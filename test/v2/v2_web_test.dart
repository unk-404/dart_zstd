// Cross-platform (VM, Chrome JS, Chrome dart2wasm) checks for the v2 decoder.
//
// Uses only base64 fixture constants, so the same test runs on the web. It
// compares the v2 engine against the expected plaintext and against the v0.1.2
// decoder output for the shared fixture matrix.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zstd_neo/src/decompress/decoder.dart' as v1;
import 'package:zstd_neo/src/v2/decompress/decoder.dart' as v2;

import '../fixtures/fixtures.g.dart';

const int _slack = 1 << 17;

void main() {
  test('v2 decodes web fixtures and matches v0.1.2', () {
    final oldDecoder = v1.ZstdDecoder(maxWindowSize: 1 << 30);
    for (final fixture in webFixtures) {
      final zst = base64Decode(fixture.zstBase64);
      final expected = base64Decode(fixture.binBase64);
      final dictionary = fixture.dictBase64 == null
          ? null
          : base64Decode(fixture.dictBase64!);
      final decoder = v2.V2ZstdDecoder(
        dictionary: dictionary,
        maxWindowSize: 1 << 30,
      );
      final dst = Uint8List(expected.length + _slack);
      final written = decoder.decodeInto(zst, dst);
      expect(written, expected.length, reason: fixture.name);
      expect(
        Uint8List.sublistView(dst, 0, written),
        expected,
        reason: fixture.name,
      );
      if (dictionary == null) {
        expect(
          Uint8List.sublistView(dst, 0, written),
          oldDecoder.decompress(zst),
          reason: '${fixture.name} vs v0.1.2',
        );
      }
    }
  });

  test('v2 decompress() convenience works on the web', () {
    final fixture = webFixtures.first;
    final zst = base64Decode(fixture.zstBase64);
    final expected = base64Decode(fixture.binBase64);
    expect(v2.V2ZstdDecoder().decompress(zst), expected);
  });
}
