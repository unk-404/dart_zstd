@TestOn('vm')
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zstd_neo/src/common/xxh64_native.dart' as native;
import 'package:zstd_neo/src/common/xxh64_web.dart' as web;

String _nativeHex(native.Xxh64Digest digest) => digest.toHexString();
String _webHex(web.Xxh64Digest digest) => digest.toHexString();

native.Xxh64Digest _native(Uint8List data, {int seed = 0, int chunk = -1}) {
  final hasher = native.Xxh64(seed);
  if (chunk <= 0) {
    hasher.update(data);
  } else {
    for (var i = 0; i < data.length; i += chunk) {
      hasher.update(data, i, min(i + chunk, data.length));
    }
  }
  return hasher.digest();
}

web.Xxh64Digest _web(Uint8List data, {int seed = 0, int chunk = -1}) {
  final hasher = web.Xxh64(seed);
  if (chunk <= 0) {
    hasher.update(data);
  } else {
    for (var i = 0; i < data.length; i += chunk) {
      hasher.update(data, i, min(i + chunk, data.length));
    }
  }
  return hasher.digest();
}

void main() {
  test('web implementation matches the reference vectors', () {
    const vectors = {
      '': 'ef46db3751d8e999',
      'a': 'd24ec4f1a98c6e5b',
      'abc': '44bc2cf5ad770999',
      'message digest': '066ed728fceeb3be',
      'abcdefghijklmnopqrstuvwxyz': 'cfe1f278fa89835c',
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef':
          '1af3ac4760fe2f85',
    };
    vectors.forEach((input, expected) {
      expect(_webHex(_web(Uint8List.fromList(input.codeUnits))), expected);
    });
  });

  test('native and web agree for every length 0..300', () {
    final random = Random(42);
    for (var length = 0; length <= 300; length++) {
      final data = Uint8List.fromList(
        List<int>.generate(length, (_) => random.nextInt(256)),
      );
      expect(
        _nativeHex(_native(data)),
        _webHex(_web(data)),
        reason: 'len=$length',
      );
    }
  });

  test('chunked web updates agree with native one-shot updates', () {
    final random = Random(7);
    for (var length = 0; length <= 200; length++) {
      final data = Uint8List.fromList(
        List<int>.generate(length, (_) => random.nextInt(256)),
      );
      final expected = _nativeHex(_native(data));
      for (final chunk in [1, 2, 3, 7, 31, 32, 33, 64]) {
        expect(
          _webHex(_web(data, chunk: chunk)),
          expected,
          reason: 'len=$length chunk=$chunk',
        );
      }
    }
  });
}
