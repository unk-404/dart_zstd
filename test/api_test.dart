import 'dart:convert';
import 'dart:typed_data';

import 'package:blit/blit.dart';
import 'package:test/test.dart';
import 'package:zstd_neo/zstd_neo.dart';

void main() {
  group('ZstdCodec', () {
    test('one-shot roundtrip', () {
      final input = utf8.encode(
        'The quick brown fox jumps over the lazy dog. ' * 100,
      );
      final codec = const ZstdCodec(level: 3);
      final compressed = codec.encode(input);
      expect(compressed, isNotEmpty);
      expect(compressed.length, lessThan(input.length));
      expect(codec.decode(compressed), input);
    });

    test('empty input', () {
      final codec = const ZstdCodec();
      final compressed = codec.encode(const <int>[]);
      expect(codec.decode(compressed), isEmpty);
    });

    test('binary input', () {
      final input = Uint8List.fromList(
        List<int>.generate(100000, (i) => (i * 31 + 7) & 0xFF),
      );
      final codec = const ZstdCodec(level: 1);
      expect(codec.decode(codec.encode(input)), input);
    });

    test('checksum option', () {
      final input = utf8.encode('checksum me ' * 1000);
      final codec = const ZstdCodec(level: 2, checksum: true);
      expect(codec.decode(codec.encode(input)), input);
    });

    test('Bytes overloads are zero-copy views', () {
      final input = Bytes.fromUint8List(
        Uint8List.fromList(utf8.encode('blit bytes ' * 50)),
      );
      final codec = const ZstdCodec();
      final compressed = codec.compressBytes(input);
      final restored = codec.decompressBytes(compressed);
      expect(restored.toUint8List(), input.toUint8List());
    });

    test('level 19 roundtrip', () {
      final input = utf8.encode('high compression level ' * 2000);
      final codec = const ZstdCodec(level: 19);
      expect(codec.decode(codec.encode(input)), input);
    });

    test('dictionary roundtrip', () {
      final dictionary = Uint8List.fromList(
        utf8.encode('shared dictionary prefix for the zstd_neo test ' * 4),
      );
      final input = Uint8List.fromList(
        utf8.encode('shared dictionary prefix for the zstd_neo test payload'),
      );
      final codec = ZstdCodec(level: 9, dictionary: dictionary);
      final frame = codec.encode(input);
      expect(codec.decode(frame), input);
    });

    test('encoder validates the level range', () {
      expect(() => ZstdEncoder(level: 0), throwsArgumentError);
      expect(() => ZstdEncoder(level: 20), throwsArgumentError);
      expect(ZstdEncoder(level: 4).level, 4);
      expect(ZstdEncoder(level: 19).level, 19);
    });
  });

  group('ZstdDecoder', () {
    test('enforces maxOutputSize', () {
      final frame = Uint8List.fromList(
        const ZstdCodec().encode(utf8.encode('x' * 1000)),
      );
      expect(
        () => ZstdDecoder(maxOutputSize: 100).decompress(frame),
        throwsA(
          isA<ZstdException>().having(
            (error) => error.code,
            'code',
            ZstdErrorCode.outputTooLarge,
          ),
        ),
      );
    });

    test('rejects a negative maxOutputSize at use time', () {
      final frame = Uint8List.fromList(
        const ZstdCodec().encode(utf8.encode('negative limit')),
      );
      expect(
        () => ZstdDecoder(maxOutputSize: -1).decompress(frame),
        throwsArgumentError,
      );
      expect(
        () => ZstdDecoder(maxOutputSize: -1)
            .startChunkedConversion(ByteConversionSink.withCallback((_) {})),
        throwsArgumentError,
      );
    });

    test('rejects garbage', () {
      expect(
        () => const ZstdDecoder().decompress(Uint8List.fromList([1, 2, 3, 4])),
        throwsA(isA<ZstdException>()),
      );
    });

    test('rejects an empty buffer', () {
      expect(
        () => const ZstdDecoder().decompress(Uint8List(0)),
        throwsA(isA<ZstdException>()),
      );
    });

    test('decompressInto writes at the requested offset', () {
      final expected = utf8.encode('decompress into a caller buffer ' * 40);
      final frame = Uint8List.fromList(const ZstdCodec().encode(expected));
      final output = Uint8List(7 + expected.length + 128 * 1024);
      final written = const ZstdDecoder().decompressInto(
        frame,
        output,
        outputOffset: 7,
      );
      expect(written, expected.length);
      expect(output.sublist(7, 7 + written), expected);
    });

    test('decompressInto falls back when the buffer has no block slack', () {
      final expected = utf8.encode('exact size destination');
      final frame = Uint8List.fromList(const ZstdCodec().encode(expected));
      final output = Uint8List(expected.length);
      final written = const ZstdDecoder().decompressInto(frame, output);
      expect(written, expected.length);
      expect(output, expected);
    });
  });
}
