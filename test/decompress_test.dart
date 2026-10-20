import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zstd_neo/src/common/xxh64.dart';
import 'package:zstd_neo/zstd_neo.dart';

import 'fixtures/fixtures.g.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Uint8List _b64(String encoded) => base64Decode(encoded);

ZstdFixture _fixture(String name) =>
    webFixtures.firstWhere((fixture) => fixture.name == name);

Uint8List _fixtureZst(String name) => _b64(_fixture(name).zstBase64);

Uint8List _fixtureBin(String name) => _b64(_fixture(name).binBase64);

Uint8List _fixtureDict(String name) => _b64(_fixture(name).dictBase64!);

/// Little-endian 32-bit value (used to build and corrupt test frames).
List<int> _le32(int value) => <int>[
  value & 0xFF,
  (value >> 8) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 24) & 0xFF,
];

const List<int> _magic = <int>[0x28, 0xB5, 0x2F, 0xFD];

/// Three-byte zstd block header.
List<int> _blockHeader({
  required bool last,
  required int type,
  required int size,
}) {
  final value = (last ? 1 : 0) | (type << 1) | (size << 3);
  return <int>[value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF];
}

int _xxh64Low32(Uint8List data) {
  final hasher = Xxh64();
  if (data.isNotEmpty) hasher.update(data);
  return hasher.digest().low32 & 0xFFFFFFFF;
}

/// A single-segment frame with one raw block. [payload] must be at most 255
/// bytes (Frame_Content_Size uses one byte).
Uint8List _singleSegmentFrame(
  List<int> payload, {
  bool checksum = false,
  int? declaredContentSize,
}) {
  final descriptor = (1 << 5) | (checksum ? 1 << 2 : 0);
  final content = Uint8List.fromList(payload);
  final builder = BytesBuilder(copy: false);
  builder.add(_magic);
  builder.add(<int>[descriptor, declaredContentSize ?? content.length]);
  builder.add(_blockHeader(last: true, type: 0, size: content.length));
  builder.add(content);
  if (checksum) {
    builder.add(_le32(_xxh64Low32(content)));
  }
  return builder.toBytes();
}

/// A frame with a window descriptor and a single raw block.
Uint8List _windowRawFrame(Uint8List payload, {int windowDescriptor = 0x00}) {
  final builder = BytesBuilder(copy: false);
  builder.add(_magic);
  builder.add(<int>[0x00, windowDescriptor]);
  builder.add(_blockHeader(last: true, type: 0, size: payload.length));
  builder.add(payload);
  return builder.toBytes();
}

Uint8List _rleFrame(int length, int value) {
  final builder = BytesBuilder(copy: false);
  builder.add(_magic);
  // Window descriptor: exponent 10 => 1 KiB, mantissa 3 => 1.375 KiB.
  builder.add(<int>[0x00, (10 << 3) | 3]);
  builder.add(_blockHeader(last: true, type: 1, size: length));
  builder.addByte(value);
  return builder.toBytes();
}

Uint8List _twoBlockFrame(Uint8List first, Uint8List second) {
  final builder = BytesBuilder(copy: false);
  builder.add(_magic);
  builder.add(<int>[0x00, (11 << 3)]);
  builder.add(_blockHeader(last: false, type: 0, size: first.length));
  builder.add(first);
  builder.add(_blockHeader(last: true, type: 0, size: second.length));
  builder.add(second);
  return builder.toBytes();
}

Uint8List _skippableFrame(List<int> userData, {int n = 0}) {
  final builder = BytesBuilder(copy: false);
  builder.add(_le32(0x184D2A50 + (n & 0x0F)));
  builder.add(_le32(userData.length));
  builder.add(userData);
  return builder.toBytes();
}

Uint8List _corruptCopy(Uint8List bytes, int index, [int mask = 0xFF]) {
  final copy = Uint8List.fromList(bytes);
  copy[index] ^= mask;
  return copy;
}

void _expectZstdException(void Function() action, {ZstdErrorCode? code}) {
  try {
    action();
  } on ZstdException catch (error) {
    if (code != null) expect(error.code, code, reason: error.toString());
    return;
  }
  fail('expected a ZstdException');
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('reference frames', () {
    for (final fixture in webFixtures) {
      test('${fixture.name} decodes to its plaintext', () {
        final compressed = _b64(fixture.zstBase64);
        final expected = _b64(fixture.binBase64);
        final dictionary = fixture.dictBase64 == null
            ? null
            : _b64(fixture.dictBase64!);
        expect(compressed, hasLength(fixture.zstLength));
        expect(expected, hasLength(fixture.binLength));
        final decoder = ZstdDecoder(dictionary: dictionary);
        expect(decoder.decompress(compressed), expected);
        expect(decoder.convert(compressed), expected);
      });
    }

    test('every plaintext matches its declared length', () {
      for (final fixture in webFixtures) {
        expect(_b64(fixture.binBase64), hasLength(fixture.binLength));
      }
      for (final input in webInputs) {
        expect(_b64(input.binBase64), hasLength(input.binLength));
      }
    });
  });

  group('official golden frames', () {
    test('empty block frame decodes to zero bytes', () {
      expect(
        const ZstdDecoder().decompress(_fixtureZst('golden_empty_block')),
        isEmpty,
      );
    });

    test('zero sequences frame decodes to its plaintext', () {
      expect(
        const ZstdDecoder().decompress(_fixtureZst('golden_zero_seq_2b')),
        _fixtureBin('golden_zero_seq_2b'),
      );
    });

    test('checksummed frame decodes to its plaintext', () {
      expect(
        const ZstdDecoder().decompress(_fixtureZst('text_4k_checksum')),
        _fixtureBin('text_4k_checksum'),
      );
    });

    test('frame without content size decodes to its plaintext', () {
      final decoded = const ZstdDecoder().decompress(
        _fixtureZst('json_4k_nocontentsize'),
      );
      expect(decoded, _fixtureBin('json_4k_nocontentsize'));
    });

    test('synthetic raw block frame', () {
      final payload = Uint8List.fromList(utf8.encode('raw block payload'));
      expect(
        const ZstdDecoder().decompress(_singleSegmentFrame(payload)),
        payload,
      );
    });

    test('synthetic RLE block frame expands the repeated byte', () {
      final decoded = const ZstdDecoder().decompress(_rleFrame(1000, 0x41));
      expect(decoded, hasLength(1000));
      expect(decoded.every((byte) => byte == 0x41), isTrue);
    });

    test('synthetic window-descriptor frame', () {
      final payload = Uint8List.fromList(List<int>.generate(700, (i) => i & 1));
      expect(const ZstdDecoder().decompress(_windowRawFrame(payload)), payload);
    });

    test('synthetic two-block frame', () {
      final first = Uint8List.fromList(List<int>.filled(300, 0x61));
      final second = Uint8List.fromList(List<int>.filled(500, 0x62));
      final frame = _twoBlockFrame(first, second);
      expect(
        const ZstdDecoder().decompress(frame),
        Uint8List.fromList(<int>[...first, ...second]),
      );
    });

    test('synthetic checksummed frame', () {
      final payload = Uint8List.fromList(utf8.encode('checksum me'));
      expect(
        const ZstdDecoder().decompress(
          _singleSegmentFrame(payload, checksum: true),
        ),
        payload,
      );
    });

    test('empty frame with a content checksum', () {
      // libzstd 1.5.7 output for 0 bytes with checksum enabled.
      const frameBase64 = 'KLUv/SQAAQAAmenYUQ==';
      final frame = _b64(frameBase64);
      expect(const ZstdDecoder().decompress(frame), isEmpty);
      final corrupted = _corruptCopy(frame, frame.length - 1, 0x01);
      _expectZstdException(
        () => const ZstdDecoder().decompress(corrupted),
        code: ZstdErrorCode.checksumMismatch,
      );
      expect(
        const ZstdDecoder(verifyChecksum: false).decompress(corrupted),
        isEmpty,
      );
    });
  });

  group('frame concatenation and skippable frames', () {
    test('two synthetic frames are concatenated', () {
      final first = Uint8List.fromList(utf8.encode('first frame '));
      final second = Uint8List.fromList(utf8.encode('second frame'));
      final frame = Uint8List.fromList(<int>[
        ..._singleSegmentFrame(first),
        ..._singleSegmentFrame(second),
      ]);
      expect(
        const ZstdDecoder().decompress(frame),
        Uint8List.fromList(<int>[...first, ...second]),
      );
    });

    test('skippable frames are ignored', () {
      final payload = Uint8List.fromList(utf8.encode('payload'));
      final frame = Uint8List.fromList(<int>[
        ..._skippableFrame(const <int>[1, 2, 3, 4, 5]),
        ..._singleSegmentFrame(payload),
        ..._skippableFrame(const <int>[9, 9, 9]),
      ]);
      expect(const ZstdDecoder().decompress(frame), payload);
    });

    test('skippable between reference frames', () {
      expect(
        const ZstdDecoder().decompress(_fixtureZst('skippable_between')),
        _fixtureBin('skippable_between'),
      );
      expect(
        const ZstdDecoder().decompress(_fixtureZst('skippable_prefix')),
        _fixtureBin('skippable_prefix'),
      );
    });

    test('multiframe reference frame', () {
      expect(
        const ZstdDecoder().decompress(_fixtureZst('multiframe')),
        _fixtureBin('multiframe'),
      );
    });
  });

  group('parameter matrix', () {
    test('window larger than maxWindowSize is rejected', () {
      final payload = Uint8List.fromList(<int>[1, 2, 3]);
      // windowLog = 10 + 11 = 21 => a 2 MiB window.
      final frame = _windowRawFrame(payload, windowDescriptor: 11 << 3);
      _expectZstdException(
        () => ZstdDecoder(maxWindowSize: 1024).decompress(frame),
        code: ZstdErrorCode.windowTooLarge,
      );
      // A large enough limit accepts the same frame.
      expect(ZstdDecoder(maxWindowSize: 1 << 21).decompress(frame), payload);
    });

    test('implementation window limit is enforced', () {
      final builder = BytesBuilder(copy: false)
        ..add(_magic)
        ..add(<int>[0x00, (31 << 3) | 7]);
      _expectZstdException(
        () => ZstdDecoder(maxWindowSize: 1 << 40).decompress(builder.toBytes()),
        code: ZstdErrorCode.windowTooLarge,
      );
    });

    test('content size present and absent both decode', () {
      expect(
        const ZstdDecoder().decompress(_fixtureZst('json_4k_contentsize')),
        _fixtureBin('json_4k_contentsize'),
      );
      expect(
        const ZstdDecoder().decompress(_fixtureZst('json_4k_nocontentsize')),
        _fixtureBin('json_4k_nocontentsize'),
      );
    });

    test('checksum verification can be disabled', () {
      final frame = _fixtureZst('text_4k_checksum');
      final corrupted = _corruptCopy(frame, frame.length - 1, 0x01);
      _expectZstdException(
        () => const ZstdDecoder().decompress(corrupted),
        code: ZstdErrorCode.checksumMismatch,
      );
      expect(
        const ZstdDecoder(verifyChecksum: false).decompress(corrupted),
        _fixtureBin('text_4k_checksum'),
      );
    });

    test('decode levels one to nineteen', () {
      for (final name in <String>[
        'text_16k_l1',
        'text_16k_l3',
        'text_16k_l9',
        'text_16k_l19',
      ]) {
        expect(
          const ZstdDecoder().decompress(_fixtureZst(name)),
          _fixtureBin(name),
          reason: name,
        );
      }
    });

    test('convert accepts a plain List<int>', () {
      final frame = _fixtureZst('text_4k_nochecksum');
      final asList = List<int>.of(frame);
      expect(
        const ZstdDecoder().convert(asList),
        _fixtureBin('text_4k_nochecksum'),
      );
    });
  });

  group('maxOutputSize', () {
    test('unlimited by default', () {
      expect(
        const ZstdDecoder().decompress(_fixtureZst('text_16k_l3')),
        _fixtureBin('text_16k_l3'),
      );
    });

    test('exact bound is allowed', () {
      final expected = _fixtureBin('text_16k_l3');
      expect(
        ZstdDecoder(maxOutputSize: expected.length)
            .decompress(_fixtureZst('text_16k_l3')),
        expected,
      );
    });

    test('one byte below the output size throws outputTooLarge', () {
      final expected = _fixtureBin('text_16k_l3');
      _expectZstdException(
        () =>
            ZstdDecoder(maxOutputSize: expected.length - 1)
                .decompress(_fixtureZst('text_16k_l3')),
        code: ZstdErrorCode.outputTooLarge,
      );
    });

    test('zero bound allows an empty frame but rejects output', () {
      expect(
        const ZstdDecoder(maxOutputSize: 0)
            .decompress(_fixtureZst('golden_empty_block')),
        isEmpty,
      );
      _expectZstdException(
        () =>
            const ZstdDecoder(maxOutputSize: 0)
                .decompress(_fixtureZst('text_4k_nochecksum')),
        code: ZstdErrorCode.outputTooLarge,
      );
    });

    test('bound covers concatenated frames', () {
      final frame = _fixtureZst('multiframe');
      final expected = _fixtureBin('multiframe');
      expect(
        ZstdDecoder(maxOutputSize: expected.length).decompress(frame),
        expected,
      );
      _expectZstdException(
        () => ZstdDecoder(maxOutputSize: expected.length - 1).decompress(frame),
        code: ZstdErrorCode.outputTooLarge,
      );
    });

    test('skippable frames do not consume the bound', () {
      final expected = _fixtureBin('skippable_between');
      expect(
        ZstdDecoder(maxOutputSize: expected.length)
            .decompress(_fixtureZst('skippable_between')),
        expected,
      );
      _expectZstdException(
        () =>
            ZstdDecoder(maxOutputSize: expected.length - 1)
                .decompress(_fixtureZst('skippable_between')),
        code: ZstdErrorCode.outputTooLarge,
      );
    });

    test('dictionary frames honour the bound', () {
      final expected = _fixtureBin('structdict');
      expect(
        ZstdDecoder(
          dictionary: _fixtureDict('structdict'),
          maxOutputSize: expected.length,
        ).decompress(_fixtureZst('structdict')),
        expected,
      );
      _expectZstdException(
        () => ZstdDecoder(
          dictionary: _fixtureDict('structdict'),
          maxOutputSize: expected.length - 1,
        ).decompress(_fixtureZst('structdict')),
        code: ZstdErrorCode.outputTooLarge,
      );
    });

    test('large RLE output respects the bound', () {
      final frame = _rleFrame(1000, 0x41);
      expect(
        const ZstdDecoder(maxOutputSize: 1000).decompress(frame),
        hasLength(1000),
      );
      _expectZstdException(
        () => const ZstdDecoder(maxOutputSize: 999).decompress(frame),
        code: ZstdErrorCode.outputTooLarge,
      );
    });
  });

  group('special entropy coding modes', () {
    for (final frame in _specialFrames) {
      test('${frame.name} decodes', () {
        final compressed = _b64(frame.zstBase64);
        final expected = _b64(frame.binBase64);
        expect(const ZstdDecoder().decompress(compressed), expected);
      });
    }
  });

  group('corruption and errors', () {
    for (final fixture in malformedFixtures) {
      test('${fixture.name} throws ZstdException', () {
        final compressed = _b64(fixture.zstBase64);
        _expectZstdException(() => const ZstdDecoder().decompress(compressed));
      });
    }

    test('empty input throws', () {
      _expectZstdException(() => const ZstdDecoder().decompress(Uint8List(0)));
    });

    test('bad magic throws invalidMagic', () {
      _expectZstdException(
        () => const ZstdDecoder().decompress(
          Uint8List.fromList(<int>[1, 2, 3, 4]),
        ),
        code: ZstdErrorCode.invalidMagic,
      );
    });

    test('reserved frame header bit throws', () {
      final frame = Uint8List.fromList(<int>[..._magic, 0x08]);
      _expectZstdException(
        () => const ZstdDecoder().decompress(frame),
        code: ZstdErrorCode.reservedField,
      );
    });

    test('reserved block type throws', () {
      final builder = BytesBuilder(copy: false)
        ..add(_magic)
        ..add(<int>[0x20, 0x00])
        ..add(_blockHeader(last: true, type: 3, size: 0));
      _expectZstdException(
        () => const ZstdDecoder().decompress(builder.toBytes()),
        code: ZstdErrorCode.invalidBlockHeader,
      );
    });

    test('declared content size mismatch throws', () {
      final frame = _singleSegmentFrame(
        Uint8List.fromList(<int>[1, 2, 3]),
        declaredContentSize: 10,
      );
      _expectZstdException(() => const ZstdDecoder().decompress(frame));
    });

    test('huge 8-byte content size is rejected', () {
      final builder = BytesBuilder(copy: false)
        ..add(_magic)
        ..add(<int>[0xC0, 0x00]) // 8-byte FCS, window descriptor
        ..add(<int>[0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);
      _expectZstdException(
        () => const ZstdDecoder().decompress(builder.toBytes()),
        code: ZstdErrorCode.outputTooLarge,
      );
    });

    test('truncated skippable frame throws', () {
      final frame = _skippableFrame(const <int>[1, 2, 3, 4]);
      for (var cut = 0; cut < frame.length; cut++) {
        _expectZstdException(
          () => const ZstdDecoder().decompress(
            Uint8List.sublistView(frame, 0, cut),
          ),
        );
      }
    });

    test('every truncated prefix of a valid frame throws', () {
      final frame = _fixtureZst('text_4k_nochecksum');
      for (var cut = 0; cut < frame.length; cut++) {
        _expectZstdException(
          () => const ZstdDecoder().decompress(
            Uint8List.sublistView(frame, 0, cut),
          ),
        );
      }
    });

    test('random bytes never escape as a non-ZstdException', () {
      final random = Random(20261020);
      for (var length = 0; length <= 64; length++) {
        for (var iteration = 0; iteration < 6; iteration++) {
          final bytes = Uint8List.fromList(
            List<int>.generate(length, (_) => random.nextInt(256)),
          );
          try {
            const ZstdDecoder().decompress(bytes);
          } on ZstdException catch (_) {
            // expected
          }
        }
      }
    });

    test('mutated frames never escape as a non-ZstdException', () {
      final random = Random(7);
      final base = _fixtureZst('golden_zero_seq_2b');
      for (var iteration = 0; iteration < 200; iteration++) {
        final candidate = Uint8List.fromList(base);
        final mutations = 1 + random.nextInt(3);
        for (var m = 0; m < mutations; m++) {
          candidate[random.nextInt(candidate.length)] ^= 1 << random.nextInt(8);
        }
        try {
          final decoded = const ZstdDecoder().decompress(candidate);
          expect(decoded.length, lessThan(1 << 20));
        } on ZstdException catch (_) {
          // expected
        }
      }
    });
  });
}

// ---------------------------------------------------------------------------
// Reference frames that specifically exercise rarely used coding modes had to
// be generated with a forced small window (libzstd 1.5.7, 2026). They are
// embedded here so browser tests can run them without dart:io:
//   * treeless Huffman literals + Repeat_Mode sequence tables
//   * RLE_Mode sequence tables for LL, OF and ML
//   * Repeat_Mode LL/OF tables
//   * directly represented Huffman weights
// ---------------------------------------------------------------------------

final class _SpecialFrame {
  const _SpecialFrame(this.name, this.zstBase64, this.binBase64);

  final String name;
  final String zstBase64;
  final String binBase64;
}

const List<_SpecialFrame> _specialFrames = <_SpecialFrame>[
  /// modes_json_2k_l9_w10 (libzstd 1.5.7, window_log override)
  _SpecialFrame(
    'modes_json_2k_l9_w10',
    'KLUv/UAAAAfcBQCSiR4cYEXr1plxhPS81UANLQoAQOZWVijVnE0yxE0MA+tonTHUzGot5tTtnrY9KdWsGXcrV8speTsj5sWrFyFlEdky3zUBLkH+kE3d8mLhNc1AH8I/oiNoGn2EAnk1smlyfHQK8oum0XPOEUAXn2ZTBz+haU42NTwFyAwYAR+oEKhBxP0a1nCTgswBEBIBERIBJnGa/0/hAYDZ82sOYRtx3fQsX+je2jVk3fT9OegFKw3OTpM4eRrskBtTtQIAQwQKq9JpxlBqlNZipBK7p+NKqV6+upVaZ1PyxBDzQqcZQuysr93DlvmuBh/sYHPEOsPG54RTVtdPLdUAu+MkjLVKvuCoCfuceZRVohogptHk8z8PjA8=',
    'WwogIHsiaWQiOiAwLCAibmFtZSI6ICJpdGVtLTAwMDAiLCAidmFsdWUiOiAwLCAidGFncyI6IFsiYWxwaGEiLCAiYmV0YSIsICJnYW1tYSJdLCAiYWN0aXZlIjogZmFsc2V9LAogIHsiaWQiOiAxLCAibmFtZSI6ICJpdGVtLTAwMDEiLCAidmFsdWUiOiA3OTE5LCAidGFncyI6IFsiYWxwaGEiLCAiYmV0YSIsICJnYW1tYSJdLCAiYWN0aXZlIjogdHJ1ZX0sCiAgeyJpZCI6IDIsICJuYW1lIjogIml0ZW0tMDAwMiIsICJ2YWx1ZSI6IDE1ODM4LCAidGFncyI6IFsiYWxwaGEiLCAiYmV0YSIsICJnYW1tYSJdLCAiYWN0aXZlIjogdHJ1ZX0sCiAgeyJpZCI6IDMsICJuYW1lIjogIml0ZW0tMDAwMyIsICJ2YWx1ZSI6IDIzNzU3LCAidGFncyI6IFsiYWxwaGEiLCAiYmV0YSIsICJnYW1tYSJdLCAiYWN0aXZlIjogZmFsc2V9LAogIHsiaWQiOiA0LCAibmFtZSI6ICJpdGVtLTAwMDQiLCAidmFsdWUiOiAzMTY3NiwgInRhZ3MiOiBbImFscGhhIiwgImJldGEiLCAiZ2FtbWEiXSwgImFjdGl2ZSI6IHRydWV9LAogIHsiaWQiOiA1LCAibmFtZSI6ICJpdGVtLTAwMDUiLCAidmFsdWUiOiAzOTU5NSwgInRhZ3MiOiBbImFscGhhIiwgImJldGEiLCAiZ2FtbWEiXSwgImFjdGl2ZSI6IHRydWV9LAogIHsiaWQiOiA2LCAibmFtZSI6ICJpdGVtLTAwMDYiLCAidmFsdWUiOiA0NzUxNCwgInRhZ3MiOiBbImFscGhhIiwgImJldGEiLCAiZ2FtbWEiXSwgImFjdGl2ZSI6IGZhbHNlfSwKICB7ImlkIjogNywgIm5hbWUiOiAiaXRlbS0wMDA3IiwgInZhbHVlIjogNTU0MzMsICJ0YWdzIjogWyJhbHBoYSIsICJiZXRhIiwgImdhbW1hIl0sICJhY3RpdmUiOiB0cnVlfSwKICB7ImlkIjogOCwgIm5hbWUiOiAiaXRlbS0wMDA4IiwgInZhbHVlIjogNjMzNTIsICJ0YWdzIjogWyJhbHBoYSIsICJiZXRhIiwgImdhbW1hIl0sICJhY3RpdmUiOiB0cnVlfSwKICB7ImlkIjogOSwgIm5hbWUiOiAiaXRlbS0wMDA5IiwgInZhbHVlIjogNzEyNzEsICJ0YWdzIjogWyJhbHBoYSIsICJiZXRhIiwgImdhbW1hIl0sICJhY3RpdmUiOiBmYWxzZX0sCiAgeyJpZCI6IDEwLCAibmFtZSI6ICJpdGVtLTAwMTAiLCAidmFsdWUiOiA3OTE5MCwgInRhZ3MiOiBbImFscGhhIiwgImJldGEiLCAiZ2FtbWEiXSwgImFjdGl2ZSI6IHRydWV9LAogIHsiaWQiOiAxMSwgIm5hbWUiOiAiaXRlbS0wMDExIiwgInZhbHVlIjogODcxMDksICJ0YWdzIjogWyJhbHBoYSIsICJiZXRhIiwgImdhbW1hIl0sICJhY3RpdmUiOiB0cnVlfSwKICB7ImlkIjogMTIsICJuYW1lIjogIml0ZW0tMDAxMiIsICJ2YWx1ZSI6IDk1MDI4LCAidGFncyI6IFsiYWxwaGEiLCAiYmV0YSIsICJnYW1tYSJdLCAiYWN0aXZlIjogZmFsc2V9LAogIHsiaWQiOiAxMywgIm5hbWUiOiAiaXRlbS0wMDEzIiwgInZhbHVlIjogMjk0NywgInRhZ3MiOiBbImFscGhhIiwgImJldGEiLCAiZ2FtbWEiXSwgImFjdGl2ZSI6IHRydWV9LAogIHsiaWQiOiAxNCwgIm5hbWUiOiAiaXRlbS0wMDE0IiwgInZhbHVlIjogMTA4NjYsICJ0YWdzIjogWyJhbHBoYSIsICJiZXRhIiwgImdhbW1hIl0sICJhY3RpdmUiOiB0cnVlfSwKICB7ImlkIjogMTUsICJuYW1lIjogIml0ZW0tMDAxNSIsICJ2YWx1ZSI6IDE4Nzg1LCAidGFncyI6IFsiYWxwaGEiLCAiYmV0YSIsICJnYW1tYSJdLCAiYWN0aXZlIjogZmFsc2V9LAogIHsiaWQiOiAxNiwgIm5hbWUiOiAiaXRlbS0wMDE2IiwgInZhbHVlIjogMjY3MDQsICJ0YWdzIjogWyJhbHBoYSIsICJiZXRhIiwgImdhbW1hIl0sICJhY3RpdmUiOiB0cnVlfSwKICB7ImlkIjogMTcsICJuYW1lIjogIml0ZW0tMDAxNyIsICJ2YWx1ZSI6IDM0NjIzLCAidGFncyI6IFsiYWxwaGEiLCAiYmV0YSIsICJnYW1tYSJdLCAiYWN0aXZlIjogdHJ1ZX0sCiAgeyJpZCI6IDE4LCAibmFtZSI6ICJpdGVtLTAwMTgiLCAidmFsdWUiOiA0MjU0MiwgInRhZ3MiOiBbImFscGhhIiwgImJldGEiLCAiZ2FtbWEiXSwgImFjdGl2ZSI6IGZhbHNlfSwKICB7ImlkIjogMTksICJuYW1lIjogIml0ZW0tMDAxOSIsICJ2YWx1ZSI6IDUwNDYxLCAidGFncyI6IFsiYWxwaGEiLCAiYmV0YSIsICJnYW1tYSJdLCAiYWN0aXZlIjogdHI=',
  ),

  /// modes_binary_2k_l19_w10 (libzstd 1.5.7, window_log override)
  _SpecialFrame(
    'modes_binary_2k_l19_w10',
    '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',
  ),

  /// modes_text_2k_l19_w10 (libzstd 1.5.7, window_log override)
  _SpecialFrame(
    'modes_text_2k_l19_w10',
    'KLUv/UAAAAccBwCyCx8RsD1sraJDu1kDz+Cmk7W8lRPAQfN6g2VvdrDN3gy8l73Bsm8zWG/2Buy97KB5vcGy95u4tLEX1y/TFxY7cRyySkI03oz19fuegG0V/kW4k5F15qbwPp60/GO9dA8XDZbE+njCxsYXyPZiB8J/TbGxr8IrS14gK0RYl9/EQ6DxzFb7P2vgXlAoFgPEITrJmNBRrTtbCDtRTs/QI0HKwQhBsdul1eCeE2kISiIX7jUDiFzOKCBPEEQC2UPIse2puJBWnlEsPy9i7C9eRUi3HST3EmI54oN4XIa96lr/GF1JFTUBAFkKF/BuE2SUHgqqB4pyxkFFgFHOGKgyOMoDChWBRXkgoXMIKAMC',
    'dGhlLCB6c3RhbmRhcmQgZnJhbWUgY29tcHJlc3Npb24uIGRhcnQgY29kZWM6IGJsb2NrIHNlcXVlbmNlLCBsaXRlcmFsIHdpbmRvdyBzdHJlYW0uIApkZWNvZGVyIGVuY29kZXI6IGNoZWNrc3VtIGRpY3Rpb25hcnksIGVudHJvcHkgdGhlIHpzdGFuZGFyZC4gZnJhbWUgY29tcHJlc3Npb246IGRhcnQgY29kZWMsIApibG9jayBzZXF1ZW5jZSBsaXRlcmFsLiB3aW5kb3cgc3RyZWFtOiBkZWNvZGVyIGVuY29kZXIsIGNoZWNrc3VtIGRpY3Rpb25hcnkgZW50cm9weS4gdGhlIAp6c3RhbmRhcmQ6IGZyYW1lIGNvbXByZXNzaW9uLCBkYXJ0IGNvZGVjIGJsb2NrLiBzZXF1ZW5jZSBsaXRlcmFsOiB3aW5kb3cgc3RyZWFtLCBkZWNvZGVyIAplbmNvZGVyIGNoZWNrc3VtLiBkaWN0aW9uYXJ5IGVudHJvcHk6IHRoZSB6c3RhbmRhcmQsIGZyYW1lIGNvbXByZXNzaW9uIGRhcnQuIGNvZGVjIGJsb2NrOiAKc2VxdWVuY2UgbGl0ZXJhbCwgd2luZG93IHN0cmVhbSBkZWNvZGVyLiBlbmNvZGVyIGNoZWNrc3VtOiBkaWN0aW9uYXJ5IGVudHJvcHksIHRoZSB6c3RhbmRhcmQgCmZyYW1lLiBjb21wcmVzc2lvbiBkYXJ0OiBjb2RlYyBibG9jaywgc2VxdWVuY2UgbGl0ZXJhbCB3aW5kb3cuIHN0cmVhbSBkZWNvZGVyOiBlbmNvZGVyIApjaGVja3N1bSwgZGljdGlvbmFyeSBlbnRyb3B5IHRoZS4genN0YW5kYXJkIGZyYW1lOiBjb21wcmVzc2lvbiBkYXJ0LCBjb2RlYyBibG9jayBzZXF1ZW5jZS4gCmxpdGVyYWwgd2luZG93OiBzdHJlYW0gZGVjb2RlciwgZW5jb2RlciBjaGVja3N1bSBkaWN0aW9uYXJ5LiBlbnRyb3B5IHRoZTogenN0YW5kYXJkIGZyYW1lLCAKY29tcHJlc3Npb24gZGFydCBjb2RlYy4gYmxvY2sgc2VxdWVuY2U6IGxpdGVyYWwgd2luZG93LCBzdHJlYW0gZGVjb2RlciBlbmNvZGVyLiBjaGVja3N1bSAKZGljdGlvbmFyeTogZW50cm9weSB0aGUsIHpzdGFuZGFyZCBmcmFtZSBjb21wcmVzc2lvbi4gZGFydCBjb2RlYzogYmxvY2sgc2VxdWVuY2UsIGxpdGVyYWwgCndpbmRvdyBzdHJlYW0uIGRlY29kZXIgZW5jb2RlcjogY2hlY2tzdW0gZGljdGlvbmFyeSwgZW50cm9weSB0aGUgenN0YW5kYXJkLiBmcmFtZSBjb21wcmVzc2lvbjogCmRhcnQgY29kZWMsIGJsb2NrIHNlcXVlbmNlIGxpdGVyYWwuIHdpbmRvdyBzdHJlYW06IGRlY29kZXIgZW5jb2RlciwgY2hlY2tzdW0gZGljdGlvbmFyeSAKZW50cm9weS4gdGhlIHpzdGFuZGFyZDogZnJhbWUgY29tcHJlc3Npb24sIGRhcnQgY29kZWMgYmxvY2suIHNlcXVlbmNlIGxpdGVyYWw6IHdpbmRvdyAKc3RyZWFtLCBkZWNvZGVyIGVuY29kZXIgY2hlY2tzdW0uIGRpY3Rpb25hcnkgZW50cm9weTogdGhlIHpzdGFuZGFyZCwgZnJhbWUgY29tcHJlc3Npb24gZGFydC4gCmNvZGVjIGJsb2NrOiBzZXF1ZW5jZSBsaXRlcmFsLCB3aW5kb3cgc3RyZWFtIGRlY29kZXIuIGVuY29kZXIgY2hlY2tzdW06IGRpY3Rpb25hcnkgZW50cm9weSwgCnRoZSB6c3RhbmRhcmQgZnJhbWUuIGNvbXByZXNzaW9uIGRhcnQ6IGNvZGVjIGJsb2NrLCBzZXF1ZW5jZSBsaXRlcmFsIHdpbmRvdy4gc3RyZWFtIApkZWNvZGVyOiBlbmNvZGVyIGNoZWNrc3VtLCBkaWN0aW9uYXJ5IGVudHJvcHkgdGhlLiB6c3RhbmRhcmQgZnJhbWU6IGNvbXByZXNzaW9uIGRhcnQsIGNvZGVjIApibG9jayBzZXF1ZW5jZS4gbGl0ZXJhbCB3aW5kb3c6IHN0cmVhbSBkZWNvZGVyLCBlbmNvZGVyIGNoZWNrc3VtIGRpY3Rpb25hcnkuIGVudHJvcHkgdGhlOiAKenN0YW5kYXJkIGZyYW1lLCBjb21wcmVzc2lvbiBkYXJ0IGNvZGVjLiBibG9jayBzZXF1ZW5jZTogbGl0ZXJhbCB3aW5kb3csIHN0cmVhbSBkZWNvZGVyIAplbmNvZGVyLiBjaGVja3N1bSBkaWN0aW9uYXJ5OiBlbnRyb3B5IHRoZSwgenN0YW5kYXJkIGZyYW1lIGNvbXByZXNzaW9uLiBkYXJ0IGNvZGVjOiBibG9jayAKc2VxdWVuY2UsIGxpdGVyYWwgd2luZG93IHN0cmVhbS4gZGVjb2RlciBlbmNvZGVyOiBjaGVja3N1bSBkaWN0aW9uYXJ5LCBlbnRyb3B5IHRoZSB6c3RhbmRhcmQuIApmcmFtZSBjb21wcmVzc2lvbjogZGFydCBjb2RlYywgYmxvY2sgc2VxdWVuY2UgbGk=',
  ),

  /// modes_direct_4k_l1_w12 (libzstd 1.5.7, window_log override)
  _SpecialFrame(
    'modes_direct_4k_l1_w12',
    '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',
  ),
];
