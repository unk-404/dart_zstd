import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zstd_neo/zstd_neo.dart';

import 'fixtures/fixtures.g.dart';

Uint8List _b64(String encoded) => base64Decode(encoded);

ZstdFixture _fixture(String name) =>
    webFixtures.firstWhere((fixture) => fixture.name == name);

Uint8List _fixtureZst(String name) => _b64(_fixture(name).zstBase64);

Uint8List _fixtureBin(String name) => _b64(_fixture(name).binBase64);

Uint8List _fixtureDict(String name) => _b64(_fixture(name).dictBase64!);

ZstdInput _input(String name) =>
    webInputs.firstWhere((input) => input.name == name);

Uint8List _inputBytes(String name) => _b64(_input(name).binBase64);

/// Frames produced with `structdict.dict` attached at level 3 (libzstd 1.5.7).
/// The first one starts with Repeat_Mode for all three sequence tables, i.e.
/// its LL/OF/ML tables come from the dictionary. The second one additionally
/// starts with a treeless literals block, i.e. its Huffman table comes from the
/// dictionary.
const String _dictSequenceTablesFrame =
    'KLUv/WOvOoYEAAOVBwDECFsKICB7ImlkIjogMCwgIm5hbWUiOiAiaXRlbS0wMDAwIiwgInZhbHV0YWdzIjogWyJhbHBoYWJldGdhbW1hIl0sICJhY3RpdmZ9LDExNzkxOXRydTIyMTU4MzgzMzIzNzU3NDQzMTY3NjU1Mzk1OTU2NjQ3NTE0Nzc1NTQzMzg4NjMzNTI5OTcxMjcxJvwAMAdwwAD8QwHMATggAP66AGYCHDD4szG90QB6A0w8+Oc09U8B6AKAPuBfC40xE+CAwV+N6Q0F0B9g4oE/bDptFsABAZ/QKZalpDoAoAc4zV90PrLSuvr1jgi1BPs8UtOo/Q==';

const String _dictHuffmanFrame =
    'KLUv/WOvOoYEAAPlCQBDyRstvU0QB3qBkwkCvQDESegF0AucBIFekCCQky8AgV7gJPQCEMjJF4BALwBxoBeAQC9wQKB8AYiT0AtArnb4NqHMVeKWVnyNtJWUL3ibvs1JEEsfY+nUF7KLZuynRmoX5QukbS0ldG0J8tqndkZCW8FY/JELRMEfDr20DnDg4Aci5gBAQS2YfzsI0DPosaMHAWpBhH8d7DClUtQ1XBx4aQCxiNAr0wRD6RGA7iFHYWwFwABAiHAh2VUAhbyC+4JvLAPYXRAircKwfXQAOA5udohh8CGtFpQYCY4IKpIdoIA0PSp5E0ADsCARATGwLyQZTPcQzCEmwWWwu6DUBVBn0EXEbjJhKAUk2M9D0I2wS+BFRIwDjPMhmkGPatzSA5PE/vVXGhuzG9iH9ASZtbf6/neP9kANVlzlvSwS';

final class _CollectingSink implements Sink<List<int>> {
  final List<int> bytes = <int>[];
  bool closed = false;

  @override
  void add(List<int> data) {
    bytes.addAll(data);
  }

  @override
  void close() {
    closed = true;
  }
}

Uint8List _decodeStreaming(
  ZstdDecoder decoder,
  Uint8List input,
  int chunkSize,
) {
  final sink = _CollectingSink();
  final chunked = decoder.startChunkedConversion(sink);
  for (var at = 0; at < input.length; at += chunkSize) {
    final end = at + chunkSize < input.length ? at + chunkSize : input.length;
    chunked.add(Uint8List.sublistView(input, at, end));
  }
  chunked.close();
  expect(sink.closed, isTrue);
  return Uint8List.fromList(sink.bytes);
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

Uint8List _corruptCopy(Uint8List bytes, int index, [int mask = 0xFF]) {
  final copy = Uint8List.fromList(bytes);
  copy[index] ^= mask;
  return copy;
}

void main() {
  group('raw-content dictionary', () {
    test('decodes with the dictionary', () {
      final frame = _fixtureZst('rawdict');
      final dictionary = _fixtureDict('rawdict');
      expect(
        ZstdDecoder(dictionary: dictionary).decompress(frame),
        _fixtureBin('rawdict'),
      );
    });

    test('streams with the dictionary', () {
      final frame = _fixtureZst('rawdict');
      final dictionary = _fixtureDict('rawdict');
      final expected = _fixtureBin('rawdict');
      for (final chunkSize in <int>[1, 7, 64, 997]) {
        expect(
          _decodeStreaming(
            ZstdDecoder(dictionary: dictionary),
            frame,
            chunkSize,
          ),
          expected,
          reason: 'chunkSize=$chunkSize',
        );
      }
    });

    test('fails without the dictionary', () {
      _expectZstdException(
        () => const ZstdDecoder().decompress(_fixtureZst('rawdict')),
      );
    });

    test('fails with an empty dictionary', () {
      _expectZstdException(
        () =>
            ZstdDecoder(dictionary: Uint8List(0))
                .decompress(_fixtureZst('rawdict')),
      );
    });

    test('fails with a truncated dictionary', () {
      final dictionary = _fixtureDict('rawdict');
      final truncated = Uint8List.sublistView(dictionary, 0, 1024);
      _expectZstdException(
        () =>
            ZstdDecoder(dictionary: truncated)
                .decompress(_fixtureZst('rawdict')),
      );
    });

    test('fails with an unrelated dictionary', () {
      final structured = _fixtureDict('structdict');
      _expectZstdException(
        () =>
            ZstdDecoder(dictionary: structured)
                .decompress(_fixtureZst('rawdict')),
      );
    });
  });

  group('formatted dictionary', () {
    test('decodes with the dictionary', () {
      final frame = _fixtureZst('structdict');
      final dictionary = _fixtureDict('structdict');
      expect(
        ZstdDecoder(dictionary: dictionary).decompress(frame),
        _fixtureBin('structdict'),
      );
    });

    test('streams with the dictionary', () {
      final frame = _fixtureZst('structdict');
      final dictionary = _fixtureDict('structdict');
      final expected = _fixtureBin('structdict');
      for (final chunkSize in <int>[1, 7, 64, 997]) {
        expect(
          _decodeStreaming(
            ZstdDecoder(dictionary: dictionary),
            frame,
            chunkSize,
          ),
          expected,
          reason: 'chunkSize=$chunkSize',
        );
      }
    });

    test('requires the dictionary', () {
      _expectZstdException(
        () => const ZstdDecoder().decompress(_fixtureZst('structdict')),
        code: ZstdErrorCode.dictionaryRequired,
      );
    });

    test('empty dictionary is treated as missing', () {
      _expectZstdException(
        () =>
            ZstdDecoder(dictionary: Uint8List(0))
                .decompress(_fixtureZst('structdict')),
        code: ZstdErrorCode.dictionaryRequired,
      );
    });

    test('rejects a dictionary with the wrong id', () {
      final dictionary = _fixtureDict('structdict');
      final wrongId = _corruptCopy(dictionary, 4, 0x01);
      _expectZstdException(
        () =>
            ZstdDecoder(dictionary: wrongId)
                .decompress(_fixtureZst('structdict')),
        code: ZstdErrorCode.dictionaryMismatch,
      );
    });

    test('rejects a raw dictionary for a formatted-dictionary frame', () {
      final raw = _fixtureDict('rawdict');
      _expectZstdException(
        () =>
            ZstdDecoder(dictionary: raw).decompress(_fixtureZst('structdict')),
        code: ZstdErrorCode.dictionaryMismatch,
      );
    });

    test('rejects a truncated formatted dictionary', () {
      final dictionary = _fixtureDict('structdict');
      for (final length in <int>[1, 4, 8, 9, 40, 100]) {
        final truncated = Uint8List.sublistView(dictionary, 0, length);
        _expectZstdException(
          () =>
              ZstdDecoder(dictionary: truncated)
                  .decompress(_fixtureZst('structdict')),
          code: null,
        );
      }
    });

    test('rejects a corrupted formatted dictionary header', () {
      final dictionary = _fixtureDict('structdict');
      final corrupted = _corruptCopy(dictionary, 0, 0x01);
      _expectZstdException(
        () =>
            ZstdDecoder(dictionary: corrupted)
                .decompress(_fixtureZst('structdict')),
      );
    });

    test('decoder does not modify the dictionary buffer', () {
      final dictionary = _fixtureDict('structdict');
      final before = Uint8List.fromList(dictionary);
      final decoder = ZstdDecoder(dictionary: dictionary);
      final expected = _fixtureBin('structdict');
      expect(decoder.decompress(_fixtureZst('structdict')), expected);
      expect(decoder.decompress(_fixtureZst('structdict')), expected);
      expect(dictionary, before);
    });

    test('uses sequence tables from the formatted dictionary', () {
      final frame = _b64(_dictSequenceTablesFrame);
      final dictionary = _fixtureDict('structdict');
      expect(
        ZstdDecoder(dictionary: dictionary).decompress(frame),
        Uint8List.sublistView(_inputBytes('json_4k'), 0, 1024),
      );
      _expectZstdException(
        () => const ZstdDecoder().decompress(frame),
        code: ZstdErrorCode.dictionaryRequired,
      );
    });

    test('uses the Huffman table from the formatted dictionary', () {
      final frame = _b64(_dictHuffmanFrame);
      final dictionary = _fixtureDict('structdict');
      expect(
        ZstdDecoder(dictionary: dictionary).decompress(frame),
        Uint8List.sublistView(_inputBytes('text_4k'), 0, 1024),
      );
      _expectZstdException(
        () => const ZstdDecoder().decompress(frame),
        code: ZstdErrorCode.dictionaryRequired,
      );
    });
  });

  group('dictionary interaction', () {
    test('decoder instances do not share state', () {
      final structured = ZstdDecoder(dictionary: _fixtureDict('structdict'));
      expect(
        structured.decompress(_fixtureZst('structdict')),
        _fixtureBin('structdict'),
      );
      final raw = ZstdDecoder(dictionary: _fixtureDict('rawdict'));
      expect(raw.decompress(_fixtureZst('rawdict')), _fixtureBin('rawdict'));
      // The first decoder still works after another one ran.
      expect(
        structured.decompress(_fixtureZst('structdict')),
        _fixtureBin('structdict'),
      );
    });

    test('maxWindowSize still applies to dictionary frames', () {
      final frame = _fixtureZst('structdict');
      final dictionary = _fixtureDict('structdict');
      _expectZstdException(
        () => ZstdDecoder(
          dictionary: dictionary,
          maxWindowSize: 1024,
        ).decompress(frame),
        code: ZstdErrorCode.windowTooLarge,
      );
    });

    test('checksum verification is independent of dictionaries', () {
      final frame = _fixtureZst('text_4k_checksum');
      final corrupted = _corruptCopy(frame, frame.length - 1, 0x01);
      final dictionary = _fixtureDict('rawdict');
      // A dictionary may be supplied even when the frame does not need one.
      expect(
        ZstdDecoder(
          dictionary: dictionary,
          verifyChecksum: false,
        ).decompress(corrupted),
        _fixtureBin('text_4k_checksum'),
      );
    });
  });
}
