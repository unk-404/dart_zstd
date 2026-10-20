/// XXH64 for dart2js / dart2wasm.
///
/// JavaScript has no 64-bit integers, so the JS build represents the state as
/// two unsigned 32-bit limbs and forms 64-bit products with 16-bit limb
/// multiplications. dart2wasm (and the VM, where tests import this file
/// directly) has genuine 64-bit integers, so it uses the much faster wide
/// implementation. The choice is a compile-time constant, letting dart2js
/// tree-shake the wide path entirely and vice versa.
library;

import 'dart:typed_data';

/// True on platforms whose `int` is a real 64-bit integer (VM, dart2wasm).
const bool _kInt64 = (1 << 40) == 1099511627776;

const int _mask32 = 0xFFFFFFFF;
const int _m16 = 0xFFFF;
const int _base32 = 0x100000000;

const int _p1b0 = 0xCA87;
const int _p1b1 = 0x85EB;
const int _p1b2 = 0x79B1;
const int _p1b3 = 0x9E37;
const int _p2b0 = 0xEB4F;
const int _p2b1 = 0x27D4;
const int _p2b2 = 0xAE3D;
const int _p2b3 = 0xC2B2;
const int _p3b0 = 0x79F9;
const int _p3b1 = 0x9E37;
const int _p3b2 = 0x67B1;
const int _p3b3 = 0x1656;

const int _p1Lo = 0x85EBCA87;
const int _p1Hi = 0x9E3779B1;
const int _p2Lo = 0x27D4EB4F;
const int _p2Hi = 0xC2B2AE3D;
const int _p3Lo = 0x9E3779F9;
const int _p3Hi = 0x165667B1;
const int _p4Lo = 0xC2B2AE63;
const int _p4Hi = 0x85EBCA77;
const int _p5Lo = 0x165667C5;
const int _p5Hi = 0x27D4EB2F;

final class _LimbsXxh64 implements Xxh64 {
  _LimbsXxh64([int seed = 0]) {
    final sHi = 0;
    final sLo = seed & _mask32;
    // v1 = seed + P1 + P2
    var lo = sLo + _p1Lo;
    var hi = (sHi + _p1Hi + (lo >= _base32 ? 1 : 0)) & _mask32;
    lo &= _mask32;
    lo += _p2Lo;
    hi = (hi + _p2Hi + (lo >= _base32 ? 1 : 0)) & _mask32;
    _v1h = hi;
    _v1l = lo & _mask32;
    // v2 = seed + P2
    lo = sLo + _p2Lo;
    _v2h = (sHi + _p2Hi + (lo >= _base32 ? 1 : 0)) & _mask32;
    _v2l = lo & _mask32;
    // v3 = seed
    _v3h = sHi;
    _v3l = sLo;
    // v4 = seed - P1
    final borrow = sLo < _p1Lo ? 1 : 0;
    _v4l = (sLo - _p1Lo) & _mask32;
    _v4h = (sHi - _p1Hi - borrow) & _mask32;
    _seedHi = sHi;
    _seedLo = sLo;
  }

  int _v1h = 0;
  int _v1l = 0;
  int _v2h = 0;
  int _v2l = 0;
  int _v3h = 0;
  int _v3l = 0;
  int _v4h = 0;
  int _v4l = 0;
  int _seedHi = 0;
  int _seedLo = 0;
  // Scratch product limbs.
  int _th = 0;
  int _tl = 0;
  final Uint8List _memory = Uint8List(32);
  int _total = 0;
  int _memorySize = 0;

  @override
  void update(Uint8List data, [int start = 0, int? end]) {
    final stop = end ?? data.length;
    RangeError.checkValidRange(start, stop, data.length);
    if (start == stop) return;
    _total += stop - start;
    var i = start;

    if (_memorySize + (stop - i) < 32) {
      _memory.setRange(_memorySize, _memorySize + (stop - i), data, i);
      _memorySize += stop - i;
      return;
    }

    if (_memorySize > 0) {
      final fill = 32 - _memorySize;
      _memory.setRange(_memorySize, 32, data, i);
      i += fill;
      _stripe(_memory, 0);
      _memorySize = 0;
    }

    final limit = stop - 32;
    while (i <= limit) {
      _stripe(data, i);
      i += 32;
    }

    if (i < stop) {
      _memorySize = stop - i;
      _memory.setRange(0, _memorySize, data, i);
    }
  }

  @override
  Xxh64Digest digest() {
    final memory = _memory;
    var hHi = 0;
    var hLo = 0;
    if (_total >= 32) {
      hHi = _rotlHi(_v1h, _v1l, 1);
      hLo = _rotlLo(_v1h, _v1l, 1);
      var addHi = _rotlHi(_v2h, _v2l, 7);
      var addLo = _rotlLo(_v2h, _v2l, 7);
      var lowSum = hLo + addLo;
      hHi = (hHi + addHi + (lowSum >= _base32 ? 1 : 0)) & _mask32;
      hLo = lowSum & _mask32;
      addHi = _rotlHi(_v3h, _v3l, 12);
      addLo = _rotlLo(_v3h, _v3l, 12);
      lowSum = hLo + addLo;
      hHi = (hHi + addHi + (lowSum >= _base32 ? 1 : 0)) & _mask32;
      hLo = lowSum & _mask32;
      addHi = _rotlHi(_v4h, _v4l, 18);
      addLo = _rotlLo(_v4h, _v4l, 18);
      lowSum = hLo + addLo;
      hHi = (hHi + addHi + (lowSum >= _base32 ? 1 : 0)) & _mask32;
      hLo = lowSum & _mask32;

      // merge rounds: h = (h ^ round(0, v)) * P1 + P4
      for (var m = 0; m < 4; m++) {
        final vh = m == 0
            ? _v1h
            : m == 1
            ? _v2h
            : m == 2
            ? _v3h
            : _v4h;
        final vl = m == 0
            ? _v1l
            : m == 1
            ? _v2l
            : m == 2
            ? _v3l
            : _v4l;
        _mulP2ToTmp(vh, vl);
        final aH = _th;
        final aL = _tl;
        _mulP1ToTmp(_rotlHi(aH, aL, 31), _rotlLo(aH, aL, 31));
        hHi = (hHi ^ _th) & _mask32;
        hLo = (hLo ^ _tl) & _mask32;
        _mulP1ToTmp(hHi, hLo);
        hLo = _tl + _p4Lo;
        hHi = (_th + _p4Hi + (hLo >= _base32 ? 1 : 0)) & _mask32;
        hLo &= _mask32;
      }
    } else {
      hHi = _seedHi;
      hLo = _seedLo;
      hLo += _p5Lo;
      hHi = (hHi + _p5Hi + (hLo >= _base32 ? 1 : 0)) & _mask32;
      hLo &= _mask32;
    }
    hLo += _total;
    hHi = (hHi + (hLo >= _base32 ? 1 : 0)) & _mask32;
    hLo &= _mask32;

    var i = 0;
    while (i + 8 <= _memorySize) {
      _mulP2ToTmp(_readHi(memory, i), _readLo(memory, i));
      // round(0, input) = rotl31(v * P2) * P1
      final aH = _th;
      final aL = _tl;
      _mulP1ToTmp(_rotlHi(aH, aL, 31), _rotlLo(aH, aL, 31));
      hHi ^= _th;
      hLo ^= _tl;
      // h = rotl(h, 27) * P1 + P4
      _mulP1ToTmp(_rotlHi(hHi, hLo, 27), _rotlLo(hHi, hLo, 27));
      hHi = _th;
      hLo = _tl + _p4Lo;
      hHi = (hHi + _p4Hi + (hLo >= _base32 ? 1 : 0)) & _mask32;
      hLo &= _mask32;
      i += 8;
    }
    if (i + 4 <= _memorySize) {
      _mulP1ToTmp(0, _readLo(memory, i));
      hHi ^= _th;
      hLo ^= _tl;
      _mulP2ToTmp(_rotlHi(hHi, hLo, 23), _rotlLo(hHi, hLo, 23));
      hHi = _th;
      hLo = _tl + _p3Lo;
      hHi = (hHi + _p3Hi + (hLo >= _base32 ? 1 : 0)) & _mask32;
      hLo &= _mask32;
      i += 4;
    }
    while (i < _memorySize) {
      _mulP5ToTmp(0, memory[i]);
      hHi ^= _th;
      hLo ^= _tl;
      _mulP1ToTmp(_rotlHi(hHi, hLo, 11), _rotlLo(hHi, hLo, 11));
      hHi = _th;
      hLo = _tl;
      i++;
    }

    // avalanche
    final s33 = _shr64(hHi, hLo, 33);
    hHi ^= s33.$1;
    hLo ^= s33.$2;
    _mulP2ToTmp(hHi, hLo);
    hHi = _th;
    hLo = _tl;
    final s29 = _shr64(hHi, hLo, 29);
    hHi ^= s29.$1;
    hLo ^= s29.$2;
    _mulP3ToTmp(hHi, hLo);
    hHi = _th;
    hLo = _tl;
    final s32 = _shr64(hHi, hLo, 32);
    hHi ^= s32.$1;
    hLo ^= s32.$2;

    return Xxh64Digest(hHi & _mask32, hLo & _mask32);
  }

  void _stripe(Uint8List data, int offset) {
    _mulP2ToTmp(_readHi(data, offset), _readLo(data, offset));
    _roundState(1);
    _mulP2ToTmp(_readHi(data, offset + 8), _readLo(data, offset + 8));
    _roundState(2);
    _mulP2ToTmp(_readHi(data, offset + 16), _readLo(data, offset + 16));
    _roundState(3);
    _mulP2ToTmp(_readHi(data, offset + 24), _readLo(data, offset + 24));
    _roundState(4);
  }

  void _roundState(int which) {
    var hi = 0;
    var lo = 0;
    switch (which) {
      case 1:
        hi = _v1h;
        lo = _v1l;
      case 2:
        hi = _v2h;
        lo = _v2l;
      case 3:
        hi = _v3h;
        lo = _v3l;
      default:
        hi = _v4h;
        lo = _v4l;
    }
    final lowSum = lo + _tl;
    hi = (hi + _th + (lowSum >= _base32 ? 1 : 0)) & _mask32;
    lo = lowSum & _mask32;
    _mulP1ToTmp(_rotlHi(hi, lo, 31), _rotlLo(hi, lo, 31));
    switch (which) {
      case 1:
        _v1h = _th;
        _v1l = _tl;
      case 2:
        _v2h = _th;
        _v2l = _tl;
      case 3:
        _v3h = _th;
        _v3l = _tl;
      default:
        _v4h = _th;
        _v4l = _tl;
    }
  }

  static int _rotlHi(int hi, int lo, int bits) =>
      ((hi << bits) | (lo >>> (32 - bits))) & _mask32;

  static int _rotlLo(int hi, int lo, int bits) =>
      ((lo << bits) | (hi >>> (32 - bits))) & _mask32;

  static (int, int) _shr64(int hi, int lo, int bits) {
    if (bits < 32) {
      return (
        hi >>> bits,
        ((lo >>> bits) | ((hi << (32 - bits)) & _mask32)) & _mask32,
      );
    }
    if (bits == 32) return (0, hi);
    return (0, hi >>> (bits - 32));
  }

  static int _readLo(Uint8List data, int offset) =>
      (data[offset] |
          (data[offset + 1] << 8) |
          (data[offset + 2] << 16) |
          (data[offset + 3] * 16777216)) &
      _mask32;

  static int _readHi(Uint8List data, int offset) =>
      (data[offset + 4] |
          (data[offset + 5] << 8) |
          (data[offset + 6] << 16) |
          (data[offset + 7] * 16777216)) &
      _mask32;

  // --- multiplication by constants, 16-bit limb schoolbook, no division ----

  void _mulP1ToTmp(int ah, int al) =>
      _mulConst(ah, al, _p1b0, _p1b1, _p1b2, _p1b3);

  void _mulP2ToTmp(int ah, int al) =>
      _mulConst(ah, al, _p2b0, _p2b1, _p2b2, _p2b3);

  void _mulP3ToTmp(int ah, int al) =>
      _mulConst(ah, al, _p3b0, _p3b1, _p3b2, _p3b3);

  void _mulP5ToTmp(int ah, int al) =>
      _mulConst(ah, al, 0x67C5, 0x1656, 0xEB2F, 0x27D4);

  void _mulConst(int ah, int al, int b0, int b1, int b2, int b3) {
    final a0 = al & _m16;
    final a1 = al >>> 16;
    final a2 = ah & _m16;
    final a3 = ah >>> 16;
    final p0 = a0 * b0;
    final p1a = a0 * b1;
    final p1b = a1 * b0;
    final p2a = a0 * b2;
    final p2b = a1 * b1;
    final p2c = a2 * b0;
    final p3a = a0 * b3;
    final p3b = a1 * b2;
    final p3c = a2 * b1;
    final p3d = a3 * b0;

    var t = p0;
    final r0 = t & _m16;
    var carry = t >>> 16;
    t = (p1a & _m16) + (p1b & _m16) + carry;
    final r1 = t & _m16;
    carry = t >>> 16;
    var hiDigit = (p1a >>> 16) + (p1b >>> 16) + carry;
    t = (p2a & _m16) + (p2b & _m16) + (p2c & _m16) + hiDigit;
    final r2 = t & _m16;
    carry = t >>> 16;
    hiDigit = (p2a >>> 16) + (p2b >>> 16) + (p2c >>> 16) + carry;
    t = (p3a & _m16) + (p3b & _m16) + (p3c & _m16) + (p3d & _m16) + hiDigit;
    final r3 = t & _m16;
    _tl = r0 | (r1 << 16);
    _th = r2 | (r3 << 16);
  }
}

final class Xxh64Digest {
  const Xxh64Digest(this.high32, this.low32);

  final int high32;
  final int low32;

  String toHexString() {
    final value = (BigInt.from(high32) << 32) | BigInt.from(low32 & _mask32);
    return value.toRadixString(16).padLeft(16, '0');
  }

  @override
  bool operator ==(Object other) =>
      other is Xxh64Digest && other.high32 == high32 && other.low32 == low32;

  @override
  int get hashCode => Object.hash(high32, low32);

  @override
  String toString() => 'Xxh64Digest(0x${toHexString()})';
}

const int _prime1 = 0x9E3779B1 * 4294967296 + 0x85EBCA87;
const int _prime2 = 0xC2B2AE3D * 4294967296 + 0x27D4EB4F;
const int _prime3 = 0x165667B1 * 4294967296 + 0x9E3779F9;
const int _prime4 = 0x85EBCA77 * 4294967296 + 0xC2B2AE63;
const int _prime5 = 0x27D4EB2F * 4294967296 + 0x165667C5;

/// The 64-bit XXH64 result, split into two 32-bit halves so that it is
/// representable on every Dart platform.
final class _WideXxh64 implements Xxh64 {
  _WideXxh64([int seed = 0])
    : _seed = seed,
      _v1 = seed + _prime1 + _prime2,
      _v2 = seed + _prime2,
      _v3 = seed,
      _v4 = seed - _prime1;

  final int _seed;
  int _v1;
  int _v2;
  int _v3;
  int _v4;
  int _total = 0;
  final Uint8List _memory = Uint8List(32);
  late final ByteData _memoryData = ByteData.sublistView(_memory);
  int _memorySize = 0;

  /// Feeds `data[start..end)`.
  @override
  void update(Uint8List data, [int start = 0, int? end]) {
    final stop = end ?? data.length;
    RangeError.checkValidRange(start, stop, data.length);
    if (start == stop) return;
    _total += stop - start;
    var i = start;

    if (_memorySize + (stop - i) < 32) {
      _memory.setRange(_memorySize, _memorySize + (stop - i), data, i);
      _memorySize += stop - i;
      return;
    }

    if (_memorySize > 0) {
      final fill = 32 - _memorySize;
      _memory.setRange(_memorySize, 32, data, i);
      i += fill;
      _stripe(_memoryData, 0);
      _memorySize = 0;
    }

    final words = ByteData.sublistView(data);
    final limit = stop - 32;
    while (i <= limit) {
      _stripe(words, i);
      i += 32;
    }

    if (i < stop) {
      _memorySize = stop - i;
      _memory.setRange(0, _memorySize, data, i);
    }
  }

  /// Finishes the hash. The state must not be updated afterwards.
  @override
  Xxh64Digest digest() {
    final memory = _memoryData;
    int h;
    if (_total >= 32) {
      h = _rotl(_v1, 1) + _rotl(_v2, 7) + _rotl(_v3, 12) + _rotl(_v4, 18);
      h = _mergeRound(h, _v1);
      h = _mergeRound(h, _v2);
      h = _mergeRound(h, _v3);
      h = _mergeRound(h, _v4);
    } else {
      h = _seed + _prime5;
    }
    h += _total;

    var i = 0;
    while (i + 8 <= _memorySize) {
      h ^= _round(0, memory.getUint64(i, Endian.little));
      h = _rotl(h, 27) * _prime1 + _prime4;
      i += 8;
    }
    if (i + 4 <= _memorySize) {
      h ^= memory.getUint32(i, Endian.little) * _prime1;
      h = _rotl(h, 23) * _prime2 + _prime3;
      i += 4;
    }
    while (i < _memorySize) {
      h ^= _memory[i] * _prime5;
      h = _rotl(h, 11) * _prime1;
      i++;
    }

    h ^= h >>> 33;
    h *= _prime2;
    h ^= h >>> 29;
    h *= _prime3;
    h ^= h >>> 32;

    return Xxh64Digest((h >>> 32) & 0xFFFFFFFF, h & 0xFFFFFFFF);
  }

  void _stripe(ByteData data, int offset) {
    _v1 = _round(_v1, data.getUint64(offset, Endian.little));
    _v2 = _round(_v2, data.getUint64(offset + 8, Endian.little));
    _v3 = _round(_v3, data.getUint64(offset + 16, Endian.little));
    _v4 = _round(_v4, data.getUint64(offset + 24, Endian.little));
  }

  static int _round(int acc, int input) {
    acc += input * _prime2;
    acc = _rotl(acc, 31);
    acc *= _prime1;
    return acc;
  }

  static int _mergeRound(int acc, int value) {
    value = _round(0, value);
    acc ^= value;
    acc = acc * _prime1 + _prime4;
    return acc;
  }

  static int _rotl(int value, int bits) =>
      (value << bits) | (value >>> (64 - bits));
}

/// Streaming XXH64 state.
///
/// [update] accepts `data[start..end)` and [digest] finishes the hash.
abstract interface class Xxh64 {
  factory Xxh64([int seed = 0]) =>
      _kInt64 ? _WideXxh64(seed) : _LimbsXxh64(seed);

  void update(Uint8List data, [int start = 0, int? end]);

  Xxh64Digest digest();
}
