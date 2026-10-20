/// Native (64-bit integer) hash helpers for the match finder.
///
/// The arithmetic is chosen so it produces exactly the same results as the
/// web implementation (`hash_web.dart`): 32-bit modular multiplication,
/// optionally folding the extra bytes of 5..8-byte matches into the hash.
///
/// Callers pass already-loaded 32-bit words so the hot loops perform one
/// unaligned load per word instead of shifting individual bytes.
library;

const int _prime = 0x9E3779B1;

/// 32-bit multiplicative hash of one word.
@pragma('vm:prefer-inline')
int mix4(int word, int shift) => ((word * _prime) & 0xFFFFFFFF) >>> shift;

/// 32-bit multiplicative hash of a word folded with up to three extra bytes.
@pragma('vm:prefer-inline')
int mixExtra(int word, int extra, int shift) =>
    (((((word * _prime) & 0xFFFFFFFF) ^ extra) * _prime) & 0xFFFFFFFF) >>>
    shift;

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
