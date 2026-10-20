// Conformance tests against frames produced by the official zstd
// `decodecorpus` generator.
//
// The corpus under test/conformance/ is committed: zst/ holds the frames,
// bin/ holds the exact plaintext for each frame, and manifest.json records
// the generator version, seeds, options, sizes and SHA-256 digests.
//
// This test uses dart:io and is therefore VM-only; browser test suites skip
// it via @TestOn. Regenerate the corpus with tool/conformance/regenerate.sh.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zstd_neo/zstd_neo.dart';

const String _corpusDir = 'test/conformance';
const int _windowLimit = 1 << 30;

void main() {
  final manifestFile = File('$_corpusDir/manifest.json');
  if (!manifestFile.existsSync()) {
    test('conformance corpus is present', () {
      fail(
        'Missing ${manifestFile.path}. Restore the committed corpus or run '
        'tool/conformance/regenerate.sh.',
      );
    });
    return;
  }

  final manifest =
      jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
  final frames = (manifest['frames'] as List<dynamic>)
      .cast<Map<String, dynamic>>();
  final groups = (manifest['groups'] as List<dynamic>)
      .cast<Map<String, dynamic>>();

  final decoder = ZstdDecoder(maxWindowSize: _windowLimit);

  test('manifest matches the committed corpus', () {
    expect(manifest['schemaVersion'], 1);

    final generator = manifest['generator'] as Map<String, dynamic>;
    expect(generator['name'], 'decodecorpus');
    expect(generator['zstdVersion'], isA<String>());
    expect((generator['zstdVersion'] as String), isNotEmpty);

    final totals = manifest['totals'] as Map<String, dynamic>;
    expect(totals['frames'], frames.length);

    var zstBytes = 0;
    var binBytes = 0;
    for (final frame in frames) {
      final zst = File('$_corpusDir/${frame['zst']}');
      final bin = File('$_corpusDir/${frame['bin']}');
      expect(zst.existsSync(), isTrue, reason: 'missing ${zst.path}');
      expect(bin.existsSync(), isTrue, reason: 'missing ${bin.path}');
      expect(
        zst.lengthSync(),
        frame['zstBytes'],
        reason: 'size changed for ${zst.path}',
      );
      expect(
        bin.lengthSync(),
        frame['binBytes'],
        reason: 'size changed for ${bin.path}',
      );
      zstBytes += zst.lengthSync();
      binBytes += bin.lengthSync();
    }
    expect(zstBytes, totals['zstBytes'], reason: 'manifest zst byte total');
    expect(binBytes, totals['binBytes'], reason: 'manifest bin byte total');

    var groupFrames = 0;
    for (final group in groups) {
      final name = group['name'] as String;
      final members = frames.where((frame) => frame['group'] == name).length;
      expect(members, group['frameCount'], reason: 'group $name frame count');
      groupFrames += members;
      expect(group['firstSeed'], isA<int>(), reason: 'group $name firstSeed');
      expect(group['lastSeed'], isA<int>(), reason: 'group $name lastSeed');
    }
    expect(groupFrames, frames.length, reason: 'groups cover every frame');
  });

  group('decodecorpus frames', () {
    for (final frame in frames) {
      final group = frame['group'] as String;
      final options = (frame['options'] as List<dynamic>).cast<String>();
      final label =
          '$group/${frame['zst']} '
          'seed=${frame['seed']} options=${options.join(' ')}';

      test('${frame['zst']}', () {
        final zst = File('$_corpusDir/${frame['zst']}').readAsBytesSync();
        final expected = File('$_corpusDir/${frame['bin']}').readAsBytesSync();

        final Uint8List actual;
        try {
          actual = decoder.decompress(zst);
        } on ZstdException catch (error) {
          fail('$label: decoder rejected a valid frame: $error');
        } catch (error) {
          fail('$label: unexpected ${error.runtimeType}: $error');
        }

        if (actual.length != expected.length) {
          fail(
            '$label: decoded ${actual.length} bytes, '
            'expected ${expected.length}',
          );
        }
        final mismatch = _firstDifference(actual, expected);
        if (mismatch >= 0) {
          fail(
            '$label: byte $mismatch differs '
            '(decoded ${actual[mismatch]}, expected ${expected[mismatch]})',
          );
        }
      });
    }
  });

  group('malformed and edge-case frames', () {
    test('empty input is rejected', () {
      _expectCode(<int>[], ZstdErrorCode.truncatedInput);
    });

    test('truncated frame is rejected with a ZstdException', () {
      final full = File('$_corpusDir/${frames.first['zst']}').readAsBytesSync();
      expect(full.length, greaterThan(12));
      _expectCode(
        full.sublist(0, full.length - 4),
        ZstdErrorCode.truncatedInput,
      );
    });

    test('corrupt magic is rejected', () {
      final valid = File('$_corpusDir/${frames.first['zst']}')
          .readAsBytesSync();
      final corrupt = Uint8List.fromList(valid)..[0] = 0x00;
      _expectCode(corrupt, ZstdErrorCode.invalidMagic);
    });

    test('raw block that overruns the input is rejected', () {
      final frame = _frame(
        frameHeaderDescriptor: 0x00,
        windowDescriptor: 0x00,
        blockHeader: _rawBlockHeader(10),
        content: const <int>[0x61, 0x62, 0x63],
      );
      _expectCode(frame, ZstdErrorCode.truncatedInput);
    });

    test('8-byte Frame_Content_Size with small content decodes', () {
      final frame = _frame(
        frameHeaderDescriptor: 0xE0, // single segment, 8-byte FCS
        fcs: _le(3, 8),
        blockHeader: _rawBlockHeader(3),
        content: const <int>[0x61, 0x62, 0x63],
      );
      expect(utf8.decode(decoder.decompress(frame)), 'abc');
    });

    test('smallest window descriptor (1 KiB) decodes', () {
      final frame = _frame(
        frameHeaderDescriptor: 0x00, // no content size, no single segment
        windowDescriptor: 0x00,
        blockHeader: _rawBlockHeader(3),
        content: const <int>[0x61, 0x62, 0x63],
      );
      expect(utf8.decode(decoder.decompress(frame)), 'abc');
    });

    test('oversized window descriptor is rejected as windowTooLarge', () {
      final frame = _frame(
        frameHeaderDescriptor: 0x00,
        windowDescriptor: 0xFF, // window log 41, far above the 1 GiB limit
        blockHeader: _rawBlockHeader(3),
        content: const <int>[0x61, 0x62, 0x63],
      );
      _expectCode(frame, ZstdErrorCode.windowTooLarge);
    });

    test('skippable-only stream decodes to empty output', () {
      final frame = <int>[
        0x50, 0x2A, 0x4D, 0x18, 4, 0, 0, 0, 1, 2, 3, 4, //
      ];
      expect(decoder.decompress(Uint8List.fromList(frame)), isEmpty);
    });
  });
}

void _expectCode(List<int> input, ZstdErrorCode expected) {
  try {
    ZstdDecoder(maxWindowSize: _windowLimit)
        .decompress(Uint8List.fromList(input));
  } on ZstdException catch (error) {
    expect(error.code, expected, reason: 'unexpected error code: $error');
    return;
  } catch (error) {
    fail(
      'expected ZstdException(${expected.name}), got '
      '${error.runtimeType}: $error',
    );
  }
  fail('expected ZstdException(${expected.name}), input decoded successfully');
}

int _firstDifference(Uint8List actual, Uint8List expected) {
  final length = actual.length < expected.length
      ? actual.length
      : expected.length;
  for (var i = 0; i < length; i++) {
    if (actual[i] != expected[i]) return i;
  }
  return actual.length == expected.length ? -1 : length;
}

Uint8List _frame({
  required int frameHeaderDescriptor,
  int? windowDescriptor,
  List<int>? fcs,
  required List<int> blockHeader,
  required List<int> content,
}) {
  return Uint8List.fromList(<int>[
    0x28,
    0xB5,
    0x2F,
    0xFD,
    frameHeaderDescriptor,
    ?windowDescriptor,
    ...?fcs,
    ...blockHeader,
    ...content,
  ]);
}

List<int> _rawBlockHeader(int size, {bool last = true}) => <int>[
  (last ? 1 : 0) | (size << 3),
  (size >> 5) & 0xFF,
  (size >> 13) & 0xFF,
];

List<int> _le(int value, int byteCount) => <int>[
  for (var i = 0; i < byteCount; i++) (value >> (8 * i)) & 0xFF,
];
