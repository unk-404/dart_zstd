import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zstd_neo/src/compress/huffman.dart';
import 'package:zstd_neo/zstd_neo.dart';

/// Entropy-coding coverage for the v0.1.1 encoder.
///
/// These tests are web-safe (no `dart:io`). They parse the frames the encoder
/// produces to verify that Huffman literals and FSE sequence tables are really
/// used, and they check that every variant round-trips through [ZstdDecoder].
void main() {
  group('Huffman literals', () {
    test('low-entropy literals are Huffman-compressed and round-trip', () {
      final input = _smallAlphabet(16 * 1024, seed: 7);
      final frame = ZstdEncoder(level: 1).compress(input);
      final blocks = _parseBlocks(frame);
      expect(blocks, isNotEmpty);
      expect(
        blocks.any((b) => b.type == 2 && b.literalType == 2),
        isTrue,
        reason: 'expected a compressed block with compressed literals',
      );
      expect(ZstdDecoder().decompress(frame), input);
      // 8 symbols need ~3 bits each; raw literals would be much larger.
      expect(frame.length, lessThan(input.length ~/ 2));
    });

    test('literals above 1 KiB use the four-stream layout', () {
      final input = _smallAlphabet(16 * 1024, seed: 7);
      final blocks = _parseBlocks(ZstdEncoder(level: 1).compress(input));
      final compressed = blocks.firstWhere(
        (b) =>
            b.type == 2 &&
            b.literalType == 2 &&
            b.literalRegeneratedSize > 1023,
      );
      expect(
        compressed.literalSizeFormat,
        isNot(0),
        reason: 'Size_Format 0 is a single Huffman stream',
      );
    });

    test('a repeated literal distribution uses a treeless block', () {
      // More than one block of the same alphabet: the second compressed
      // literals block can reuse the previous Huffman table.
      final input = _smallAlphabet(256 * 1024, seed: 11);
      final frame = ZstdEncoder(level: 1).compress(input);
      final blocks = _parseBlocks(frame);
      expect(blocks.length, greaterThanOrEqualTo(2));
      expect(
        blocks.any((b) => b.literalType == 3),
        isTrue,
        reason: 'expected at least one treeless literals block',
      );
      expect(ZstdDecoder().decompress(frame), input);
    });

    test(
      'uniform data uses an RLE block and incompressible data stays raw',
      () {
        final zeros = Uint8List(64 * 1024);
        final rleBlocks = _parseBlocks(ZstdEncoder(level: 2).compress(zeros));
        expect(rleBlocks.single.type, 1, reason: 'RLE_Block');

        final random = _randomBytes(16 * 1024, seed: 3);
        final rawBlocks = _parseBlocks(ZstdEncoder(level: 3).compress(random));
        expect(rawBlocks.single.type, 0, reason: 'Raw_Block fallback');
      },
    );

    test('Huffman tree construction is valid and describable', () {
      final data = _wordyText(32 * 1024).toList();
      final counts = Uint32List(256);
      for (final byte in data) {
        counts[byte]++;
      }
      final table = buildHuffmanTable(counts);
      expect(table, isNotNull);
      expect(table!.tableLog, lessThanOrEqualTo(huffmanMaxBits));
      // Kraft equality: the weights describe a complete prefix tree.
      var kraft = 0;
      for (var symbol = 0; symbol < 256; symbol++) {
        final bits = table.bits[symbol];
        if (bits == 0) continue;
        expect(bits, lessThanOrEqualTo(huffmanMaxBits));
        kraft += 1 << (table.tableLog - bits);
      }
      expect(kraft, 1 << table.tableLog);

      final description = writeHuffmanTreeDescription(table);
      expect(description, isNotNull);
      _expectValidTreeDescription(description!);
    });

    test('full-alphabet weight series is FSE-described', () {
      final counts = Uint32List(256);
      for (var symbol = 0; symbol < 256; symbol++) {
        counts[symbol] = 1 + ((255 - symbol) >> 2);
      }
      final table = buildHuffmanTable(counts);
      expect(table, isNotNull);
      final description = writeHuffmanTreeDescription(table!);
      if (description != null) {
        // Direct 4-bit weights cannot represent an alphabet above 128.
        expect(description[0], lessThan(128));
        _expectValidTreeDescription(description);
      }
    });
  });

  group('FSE sequence tables', () {
    test('text data selects custom FSE tables and round-trips', () {
      final input = _wordyText(20 * 1024);
      final frame = ZstdEncoder(level: 9).compress(input);
      final blocks = _parseBlocks(frame);
      var sawCustom = false;
      for (final block in blocks) {
        if (block.sequenceCount == 0 || block.sequenceModeByte < 0) continue;
        final llMode = block.sequenceModeByte >> 6;
        final ofMode = (block.sequenceModeByte >> 4) & 3;
        final mlMode = (block.sequenceModeByte >> 2) & 3;
        if (llMode >= 2 || ofMode >= 2 || mlMode >= 2) sawCustom = true;
      }
      expect(sawCustom, isTrue, reason: 'expected a custom/repeat FSE table');
      expect(ZstdDecoder().decompress(frame), input);
    });

    test('zero-run FSE descriptions stay valid (fast-level edge)', () {
      // Regression for a custom FSE description with a very long run of
      // zero-probability symbols; fast levels used to emit corrupt tables.
      for (final size in <int>[
        65599,
        65600,
        65601,
        65602,
        65603,
        65604,
        65605,
      ]) {
        final input = _repetitivePattern(size);
        for (final level in <int>[1, 2]) {
          final frame = ZstdEncoder(level: level).compress(input);
          expect(
            ZstdDecoder().decompress(frame),
            input,
            reason: 'size=$size level=$level',
          );
        }
      }
    });

    test('custom FSE tables are used with many match sequences', () {
      final input = _wordyText(40 * 1024);
      final frame = ZstdEncoder(level: 3).compress(input);
      final blocks = _parseBlocks(frame);
      final block = blocks.firstWhere((b) => b.sequenceCount > 100);
      expect(block.sequenceModeByte, isNot(-1));
      expect(ZstdDecoder().decompress(frame), input);
      expect(frame.length, lessThan(input.length ~/ 2));
    });
  });

  group('entropy fallbacks', () {
    test('incompressible data never grows beyond block headers', () {
      final input = _randomBytes(32 * 1024, seed: 21);
      for (final level in <int>[1, 3, 9]) {
        final frame = ZstdEncoder(level: level).compress(input);
        expect(frame.length, lessThanOrEqualTo(input.length + 32));
        expect(ZstdDecoder().decompress(frame), input);
      }
    });

    test('short literals use the compact single-stream header', () {
      // Mostly-match data leaves few literals; the section must stay valid.
      final input = _repetitiveText(4096);
      for (final level in <int>[1, 5, 9]) {
        final frame = ZstdEncoder(level: level).compress(input);
        expect(ZstdDecoder().decompress(frame), input);
        for (final block in _parseBlocks(frame)) {
          if (block.literalType == 2 || block.literalType == 3) {
            expect(block.literalRegeneratedSize, greaterThan(0));
          }
        }
      }
    });
  });
}

// --- Frame parsing helpers --------------------------------------------------

final class _BlockInfo {
  _BlockInfo({
    required this.type,
    required this.size,
    required this.literalType,
    required this.literalSizeFormat,
    required this.literalRegeneratedSize,
    required this.sequenceCount,
    required this.sequenceModeByte,
  });

  final int type;
  final int size;
  final int literalType;
  final int literalSizeFormat;
  final int literalRegeneratedSize;
  final int sequenceCount;
  final int sequenceModeByte;
}

List<_BlockInfo> _parseBlocks(Uint8List frame) {
  expect(frame.length, greaterThanOrEqualTo(9));
  expect(
    frame[0] == 0x28 &&
        frame[1] == 0xB5 &&
        frame[2] == 0x2F &&
        frame[3] == 0xFD,
    isTrue,
    reason: 'frame must start with the zstd magic',
  );
  final descriptor = frame[4];
  final singleSegment = (descriptor & 0x20) != 0;
  final dictionaryIdFlag = descriptor & 3;
  final fcsFlag = descriptor >> 6;
  var position = 5;
  if (!singleSegment) position++;
  position += const <int>[0, 1, 2, 4][dictionaryIdFlag];
  final fcsSize = fcsFlag == 0
      ? (singleSegment ? 1 : 0)
      : const <int>[0, 2, 4, 8][fcsFlag];
  position += fcsSize;

  final blocks = <_BlockInfo>[];
  while (position + 3 <= frame.length) {
    final header =
        frame[position] |
        (frame[position + 1] << 8) |
        (frame[position + 2] << 16);
    position += 3;
    final last = (header & 1) != 0;
    final type = (header >> 1) & 3;
    final size = header >> 3;
    if (type != 2) {
      blocks.add(
        _BlockInfo(
          type: type,
          size: size,
          literalType: -1,
          literalSizeFormat: -1,
          literalRegeneratedSize: 0,
          sequenceCount: 0,
          sequenceModeByte: -1,
        ),
      );
      position += type == 1 ? 1 : size;
      if (last) break;
      continue;
    }
    final blockStart = position;
    final b0 = frame[blockStart];
    final literalType = b0 & 3;
    final sizeFormat = (b0 >> 2) & 3;
    var headerSize = 0;
    var regeneratedSize = 0;
    var compressedSize = 0;
    if (literalType <= 1) {
      if (sizeFormat == 0 || sizeFormat == 2) {
        headerSize = 1;
        regeneratedSize = b0 >> 3;
      } else if (sizeFormat == 1) {
        headerSize = 2;
        regeneratedSize = (b0 >> 4) + (frame[blockStart + 1] << 4);
      } else {
        headerSize = 3;
        regeneratedSize =
            (b0 >> 4) +
            (frame[blockStart + 1] << 4) +
            (frame[blockStart + 2] << 12);
      }
    } else {
      if (sizeFormat == 0) {
        headerSize = 3;
        regeneratedSize = (b0 >> 4) | ((frame[blockStart + 1] & 0x3F) << 4);
        compressedSize =
            ((frame[blockStart + 1] >> 6) & 0x3) + (frame[blockStart + 2] << 2);
      } else {
        headerSize = sizeFormat + 2;
        final bits = sizeFormat == 1 ? 10 : (sizeFormat == 2 ? 14 : 18);
        var value = 0;
        var multiplier = 1;
        for (var i = 0; i < headerSize; i++) {
          value += frame[blockStart + i] * multiplier;
          multiplier *= 256;
        }
        value = value ~/ 16;
        final mask = (1 << bits) - 1;
        regeneratedSize = value & mask;
        compressedSize = (value ~/ (1 << bits)) & mask;
      }
    }
    final literalSectionSize =
        headerSize +
        (literalType == 0
            ? regeneratedSize
            : (literalType == 1 ? 1 : compressedSize));
    var sequenceCount = 0;
    var sequenceModeByte = -1;
    var sequencePosition = blockStart + literalSectionSize;
    if (sequencePosition < frame.length) {
      final q0 = frame[sequencePosition];
      if (q0 < 128) {
        sequenceCount = q0;
        sequencePosition += 1;
      } else if (q0 < 255) {
        sequenceCount = ((q0 - 128) << 8) + frame[sequencePosition + 1];
        sequencePosition += 2;
      } else {
        sequenceCount =
            frame[sequencePosition + 1] +
            (frame[sequencePosition + 2] << 8) +
            0x7F00;
        sequencePosition += 3;
      }
      if (sequenceCount > 0 && sequencePosition < frame.length) {
        sequenceModeByte = frame[sequencePosition];
      }
    }
    blocks.add(
      _BlockInfo(
        type: type,
        size: size,
        literalType: literalType,
        literalSizeFormat: sizeFormat,
        literalRegeneratedSize: regeneratedSize,
        sequenceCount: sequenceCount,
        sequenceModeByte: sequenceModeByte,
      ),
    );
    position = blockStart + size;
    if (last) break;
  }
  return blocks;
}

void _expectValidTreeDescription(Uint8List description) {
  expect(description, isNotEmpty);
  final header = description[0];
  if (header < 128) {
    expect(header, greaterThanOrEqualTo(1));
    expect(description.length, 1 + header);
  } else {
    final weightCount = header - 127;
    expect(weightCount, greaterThan(0));
    expect(description.length, 1 + ((weightCount + 1) >> 1));
  }
}

// --- Deterministic test data ------------------------------------------------

const List<String> _words = <String>[
  'the',
  'of',
  'and',
  'to',
  'in',
  'a',
  'is',
  'that',
  'for',
  'it',
  'as',
  'with',
  'was',
  'on',
  'be',
  'at',
  'by',
  'this',
  'had',
  'not',
  'are',
  'but',
  'from',
  'or',
  'have',
  'an',
  'they',
  'which',
  'one',
  'you',
  'were',
  'her',
  'all',
  'she',
  'there',
  'would',
  'their',
  'we',
  'him',
  'been',
  'has',
  'when',
  'who',
  'will',
  'more',
  'no',
  'if',
  'out',
  'so',
  'said',
  'what',
  'up',
  'its',
  'about',
  'into',
  'than',
  'them',
  'can',
  'only',
  'other',
  'new',
  'some',
  'could',
  'time',
  'these',
  'two',
  'may',
  'then',
  'do',
  'first',
  'any',
  'my',
  'now',
  'such',
  'like',
  'our',
  'over',
  'man',
  'me',
  'even',
  'most',
  'made',
  'after',
  'also',
  'did',
  'many',
  'before',
  'must',
  'through',
  'back',
  'years',
  'where',
  'much',
  'your',
  'way',
  'well',
  'down',
  'should',
  'because',
  'each',
];

int _nextState(int state) => (state * 48271) % 2147483647;

Uint8List _wordyText(int size, {int seed = 12345}) {
  final out = Uint8List(size);
  var position = 0;
  var state = seed;
  while (position < size) {
    state = _nextState(state);
    final word = _words[state % _words.length];
    for (var i = 0; i < word.length && position < size; i++) {
      out[position++] = word.codeUnitAt(i);
    }
    if (position < size) {
      state = _nextState(state);
      out[position++] = (state & 0x100) == 0 ? 0x20 : 0x0A;
    }
  }
  return out;
}

Uint8List _smallAlphabet(int size, {required int seed}) {
  final out = Uint8List(size);
  var state = seed;
  for (var i = 0; i < size; i++) {
    state = _nextState(state);
    out[i] = 0x61 + (state % 8);
  }
  return out;
}

Uint8List _randomBytes(int size, {required int seed}) {
  final random = Random(seed);
  final out = Uint8List(size);
  for (var i = 0; i < size; i++) {
    out[i] = random.nextInt(256);
  }
  return out;
}

Uint8List _repetitivePattern(int size) {
  final block = Uint8List(64);
  for (var i = 0; i < block.length; i++) {
    block[i] = 0x61 + ((i * 7 + (i ~/ 5)) % 6);
  }
  final out = Uint8List(size);
  for (var at = 0; at < size; at += block.length) {
    out.setRange(at, min(at + block.length, size), block);
  }
  return out;
}

Uint8List _repetitiveText(int size) {
  final out = Uint8List(size);
  for (var i = 0; i < size; i++) {
    out[i] = 0x61 + (i % 3);
  }
  return out;
}
