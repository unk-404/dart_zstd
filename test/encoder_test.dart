import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zstd_neo/zstd_neo.dart';

/// Little-endian zstd frame magic (`0xFD2FB528`).
const List<int> _magic = <int>[0x28, 0xB5, 0x2F, 0xFD];

/// Boundary sizes exercised by the round-trip matrix.
const List<int> _boundarySizes = <int>[
  0,
  1,
  3,
  4,
  127,
  128,
  255,
  256,
  1023,
  1024,
  4095,
  65536,
  131071,
  131072,
  1 << 20,
];

void main() {
  group('frame header', () {
    test('empty input produces a minimal valid frame', () {
      final compressed = _compress(Uint8List(0), level: 3);
      final header = _parseHeader(compressed);
      expect(header.singleSegment, isTrue);
      expect(header.contentSize, 0);
      expect(header.checksumFlag, isFalse);
      expect(header.dictionaryIdFlag, 0);
      expect(compressed.length, 9);
      expect(ZstdDecoder().decompress(compressed), isEmpty);
    });

    test('small input uses a single segment with content size', () {
      final input = Uint8List.fromList(<int>[1, 2, 3, 4]);
      final compressed = _compress(input, level: 3);
      final header = _parseHeader(compressed);
      expect(header.singleSegment, isTrue);
      expect(header.contentSize, 4);
      // No window descriptor is present in a single-segment frame.
      expect(header.windowSize, isNull);
      expect(ZstdDecoder().decompress(compressed), input);
    });

    test('large input keeps a bounded window but records content size', () {
      final input = _mixed(1 << 20, seed: 11);
      final compressed = _compress(input, level: 1);
      final header = _parseHeader(compressed);
      expect(header.singleSegment, isFalse);
      // Level 1 default window is 2^19.
      expect(header.windowSize, 1 << 19);
      expect(header.contentSize, input.length);
      expect(ZstdDecoder().decompress(compressed), input);
    });

    test('checksum flag is written and the checksum is verified', () {
      final input = _mixed(4096, seed: 3);
      final compressed = _compress(input, level: 2, checksum: true);
      final header = _parseHeader(compressed);
      expect(header.checksumFlag, isTrue);
      expect(ZstdDecoder().decompress(compressed), input);

      final tampered = Uint8List.fromList(compressed);
      tampered[tampered.length - 1] ^= 0xFF;
      expect(
        () => ZstdDecoder().decompress(tampered),
        throwsA(isA<ZstdException>()),
      );
    });

    test('unused/reserved header bits and dictionary id are clear', () {
      for (final level in <int>[1, 2, 3]) {
        for (final size in <int>[0, 1, 300, 4096]) {
          final compressed = _compress(_mixed(size, seed: size), level: level);
          final descriptor = compressed[4];
          expect(descriptor & 0x18, 0, reason: 'unused/reserved bits');
          expect(descriptor & 0x03, 0, reason: 'dictionary id flag');
        }
      }
    });
  });

  group('one-shot roundtrip', () {
    test('boundary sizes x levels x checksum', () {
      for (final size in _boundarySizes) {
        final input = _mixed(size, seed: size);
        for (final level in <int>[1, 2, 3]) {
          for (final checksum in <bool>[false, true]) {
            _expectRoundtrip(
              input,
              level: level,
              checksum: checksum,
              reason: 'size=$size level=$level checksum=$checksum',
            );
          }
        }
      }
    });

    test('random data roundtrips at every level', () {
      for (final size in <int>[0, 1, 64, 1000, 65536]) {
        final input = _random(size, seed: size + 17);
        for (final level in <int>[1, 2, 3]) {
          _expectRoundtrip(input, level: level, checksum: true);
        }
      }
    });

    test('repetitive data actually compresses', () {
      final input = _repetitive(1 << 16);
      for (final level in <int>[1, 2, 3]) {
        final compressed = _compress(input, level: level);
        expect(
          compressed.length,
          lessThan(input.length ~/ 2),
          reason: 'level $level should compress repetitive text',
        );
        expect(ZstdDecoder().decompress(compressed), input);
      }
    });

    test('incompressible data falls back to raw blocks and stays valid', () {
      final input = _random(1 << 16, seed: 99);
      final compressed = _compress(input, level: 3);
      // Frame overhead only: magic + header + block header (+ padding).
      expect(compressed.length, lessThanOrEqualTo(input.length + 32));
      expect(ZstdDecoder().decompress(compressed), input);
    });

    test('single-value data uses RLE blocks', () {
      final input = Uint8List(1 << 16); // all zeroes
      final compressed = _compress(input, level: 2);
      expect(compressed.length, lessThan(20));
      expect(ZstdDecoder().decompress(compressed), input);
    });

    test('multi-block input above 128 KiB roundtrips', () {
      final input = _mixed(300 * 1024, seed: 5);
      final compressed = _compress(input, level: 1, checksum: true);
      expect(ZstdDecoder().decompress(compressed), input);
    });

    test('convert() accepts a plain List<int>', () {
      final input = List<int>.generate(4096, (i) => (i * 37 + 5) & 0xFF);
      final compressed = ZstdEncoder(level: 3).convert(input);
      expect(_startsWithMagic(compressed), isTrue);
      expect(ZstdDecoder().decompress(compressed), input);
    });

    test('compression is deterministic', () {
      final input = _mixed(20000, seed: 8);
      final encoder = ZstdEncoder(level: 3, checksum: true);
      expect(encoder.compress(input), encoder.compress(input));
    });
  });

  group('streaming', () {
    test('chunk splits 1/7/31/1000 at levels 1 and 3', () {
      final input = _mixed(100000, seed: 21);
      for (final split in <int>[1, 7, 31, 1000]) {
        for (final level in <int>[1, 3]) {
          final collector = _CollectSink();
          final sink = ZstdEncoder(level: level)
              .startChunkedConversion(collector);
          for (var i = 0; i < input.length; i += split) {
            final end = min(i + split, input.length);
            sink.add(Uint8List.sublistView(input, i, end));
          }
          sink.close();
          final compressed = collector.toBytes();
          expect(collector.closed, isTrue);
          expect(_startsWithMagic(compressed), isTrue);
          expect(
            ZstdDecoder().decompress(compressed),
            input,
            reason: 'split=$split level=$level',
          );
        }
      }
    });

    test('addSlice with isLast produces a complete frame', () {
      final input = _mixed(50000, seed: 4);
      for (final split in <int>[7, 31]) {
        final collector = _CollectSink();
        final sink = ZstdEncoder(
          level: 3,
          checksum: true,
        ).startChunkedConversion(collector);
        var offset = 0;
        while (offset < input.length) {
          final end = min(offset + split, input.length);
          sink.addSlice(input, offset, end, end == input.length);
          offset = end;
        }
        sink.close();
        expect(
          ZstdDecoder().decompress(collector.toBytes()),
          input,
          reason: 'split=$split',
        );
      }
    });

    test('works with ByteConversionSink.withCallback', () {
      final input = _mixed(70000, seed: 30);
      List<int>? result;
      final sink = ZstdEncoder(level: 3, checksum: true).startChunkedConversion(
        ByteConversionSink.withCallback((bytes) => result = bytes),
      );
      const split = 1000;
      for (var i = 0; i < input.length; i += split) {
        final end = min(i + split, input.length);
        sink.addSlice(input, i, end, end == input.length);
      }
      sink.close();
      expect(result, isNotNull, reason: 'downstream close() must be forwarded');
      expect(ZstdDecoder().decompress(Uint8List.fromList(result!)), input);
    });

    test('emits blocks before close instead of buffering the whole input', () {
      final input = _mixed(300 * 1024, seed: 6);
      final collector = _CollectSink();
      final sink = ZstdEncoder(level: 1).startChunkedConversion(collector);
      for (var i = 0; i < input.length; i += 1000) {
        final end = min(i + 1000, input.length);
        sink.add(Uint8List.sublistView(input, i, end));
      }
      // Header plus at least one emitted block must already have been pushed.
      expect(collector.chunks.length, greaterThan(1));
      sink.close();
      expect(ZstdDecoder().decompress(collector.toBytes()), input);
    });

    test('empty stream is a valid empty frame', () {
      final collector = _CollectSink();
      ZstdEncoder(level: 3).startChunkedConversion(collector).close();
      final compressed = collector.toBytes();
      expect(_startsWithMagic(compressed), isTrue);
      expect(ZstdDecoder().decompress(compressed), isEmpty);
    });

    test('streaming header omits the content size and uses a window', () {
      final input = _mixed(3000, seed: 12);
      final collector = _CollectSink();
      final sink = ZstdEncoder(
        level: 3,
        checksum: true,
      ).startChunkedConversion(collector);
      sink.add(input);
      final header = _parseHeader(collector.toBytes());
      expect(header.checksumFlag, isTrue);
      expect(header.singleSegment, isFalse);
      expect(header.contentSize, isNull);
      expect(header.windowSize, 1 << 21); // level 3 default window
      sink.close();
      expect(ZstdDecoder().decompress(collector.toBytes()), input);
    });

    test('empty chunks are ignored and add() after close() throws', () {
      final collector = _CollectSink();
      final sink = ZstdEncoder(level: 2).startChunkedConversion(collector);
      sink.add(const <int>[]);
      sink.add(_mixed(1000, seed: 2));
      sink.close();
      expect(() => sink.add(const <int>[1, 2, 3]), throwsA(isA<StateError>()));
      expect(ZstdDecoder().decompress(collector.toBytes()).length, 1000);
    });

    test('streaming and one-shot output decode identically', () {
      final input = _mixed(250000, seed: 13);
      final oneShot = ZstdEncoder(level: 2).compress(input);
      final collector = _CollectSink();
      final sink = ZstdEncoder(level: 2).startChunkedConversion(collector);
      for (var i = 0; i < input.length; i += 4096) {
        final end = min(i + 4096, input.length);
        sink.add(Uint8List.sublistView(input, i, end));
      }
      sink.close();
      expect(
        ZstdDecoder().decompress(oneShot),
        ZstdDecoder().decompress(collector.toBytes()),
      );
    });
  });
}

Uint8List _compress(
  Uint8List input, {
  required int level,
  bool checksum = false,
}) => ZstdEncoder(level: level, checksum: checksum).compress(input);

void _expectRoundtrip(
  Uint8List input, {
  required int level,
  required bool checksum,
  String? reason,
}) {
  final compressed = _compress(input, level: level, checksum: checksum);
  expect(_startsWithMagic(compressed), isTrue, reason: reason);
  expect(ZstdDecoder().decompress(compressed), input, reason: reason);
}

bool _startsWithMagic(Uint8List frame) {
  if (frame.length < _magic.length) return false;
  for (var i = 0; i < _magic.length; i++) {
    if (frame[i] != _magic[i]) return false;
  }
  return true;
}

/// Parses the subset of the frame header the encoder can produce.
({
  bool singleSegment,
  bool checksumFlag,
  int dictionaryIdFlag,
  int? windowSize,
  int? contentSize,
})
_parseHeader(Uint8List frame) {
  expect(frame.length, greaterThanOrEqualTo(6));
  expect(
    _startsWithMagic(frame),
    isTrue,
    reason: 'frame must start with magic',
  );
  final descriptor = frame[4];
  final fcsFlag = descriptor >> 6;
  final singleSegment = (descriptor & 0x20) != 0;
  final checksumFlag = (descriptor & 0x04) != 0;
  final dictionaryIdFlag = descriptor & 0x03;
  var position = 5;

  int? windowSize;
  if (!singleSegment) {
    final windowDescriptor = frame[position++];
    final windowLog = 10 + (windowDescriptor >> 3);
    final windowBase = 1 << windowLog;
    final windowAdd = (windowBase >> 3) * (windowDescriptor & 7);
    windowSize = windowBase + windowAdd;
  }
  position += const <int>[0, 1, 2, 4][dictionaryIdFlag];
  final fcsSize = fcsFlag == 0
      ? (singleSegment ? 1 : 0)
      : const <int>[0, 2, 4, 8][fcsFlag];
  int? contentSize;
  if (fcsSize > 0) {
    var value = 0;
    var multiplier = 1;
    for (var i = 0; i < fcsSize; i++) {
      value += frame[position + i] * multiplier;
      multiplier *= 256;
    }
    if (fcsSize == 2) value += 256;
    contentSize = value;
    position += fcsSize;
  }
  return (
    singleSegment: singleSegment,
    checksumFlag: checksumFlag,
    dictionaryIdFlag: dictionaryIdFlag,
    windowSize: windowSize,
    contentSize: contentSize,
  );
}

Uint8List _random(int size, {required int seed}) {
  final random = Random(seed);
  final data = Uint8List(size);
  for (var i = 0; i < size; i++) {
    data[i] = random.nextInt(256);
  }
  return data;
}

const String _sampleText = 'the quick brown fox jumps over the lazy dog. ';

Uint8List _repetitive(int size) {
  final data = Uint8List(size);
  for (var i = 0; i < size; i++) {
    data[i] = _sampleText.codeUnitAt(i % _sampleText.length);
  }
  return data;
}

/// Compressible prefix, incompressible middle and RLE-able tail.
Uint8List _mixed(int size, {required int seed}) {
  final data = Uint8List(size);
  final third = size ~/ 3;
  final random = Random(seed);
  for (var i = 0; i < size; i++) {
    if (i < third) {
      data[i] = _sampleText.codeUnitAt(i % _sampleText.length);
    } else if (i < 2 * third) {
      data[i] = random.nextInt(256);
    } else {
      data[i] = 0;
    }
  }
  return data;
}

final class _CollectSink implements Sink<List<int>> {
  final List<List<int>> chunks = <List<int>>[];
  bool closed = false;

  @override
  void add(List<int> data) {
    expect(closed, isFalse, reason: 'add() after close()');
    chunks.add(data);
  }

  @override
  void close() {
    closed = true;
  }

  Uint8List toBytes() {
    var length = 0;
    for (final chunk in chunks) {
      length += chunk.length;
    }
    final out = Uint8List(length);
    var offset = 0;
    for (final chunk in chunks) {
      out.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return out;
  }
}
