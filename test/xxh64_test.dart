import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zstd_neo/src/common/xxh64.dart';

String _hex(Xxh64Digest digest) => digest.toHexString();

Xxh64Digest _hash(Uint8List data, {int seed = 0, int chunk = -1}) {
  final hasher = Xxh64(seed);
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
  const vectors = {
    '': 'ef46db3751d8e999',
    'a': 'd24ec4f1a98c6e5b',
    'abc': '44bc2cf5ad770999',
    'message digest': '066ed728fceeb3be',
    'abcdefghijklmnopqrstuvwxyz': 'cfe1f278fa89835c',
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef':
        '1af3ac4760fe2f85',
  };

  test('matches the reference vectors', () {
    vectors.forEach((input, expected) {
      expect(_hex(_hash(Uint8List.fromList(input.codeUnits))), expected);
    });
  });

  test('seed is honoured', () {
    final data = Uint8List.fromList('abc'.codeUnits);
    expect(_hex(_hash(data, seed: 1)), 'bea9ca8199328908');
  });

  test('chunked updates agree with one-shot updates', () {
    final random = Random(7);
    for (var length = 0; length <= 200; length++) {
      final data = Uint8List.fromList(
        List<int>.generate(length, (_) => random.nextInt(256)),
      );
      final oneShot = _hex(_hash(data));
      for (final chunk in [1, 2, 3, 7, 31, 32, 33, 64]) {
        expect(
          _hex(_hash(data, chunk: chunk)),
          oneShot,
          reason: 'len=$length chunk=$chunk',
        );
      }
    }
  });
}
