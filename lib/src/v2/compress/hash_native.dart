/// Exact zstd multiplicative hashes for the v2 match finder (native path).
///
/// Native Dart integers are 64-bit two's complement, so the reference
/// implementation's unsigned 64-bit products are the same bit patterns and
/// `>>>` extracts the top bits directly. The web implementation in
/// `hash_web.dart` uses 32-bit limb arithmetic instead; both are correct
/// hashes, but only the native path reproduces libzstd's hash values.
library;

const int _prime4 = 0x9E3779B1;
const int _prime5 = 889523592379;
const int _prime6 = 227718039650203;
const int _prime7 = 58295818150454627;
const int _prime8 = 0xCF1BBCDCB7A56463;

/// zstd's `ZSTD_hash4`: 32-bit product, top `32 - shift` bits.
@pragma('vm:prefer-inline')
int hash4(int word, int shift) => ((word * _prime4) & 0xFFFFFFFF) >>> shift;

@pragma('vm:prefer-inline')
int hash5(int word, int word2, int shift) =>
    ((((word | (word2 << 32)) << 24) * _prime5) >>> (32 + shift));

@pragma('vm:prefer-inline')
int hash6(int word, int word2, int shift) =>
    ((((word | (word2 << 32)) << 16) * _prime6) >>> (32 + shift));

@pragma('vm:prefer-inline')
int hash7(int word, int word2, int shift) =>
    ((((word | (word2 << 32)) << 8) * _prime7) >>> (32 + shift));

@pragma('vm:prefer-inline')
int hash8(int word, int word2, int shift) =>
    (((word | (word2 << 32)) * _prime8) >>> (32 + shift));
