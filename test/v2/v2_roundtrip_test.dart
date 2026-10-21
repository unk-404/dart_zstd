import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zstd_neo/src/compress/encoder.dart' as v1;
import 'package:zstd_neo/src/v2/compress/encoder.dart';
import 'package:zstd_neo/zstd_neo.dart';

Uint8List _wordyText(int size, {int seed = 12345}) {
  final random = Random(seed);
  final words = <String>[
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
  ];
  final out = Uint8List(size);
  var position = 0;
  while (position < size) {
    final word = words[random.nextInt(words.length)];
    for (var i = 0; i < word.length && position < size; i++) {
      out[position++] = word.codeUnitAt(i);
    }
    if (position < size) out[position++] = random.nextBool() ? 0x20 : 0x0A;
  }
  return out;
}

Uint8List _randomBytes(int size, {int seed = 7}) {
  final random = Random(seed);
  final out = Uint8List(size);
  for (var i = 0; i < size; i++) {
    out[i] = random.nextInt(256);
  }
  return out;
}

void main() {
  final decoder = ZstdDecoder();

  test('v2 round-trips at every level', () {
    final data = Uint8List.fromList(
      _wordyText(32 * 1024) + _randomBytes(4096) + List<int>.filled(1024, 0x41),
    );
    for (var level = 1; level <= 19; level++) {
      final frame = ZstdV2Encoder(level: level).compress(data);
      expect(decoder.decompress(frame), data, reason: 'level $level');
    }
  });

  test('v2 frame decodes with libzstd-compatible decoder, checksum on', () {
    final data = _wordyText(16 * 1024);
    final frame = ZstdV2Encoder(level: 3, checksum: true).compress(data);
    expect(decoder.decompress(frame), data);
  });

  test('v2 streaming round-trips', () {
    final data = _wordyText(20 * 1024);
    final collector = <int>[];
    final sink = ZstdV2Encoder(
      level: 3,
    ).startChunkedConversion(ByteConversionSink.withCallback(collector.addAll));
    for (var i = 0; i < data.length; i += 777) {
      final end = min(i + 777, data.length);
      sink.add(Uint8List.sublistView(data, i, end));
    }
    sink.close();
    expect(decoder.decompress(Uint8List.fromList(collector)), data);
  });

  test('v2 ratio is close to v0.1.2', () {
    final data = _wordyText(64 * 1024);
    for (final level in <int>[3, 9, 19]) {
      final v1Size = v1.ZstdEncoder(level: level).compress(data).length;
      final v2Size = ZstdV2Encoder(level: level).compress(data).length;
      final gap = (v2Size - v1Size) / v1Size * 100;
      expect(
        gap,
        lessThan(2.0),
        reason:
            'level $level: v2=$v2Size v1=$v1Size (${gap.toStringAsFixed(2)}%)',
      );
    }
  });
}
