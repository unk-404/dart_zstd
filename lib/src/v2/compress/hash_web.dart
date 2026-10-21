/// Web-safe hashes for the v2 match finder.
///
/// JavaScript only has exact integers up to 2^53, so a 64-bit multiply cannot
/// be emulated cheaply. This implementation keeps the 32-bit multiplicative
/// hash used by the v0.1 encoder: a correct hash for every length, but not
/// bit-identical to `hash_native.dart` (frame contents may differ between the
/// VM and the web; both streams are valid zstd).
library;

const int _prime = 0x9E3779B1;

@pragma('vm:prefer-inline')
int _mul32(int a, int b) {
  final low = (a & 0xFFFF) * b;
  final high = ((a >>> 16) & 0xFFFF) * b;
  return (low + ((high & 0xFFFF) << 16)) & 0xFFFFFFFF;
}

@pragma('vm:prefer-inline')
int hash4(int word, int shift) => _mul32(word, _prime) >>> shift;

@pragma('vm:prefer-inline')
int _hashExtra(int word, int extra, int shift) =>
    _mul32(_mul32(word, _prime) ^ extra, _prime) >>> shift;

@pragma('vm:prefer-inline')
int hash5(int word, int word2, int shift) =>
    _hashExtra(word, word2 & 0xFF, shift);

@pragma('vm:prefer-inline')
int hash6(int word, int word2, int shift) =>
    _hashExtra(word, ((word2 & 0xFF) << 8) | ((word2 >>> 8) & 0xFF), shift);

@pragma('vm:prefer-inline')
int hash7(int word, int word2, int shift) => _hashExtra(
  word,
  ((word2 & 0xFF) << 16) | (word2 & 0xFF00) | ((word2 >>> 16) & 0xFF),
  shift,
);

@pragma('vm:prefer-inline')
int hash8(int word, int word2, int shift) => _hashExtra(
  word,
  ((word2 & 0xFF) << 24) |
      ((word2 & 0xFF00) << 8) |
      ((word2 >>> 8) & 0xFF00) |
      (word2 >>> 24),
  shift,
);
