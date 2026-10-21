// Development tests for the v2 decoder engine.
//
// VM-only: the conformance corpus is read from disk. The v2 engine is expected
// to match the v0.1.2 decoder byte-for-byte and to decode every committed
// official decodecorpus frame.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zstd_neo/src/common/errors.dart';
import 'package:zstd_neo/src/decompress/decoder.dart' as v1;
import 'package:zstd_neo/src/v2/decompress/decoder.dart' as v2;

const String _corpusDir = 'test/conformance';
const int _windowLimit = 1 << 30;
const int _slack = 1 << 17;

void main() {
  final manifestFile = File('$_corpusDir/manifest.json');
  if (!manifestFile.existsSync()) {
    test('conformance corpus is present', () => fail('missing corpus'));
    return;
  }
  final manifest =
      jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
  final frames = (manifest['frames'] as List<dynamic>)
      .cast<Map<String, dynamic>>();

  test('v2 decodes all ${frames.length} official conformance frames', () {
    final decoder = v2.V2ZstdDecoder(maxWindowSize: _windowLimit);
    final failures = <String>[];
    for (final frame in frames) {
      final zst = File('$_corpusDir/${frame['zst']}').readAsBytesSync();
      final bin = File('$_corpusDir/${frame['bin']}').readAsBytesSync();
      final dst = Uint8List(bin.length + _slack);
      final written = decoder.decodeInto(zst, dst);
      if (written != bin.length) {
        failures.add('${frame['zst']}: length $written != ${bin.length}');
        continue;
      }
      for (var i = 0; i < written; i++) {
        if (dst[i] != bin[i]) {
          failures.add('${frame['zst']}: byte $i differs');
          break;
        }
      }
    }
    expect(failures, isEmpty, reason: failures.take(20).join('\n'));
  });

  test('v2 matches v0.1.2 on Silesia benchmark frames', () {
    final oldDecoder = v1.ZstdDecoder(maxWindowSize: _windowLimit);
    final newDecoder = v2.V2ZstdDecoder(maxWindowSize: _windowLimit);
    final cases = <String>[
      'dickens.l3',
      'dickens.l19',
      'xml.l3',
      'xml.l19',
      'x-ray.l3',
      'x-ray.l19',
      'osdb.l3',
      'osdb.l19',
    ];
    for (final name in cases) {
      final zst = File('benchmark/bench_data/$name.zst').readAsBytesSync();
      final expected = oldDecoder.decompress(zst);
      final dst = Uint8List(expected.length + _slack);
      final written = newDecoder.decodeInto(zst, dst);
      expect(written, expected.length, reason: name);
      expect(Uint8List.sublistView(dst, 0, written), expected, reason: name);
    }
  });

  test('v2 rejects a checksum mismatch', () {
    final zst = File('benchmark/bench_data/dickens.l3.zst').readAsBytesSync();
    final corrupted = Uint8List.fromList(zst);
    corrupted[corrupted.length - 1] ^= 0xFF;
    final dst = Uint8List(1 << 20);
    expect(
      () => v2.V2ZstdDecoder().decodeInto(corrupted, dst),
      throwsA(isA<ZstdException>()),
    );
  });
}
