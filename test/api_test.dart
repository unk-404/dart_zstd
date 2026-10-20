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

    test('encoder rejects unavailable levels', () {
      expect(() => ZstdEncoder(level: 0), throwsArgumentError);
      expect(() => ZstdEncoder(level: 4), throwsUnsupportedError);
    });
  });

  group('ZstdDecoder', () {
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
  });
}
