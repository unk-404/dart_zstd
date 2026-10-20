import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zstd_neo/zstd_neo.dart';

/// Builds a single-frame zstd stream with one raw block.
Uint8List rawFrame({
  required int contentSize,
  int fcsSize = 0,
  bool singleSegment = false,
  int windowDescriptor = 0,
  required Uint8List payload,
  bool unusedBit = false,
  bool reservedBit = false,
}) {
  final out = <int>[0x28, 0xB5, 0x2F, 0xFD];
  final flag = switch (fcsSize) {
    0 => 0, // 0 bytes, or 1 byte with single-segment
    1 => 0,
    2 => 1,
    4 => 2,
    8 => 3,
    _ => throw ArgumentError.value(fcsSize, 'fcsSize'),
  };
  var descriptor = flag << 6;
  if (singleSegment) descriptor |= 0x20;
  if (unusedBit) descriptor |= 0x10;
  if (reservedBit) descriptor |= 0x08;
  out.add(descriptor);
  if (!singleSegment) out.add(windowDescriptor);

  final effectiveFcsSize = fcsSize == 0 ? (singleSegment ? 1 : 0) : fcsSize;
  if (effectiveFcsSize == 1) {
    out.add(contentSize);
  } else if (effectiveFcsSize == 2) {
    final v = contentSize - 256;
    out
      ..add(v & 0xFF)
      ..add((v >> 8) & 0xFF);
  } else if (effectiveFcsSize == 4) {
    for (var i = 0; i < 4; i++) {
      out.add((contentSize >> (8 * i)) & 0xFF);
    }
  } else if (effectiveFcsSize == 8) {
    for (var i = 0; i < 8; i++) {
      out.add((contentSize >> (8 * i)) & 0xFF);
    }
  }

  final blockHeader = (payload.length << 3) | 1; // last raw block
  out.add(blockHeader & 0xFF);
  out.add((blockHeader >> 8) & 0xFF);
  out.add((blockHeader >> 16) & 0xFF);
  out.addAll(payload);
  return Uint8List.fromList(out);
}

Uint8List bytes(int length) =>
    Uint8List.fromList(List<int>.generate(length, (i) => (i * 17 + 3) & 0xFF));

void main() {
  group('frame header conformance', () {
    test('8-byte Frame_Content_Size with small content (single segment)', () {
      final payload = bytes(13);
      final frame = rawFrame(
        contentSize: 13,
        fcsSize: 8,
        singleSegment: true,
        payload: payload,
      );
      expect(const ZstdDecoder().decompress(frame), payload);
    });

    test('8-byte Frame_Content_Size with an explicit window', () {
      final payload = bytes(13);
      final frame = rawFrame(contentSize: 13, fcsSize: 8, payload: payload);
      expect(const ZstdDecoder().decompress(frame), payload);
    });

    test('1/2/4-byte Frame_Content_Size encodings', () {
      for (final (size, length) in [(1, 13), (2, 300), (4, 500)]) {
        final payload = bytes(length);
        final frame = rawFrame(
          contentSize: length,
          fcsSize: size,
          singleSegment: size == 1,
          payload: payload,
        );
        expect(
          const ZstdDecoder().decompress(frame),
          payload,
          reason: 'fcsSize=$size',
        );
      }
    });

    test('unused frame-header bit is ignored', () {
      final payload = bytes(20);
      final frame = rawFrame(
        contentSize: 20,
        fcsSize: 1,
        singleSegment: true,
        unusedBit: true,
        payload: payload,
      );
      expect(const ZstdDecoder().decompress(frame), payload);
    });

    test('reserved frame-header bit is rejected', () {
      final frame = rawFrame(
        contentSize: 20,
        fcsSize: 1,
        singleSegment: true,
        reservedBit: true,
        payload: bytes(20),
      );
      expect(
        () => const ZstdDecoder().decompress(frame),
        throwsA(isA<ZstdException>()),
      );
    });

    test('zero-length single-segment frame decodes to empty', () {
      final frame = rawFrame(
        contentSize: 0,
        fcsSize: 1,
        singleSegment: true,
        payload: Uint8List(0),
      );
      expect(const ZstdDecoder().decompress(frame), isEmpty);
    });
  });

  group('resource and corruption limits', () {
    test('declared content size mismatch is rejected', () {
      final frame = rawFrame(
        contentSize: 13,
        fcsSize: 8,
        singleSegment: true,
        payload: bytes(12),
      );
      expect(
        () => const ZstdDecoder().decompress(frame),
        throwsA(isA<ZstdException>()),
      );
    });

    test('64-bit content size beyond 2^53 is rejected clearly', () {
      final frame = rawFrame(
        contentSize: -1, // 0xFFFFFFFFFFFFFFFF
        fcsSize: 8,
        payload: Uint8List.fromList([1]),
      );
      expect(
        () => const ZstdDecoder().decompress(frame),
        throwsA(
          isA<ZstdException>().having(
            (e) => e.code,
            'code',
            ZstdErrorCode.outputTooLarge,
          ),
        ),
      );
    });

    test('huge window descriptor is rejected as windowTooLarge', () {
      final frame = rawFrame(
        contentSize: 1,
        fcsSize: 1,
        windowDescriptor: 0xFF, // exponent 31, mantissa 7
        payload: Uint8List.fromList([1]),
      );
      expect(
        () => const ZstdDecoder().decompress(frame),
        throwsA(
          isA<ZstdException>().having(
            (e) => e.code,
            'code',
            ZstdErrorCode.windowTooLarge,
          ),
        ),
      );
    });

    test('skippable-only stream yields empty output', () {
      final frame = Uint8List.fromList([
        0x50, 0x2A, 0x4D, 0x18, // skippable magic
        0x00, 0x00, 0x00, 0x00, // zero payload
      ]);
      expect(const ZstdDecoder().decompress(frame), isEmpty);
    });
  });
}
