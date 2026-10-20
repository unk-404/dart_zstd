/// Web-safe hash helpers for the match finder.
///
/// JavaScript only has exact integers up to 2^53, so the 32-bit multiply is
/// emulated with 16-bit limbs. The results are identical to
/// `hash_native.dart`.
library;

const int _prime = 0x9E3779B1;

/// 32-bit modular multiplication, safe on 32-bit integer semantics.
@pragma('vm:prefer-inline')
int mul32(int a, int b) {
  final low = (a & 0xFFFF) * b;
  final high = ((a >>> 16) & 0xFFFF) * b;
  return (low + ((high & 0xFFFF) << 16)) & 0xFFFFFFFF;
}

/// 32-bit multiplicative hash of one word.
@pragma('vm:prefer-inline')
int mix4(int word, int shift) => mul32(word, _prime) >>> shift;

/// 32-bit multiplicative hash of a word folded with up to three extra bytes.
@pragma('vm:prefer-inline')
int mixExtra(int word, int extra, int shift) =>
    mul32(mul32(word, _prime) ^ extra, _prime) >>> shift;

/// Multiplicative hash of two words (an 8-byte match).
@pragma('vm:prefer-inline')
int mix8(int word, int word2, int shift) {
  final extra =
      ((word2 & 0xFF) << 24) |
      ((word2 & 0xFF00) << 8) |
      ((word2 >>> 8) & 0xFF00) |
      (word2 >>> 24);
  return mixExtra(word, extra, shift);
}
