import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
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

ZstdInput _input(String name) =>
    webInputs.firstWhere((input) => input.name == name);

Uint8List _inputBytes(String name) => _b64(_input(name).binBase64);

/// Multi-block frames compressed with a forced 1 KiB window, so the streaming
/// ring buffer has to wrap and grow while decoding them.
final class _ModeFrame {
  const _ModeFrame(this.name, this.zstBase64, this.inputName, this.prefix);

  final String name;
  final String zstBase64;
  final String inputName;
  final int prefix;
}

const List<_ModeFrame> _modeFrames = <_ModeFrame>[
  _ModeFrame(
    'modes_json_2k_l9_w10',
    'KLUv/UAAAAfcBQCSiR4cYEXr1plxhPS81UANLQoAQOZWVijVnE0yxE0MA+tonTHUzGot5tTtnrY9KdWsGXcrV8speTsj5sWrFyFlEdky3zUBLkH+kE3d8mLhNc1AH8I/oiNoGn2EAnk1smlyfHQK8oum0XPOEUAXn2ZTBz+haU42NTwFyAwYAR+oEKhBxP0a1nCTgswBEBIBERIBJnGa/0/hAYDZ82sOYRtx3fQsX+je2jVk3fT9OegFKw3OTpM4eRrskBtTtQIAQwQKq9JpxlBqlNZipBK7p+NKqV6+upVaZ1PyxBDzQqcZQuysr93DlvmuBh/sYHPEOsPG54RTVtdPLdUAu+MkjLVKvuCoCfuceZRVohogptHk8z8PjA8=',
    'json_4k',
    2048,
  ),
  _ModeFrame(
    'modes_binary_2k_l19_w10',
    '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',
    'binary_4k',
    2048,
  ),
  _ModeFrame(
    'modes_text_2k_l19_w10',
    'KLUv/UAAAAccBwCyCx8RsD1sraJDu1kDz+Cmk7W8lRPAQfN6g2VvdrDN3gy8l73Bsm8zWG/2Buy97KB5vcGy95u4tLEX1y/TFxY7cRyySkI03oz19fuegG0V/kW4k5F15qbwPp60/GO9dA8XDZbE+njCxsYXyPZiB8J/TbGxr8IrS14gK0RYl9/EQ6DxzFb7P2vgXlAoFgPEITrJmNBRrTtbCDtRTs/QI0HKwQhBsdul1eCeE2kISiIX7jUDiFzOKCBPEEQC2UPIse2puJBWnlEsPy9i7C9eRUi3HST3EmI54oN4XIa96lr/GF1JFTUBAFkKF/BuE2SUHgqqB4pyxkFFgFHOGKgyOMoDChWBRXkgoXMIKAMC',
    'text_4k',
    2048,
  ),
];

final class _CollectingSink implements Sink<List<int>> {
  final List<int> bytes = <int>[];
  int chunks = 0;
  bool closed = false;
  int largestChunk = 0;

  @override
  void add(List<int> data) {
    chunks++;
    if (data.length > largestChunk) largestChunk = data.length;
    bytes.addAll(data);
  }

  @override
  void close() {
    closed = true;
  }
}

/// Feeds [input] in chunks whose end offsets are [boundaries] (must end with
/// `input.length`).
Uint8List _decodeChunked(
  ZstdDecoder decoder,
  Uint8List input,
  List<int> boundaries,
) {
  final sink = _CollectingSink();
  final chunked = decoder.startChunkedConversion(sink);
  var previous = 0;
  for (final boundary in boundaries) {
    chunked.add(Uint8List.sublistView(input, previous, boundary));
    previous = boundary;
  }
  chunked.close();
  expect(sink.closed, isTrue, reason: 'downstream sink must be closed');
  return Uint8List.fromList(sink.bytes);
}

List<int> _uniformBoundaries(int length, int chunkSize) {
  final boundaries = <int>[];
  for (var at = chunkSize; at < length; at += chunkSize) {
    boundaries.add(at);
  }
  boundaries.add(length);
  return boundaries;
}

List<int> _randomBoundaries(int length, Random random) {
  final boundaries = <int>[];
  var at = 0;
  while (at < length) {
    at += 1 + random.nextInt(41);
    if (at >= length) break;
    boundaries.add(at);
  }
  boundaries.add(length);
  return boundaries;
}

const List<int> _magic = <int>[0x28, 0xB5, 0x2F, 0xFD];

List<int> _blockHeader({
  required bool last,
  required int type,
  required int size,
}) {
  final value = (last ? 1 : 0) | (type << 1) | (size << 3);
  return <int>[value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF];
}

Uint8List _singleSegmentFrame(List<int> payload) {
  final content = Uint8List.fromList(payload);
  return Uint8List.fromList(<int>[
    ..._magic,
    (1 << 5),
    content.length,
    ..._blockHeader(last: true, type: 0, size: content.length),
    ...content,
  ]);
}

Uint8List _twoBlockFrame(Uint8List first, Uint8List second) {
  final builder = BytesBuilder(copy: false)
    ..add(_magic)
    ..add(<int>[0x00, 11 << 3])
    ..add(_blockHeader(last: false, type: 0, size: first.length))
    ..add(first)
    ..add(_blockHeader(last: true, type: 0, size: second.length))
    ..add(second);
  return builder.toBytes();
}

Uint8List _skippableFrame(List<int> userData) {
  final builder = BytesBuilder(copy: false)
    ..add(<int>[0x50, 0x2A, 0x4D, 0x18])
    ..add(<int>[userData.length & 0xFF, (userData.length >> 8) & 0xFF, 0, 0])
    ..add(userData);
  return builder.toBytes();
}

Uint8List _corruptCopy(Uint8List bytes, int index, [int mask = 0xFF]) {
  final copy = Uint8List.fromList(bytes);
  copy[index] ^= mask;
  return copy;
}

// ---------------------------------------------------------------------------

void main() {
  group('streaming equals one-shot', () {
    for (final fixture in webFixtures) {
      test('${fixture.name} with many chunk sizes', () {
        final compressed = _b64(fixture.zstBase64);
        final expected = _b64(fixture.binBase64);
        final dictionary = fixture.dictBase64 == null
            ? null
            : _b64(fixture.dictBase64!);
        for (final chunkSize in <int>[1, 2, 3, 7, 31, 32, 33, 64, 257]) {
          final decoded = _decodeChunked(
            ZstdDecoder(dictionary: dictionary),
            compressed,
            _uniformBoundaries(compressed.length, chunkSize),
          );
          expect(
            decoded,
            expected,
            reason: '${fixture.name} chunkSize=$chunkSize',
          );
        }
      });
    }

    test('random chunk sizes', () {
      final random = Random(424242);
      for (final fixture in webFixtures) {
        final compressed = _b64(fixture.zstBase64);
        final expected = _b64(fixture.binBase64);
        final dictionary = fixture.dictBase64 == null
            ? null
            : _b64(fixture.dictBase64!);
        for (var iteration = 0; iteration < 3; iteration++) {
          final decoded = _decodeChunked(
            ZstdDecoder(dictionary: dictionary),
            compressed,
            _randomBoundaries(compressed.length, random),
          );
          expect(
            decoded,
            expected,
            reason: '${fixture.name} iteration=$iteration',
          );
        }
      }
    });

    test('whole frame in a single add', () {
      final compressed = _fixtureZst('text_16k_l3');
      expect(
        _decodeChunked(const ZstdDecoder(), compressed, <int>[
          compressed.length,
        ]),
        _fixtureBin('text_16k_l3'),
      );
    });

    test('empty chunks are harmless', () {
      final compressed = _fixtureZst('text_4k_nochecksum');
      final sink = _CollectingSink();
      final chunked = const ZstdDecoder().startChunkedConversion(sink);
      chunked.add(Uint8List(0));
      chunked.add(Uint8List.sublistView(compressed, 0, 100));
      chunked.add(Uint8List(0));
      chunked.add(Uint8List.sublistView(compressed, 100, compressed.length));
      chunked.close();
      expect(Uint8List.fromList(sink.bytes), _fixtureBin('text_4k_nochecksum'));
    });
  });

  group('streaming structure', () {
    test('emits chunks before close', () {
      final first = _fixtureZst('text_4k_nochecksum');
      final second = _fixtureZst('text_4k_checksum');
      final expectedFirst = _fixtureBin('text_4k_nochecksum');
      final expectedSecond = _fixtureBin('text_4k_checksum');

      final sink = _CollectingSink();
      final chunked = const ZstdDecoder().startChunkedConversion(sink);
      chunked.add(first);

      // The first frame is complete, so its output must already be visible.
      expect(sink.bytes, isNotEmpty);
      expect(Uint8List.fromList(sink.bytes), expectedFirst);
      expect(sink.closed, isFalse);

      chunked.add(second);
      chunked.close();
      expect(sink.closed, isTrue);
      expect(
        Uint8List.fromList(sink.bytes),
        Uint8List.fromList(<int>[...expectedFirst, ...expectedSecond]),
      );
    });

    test('streams multiple frames and skippable frames', () {
      final first = _fixtureZst('text_4k_nochecksum');
      final second = _fixtureZst('json_4k_contentsize');
      final stream = Uint8List.fromList(<int>[
        ..._skippableFrame(const <int>[7, 7, 7]),
        ...first,
        ..._skippableFrame(const <int>[1, 2]),
        ...second,
      ]);
      final expected = Uint8List.fromList(<int>[
        ..._fixtureBin('text_4k_nochecksum'),
        ..._fixtureBin('json_4k_contentsize'),
      ]);
      expect(
        _decodeChunked(
          const ZstdDecoder(),
          stream,
          _uniformBoundaries(stream.length, 13),
        ),
        expected,
      );
    });

    test('synthetic multi-block frame', () {
      final first = Uint8List.fromList(List<int>.filled(400, 0x61));
      final second = Uint8List.fromList(List<int>.filled(900, 0x62));
      final frame = _twoBlockFrame(first, second);
      final expected = Uint8List.fromList(<int>[...first, ...second]);
      expect(
        _decodeChunked(
          const ZstdDecoder(),
          frame,
          _uniformBoundaries(frame.length, 1),
        ),
        expected,
      );
    });

    test('synthetic concatenated frames', () {
      final first = Uint8List.fromList(utf8.encode('stream frame one'));
      final second = Uint8List.fromList(utf8.encode('stream frame two'));
      final stream = Uint8List.fromList(<int>[
        ..._singleSegmentFrame(first),
        ..._singleSegmentFrame(second),
      ]);
      expect(
        _decodeChunked(
          const ZstdDecoder(),
          stream,
          _uniformBoundaries(stream.length, 3),
        ),
        Uint8List.fromList(<int>[...first, ...second]),
      );
    });

    test('ByteConversionSink.withCallback is flushed on close', () {
      // Regression test: the decoder must close the downstream sink, otherwise
      // buffering sinks never deliver their data.
      final compressed = _fixtureZst('text_4k_checksum');
      final out = <int>[];
      final chunked = const ZstdDecoder().startChunkedConversion(
        ByteConversionSink.withCallback(out.addAll),
      );
      var previous = 0;
      for (final boundary in _uniformBoundaries(compressed.length, 97)) {
        chunked.add(Uint8List.sublistView(compressed, previous, boundary));
        previous = boundary;
      }
      chunked.close();
      expect(out, _fixtureBin('text_4k_checksum'));
    });

    test('small-window multi-block frames exercise the ring buffer', () {
      for (final frame in _modeFrames) {
        final compressed = _b64(frame.zstBase64);
        final expected = Uint8List.sublistView(
          _inputBytes(frame.inputName),
          0,
          frame.prefix,
        );
        for (final chunkSize in <int>[1, 2, 3, 7, 31, 33, 64]) {
          expect(
            _decodeChunked(
              const ZstdDecoder(),
              compressed,
              _uniformBoundaries(compressed.length, chunkSize),
            ),
            expected,
            reason: '${frame.name} chunkSize=$chunkSize',
          );
        }
      }
    });

    test('output chunks never exceed the maximum block size', () {
      final compressed = _fixtureZst('text_16k_l19');
      final sink = _CollectingSink();
      final chunked = const ZstdDecoder().startChunkedConversion(sink);
      var previous = 0;
      for (final boundary in _uniformBoundaries(compressed.length, 11)) {
        chunked.add(Uint8List.sublistView(compressed, previous, boundary));
        previous = boundary;
      }
      chunked.close();
      expect(sink.chunks, greaterThan(0));
      expect(sink.largestChunk, lessThanOrEqualTo(128 * 1024));
    });

    test('addSlice works with isLast', () {
      final compressed = _fixtureZst('text_4k_nochecksum');
      final sink = _CollectingSink();
      final chunked = const ZstdDecoder().startChunkedConversion(sink);
      final half = compressed.length ~/ 2;
      chunked.addSlice(compressed, 0, half, false);
      chunked.addSlice(compressed, half, compressed.length, true);
      expect(sink.closed, isTrue);
      expect(sink.bytes, _fixtureBin('text_4k_nochecksum'));
    });

    test('addSlice with isLast=false requires close', () {
      final compressed = _fixtureZst('json_4k_contentsize');
      final sink = _CollectingSink();
      final chunked = const ZstdDecoder().startChunkedConversion(sink);
      chunked.addSlice(compressed, 0, compressed.length, false);
      expect(sink.closed, isFalse);
      chunked.close();
      expect(sink.closed, isTrue);
      expect(sink.bytes, _fixtureBin('json_4k_contentsize'));
    });

    test('empty frame with a checksum', () {
      final frame = _b64('KLUv/SQAAQAAmenYUQ==');
      final sink = _CollectingSink();
      final chunked = const ZstdDecoder().startChunkedConversion(sink);
      var previous = 0;
      for (final boundary in _uniformBoundaries(frame.length, 4)) {
        chunked.add(Uint8List.sublistView(frame, previous, boundary));
        previous = boundary;
      }
      chunked.close();
      expect(sink.bytes, isEmpty);
      expect(sink.closed, isTrue);
    });
  });

  group('streaming errors', () {
    test('closing without input throws', () {
      final sink = _CollectingSink();
      final chunked = const ZstdDecoder().startChunkedConversion(sink);
      expect(chunked.close, throwsA(isA<ZstdException>()));
    });

    test('closing an incomplete frame throws', () {
      final compressed = _fixtureZst('text_16k_l3');
      final sink = _CollectingSink();
      final chunked = const ZstdDecoder().startChunkedConversion(sink);
      chunked.add(Uint8List.sublistView(compressed, 0, compressed.length - 5));
      expect(chunked.close, throwsA(isA<ZstdException>()));
    });

    test('truncated input in the middle of the header throws', () {
      final compressed = _fixtureZst('text_16k_l3');
      expect(() {
        final sink = _CollectingSink();
        final chunked = const ZstdDecoder().startChunkedConversion(sink);
        chunked.add(Uint8List.sublistView(compressed, 0, 2));
        chunked.close();
      }, throwsA(isA<ZstdException>()));
    });

    test('corrupted checksum throws during add or close', () {
      final frame = _fixtureZst('text_4k_checksum');
      final corrupted = _corruptCopy(frame, frame.length - 1, 0x01);
      expect(
        () {
          final sink = _CollectingSink();
          final chunked = const ZstdDecoder().startChunkedConversion(sink);
          var previous = 0;
          for (final boundary in _uniformBoundaries(corrupted.length, 37)) {
            chunked.add(Uint8List.sublistView(corrupted, previous, boundary));
            previous = boundary;
          }
          chunked.close();
        },
        throwsA(
          isA<ZstdException>().having(
            (error) => error.code,
            'code',
            ZstdErrorCode.checksumMismatch,
          ),
        ),
      );
    });

    test('windowTooLarge is raised while streaming', () {
      final frame = _fixtureZst('text_16k_l3');
      expect(
        () {
          final sink = _CollectingSink();
          final chunked = ZstdDecoder(maxWindowSize: 1024)
              .startChunkedConversion(sink);
          chunked.add(frame);
        },
        throwsA(
          isA<ZstdException>().having(
            (error) => error.code,
            'code',
            ZstdErrorCode.windowTooLarge,
          ),
        ),
      );
    });

    test('adding after close throws StateError', () {
      final compressed = _fixtureZst('golden_zero_seq_2b');
      final sink = _CollectingSink();
      final chunked = const ZstdDecoder().startChunkedConversion(sink);
      chunked.add(compressed);
      chunked.close();
      expect(() => chunked.add(compressed), throwsStateError);
    });

    test('garbage input throws', () {
      expect(() {
        final sink = _CollectingSink();
        final chunked = const ZstdDecoder().startChunkedConversion(sink);
        chunked.add(Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8]));
        chunked.close();
      }, throwsA(isA<ZstdException>()));
    });
  });
}
