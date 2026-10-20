/// XXH64 for dart2js / dart2wasm.
///
/// JavaScript has no 64-bit integers, so the state is represented as two
/// unsigned 32-bit limbs. Every operation is exact: products of two 16-bit
/// limbs stay far below `2^53`, and carries are propagated explicitly.
library;

import 'dart:typed_data';

const int _mask32 = 0xFFFFFFFF;
const int _base32 = 0x100000000;

/// The 64-bit XXH64 result, split into two 32-bit halves.
final class Xxh64Digest {
  const Xxh64Digest(this.high32, this.low32);

  final int high32;
  final int low32;

  /// Lowercase, zero-padded, 16 hex digits.
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

/// Mutable unsigned 64-bit value, two 32-bit limbs.
final class _U64 {
  _U64([this.hi = 0, this.lo = 0]);

  int hi;
  int lo;

  void set(int high, int low) {
    hi = high & _mask32;
    lo = low & _mask32;
  }

  void copy(_U64 other) {
    hi = other.hi;
    lo = other.lo;
  }

  void add(_U64 other) {
    final lowSum = lo + other.lo;
    hi = (hi + other.hi + (lowSum >= _base32 ? 1 : 0)) & _mask32;
    lo = lowSum & _mask32;
  }

  void sub(_U64 other) {
    final borrow = lo < other.lo ? 1 : 0;
    lo = (lo - other.lo) & _mask32;
    hi = (hi - other.hi - borrow) & _mask32;
  }

  void addInt(int value) {
    final valueHi = value ~/ _base32;
    final valueLo = value & _mask32;
    final lowSum = lo + valueLo;
    hi = (hi + valueHi + (lowSum >= _base32 ? 1 : 0)) & _mask32;
    lo = lowSum & _mask32;
  }

  void xor(_U64 other) {
    hi = (hi ^ other.hi) & _mask32;
    lo = (lo ^ other.lo) & _mask32;
  }

  /// `this = this * other`, low 64 bits.
  void mul(_U64 other) {
    final a0 = lo & 0xFFFF;
    final a1 = lo >>> 16;
    final a2 = hi & 0xFFFF;
    final a3 = hi >>> 16;
    final b0 = other.lo & 0xFFFF;
    final b1 = other.lo >>> 16;
    final b2 = other.hi & 0xFFFF;
    final b3 = other.hi >>> 16;

    final p0 = a0 * b0;
    final p1 = a0 * b1 + a1 * b0;
    final p2 = a0 * b2 + a1 * b1 + a2 * b0;
    final p3 = a0 * b3 + a1 * b2 + a2 * b1 + a3 * b0;

    var carry = p0 >>> 16;
    final r0 = p0 & 0xFFFF;
    var t = p1 + carry;
    final r1 = t & 0xFFFF;
    carry = (t - r1) ~/ 0x10000;
    t = p2 + carry;
    final r2 = t & 0xFFFF;
    carry = (t - r2) ~/ 0x10000;
    t = p3 + carry;
    final r3 = t & 0xFFFF;

    lo = ((r1 << 16) | r0) & _mask32;
    hi = ((r3 << 16) | r2) & _mask32;
  }

  /// Rotate left by `bits` (1..31).
  void rotl(int bits) {
    final newHi = ((hi << bits) | (lo >>> (32 - bits))) & _mask32;
    final newLo = ((lo << bits) | (hi >>> (32 - bits))) & _mask32;
    hi = newHi;
    lo = newLo;
  }

  /// Logical shift right by `bits` (1..63).
  void shr(int bits) {
    if (bits < 32) {
      lo = ((lo >>> bits) | ((hi << (32 - bits)) & _mask32)) & _mask32;
      hi = hi >>> bits;
    } else if (bits == 32) {
      lo = hi;
      hi = 0;
    } else {
      lo = hi >>> (bits - 32);
      hi = 0;
    }
  }

  void readLE32(Uint8List data, int offset) {
    lo =
        (data[offset] |
            (data[offset + 1] << 8) |
            (data[offset + 2] << 16) |
            (data[offset + 3] << 24)) &
        _mask32;
    hi = 0;
  }

  void readLE64(Uint8List data, int offset) {
    readLE32(data, offset);
    final low = lo;
    readLE32(data, offset + 4);
    hi = lo;
    lo = low;
  }
}

final class Xxh64 {
  Xxh64([int seed = 0]) {
    _seed.set(0, seed & _mask32);
    _v1
      ..copy(_seed)
      ..add(_p1)
      ..add(_p2);
    _v2
      ..copy(_seed)
      ..add(_p2);
    _v3.copy(_seed);
    _v4
      ..copy(_seed)
      ..sub(_p1);
  }

  static final _U64 _p1 = _U64(0x9E3779B1, 0x85EBCA87);
  static final _U64 _p2 = _U64(0xC2B2AE3D, 0x27D4EB4F);
  static final _U64 _p3 = _U64(0x165667B1, 0x9E3779F9);
  static final _U64 _p4 = _U64(0x85EBCA77, 0xC2B2AE63);
  static final _U64 _p5 = _U64(0x27D4EB2F, 0x165667C5);

  final _U64 _seed = _U64();
  final _U64 _v1 = _U64();
  final _U64 _v2 = _U64();
  final _U64 _v3 = _U64();
  final _U64 _v4 = _U64();
  final _U64 _h = _U64();
  final _U64 _t = _U64();
  final Uint8List _memory = Uint8List(32);
  int _total = 0;
  int _memorySize = 0;

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

  Xxh64Digest digest() {
    _h.set(0, 0);
    if (_total >= 32) {
      _t
        ..copy(_v1)
        ..rotl(1);
      _h.add(_t);
      _t
        ..copy(_v2)
        ..rotl(7);
      _h.add(_t);
      _t
        ..copy(_v3)
        ..rotl(12);
      _h.add(_t);
      _t
        ..copy(_v4)
        ..rotl(18);
      _h.add(_t);

      _merge(_v1);
      _merge(_v2);
      _merge(_v3);
      _merge(_v4);
    } else {
      _h.copy(_seed);
      _h.add(_p5);
    }
    _h.addInt(_total);

    var i = 0;
    while (i + 8 <= _memorySize) {
      _t.readLE64(_memory, i);
      _t
        ..mul(_p2)
        ..rotl(31)
        ..mul(_p1);
      _h
        ..xor(_t)
        ..rotl(27)
        ..mul(_p1)
        ..add(_p4);
      i += 8;
    }
    if (i + 4 <= _memorySize) {
      _t.readLE32(_memory, i);
      _t.mul(_p1);
      _h
        ..xor(_t)
        ..rotl(23)
        ..mul(_p2)
        ..add(_p3);
      i += 4;
    }
    while (i < _memorySize) {
      _t.set(0, _memory[i]);
      _t.mul(_p5);
      _h
        ..xor(_t)
        ..rotl(11)
        ..mul(_p1);
      i++;
    }

    _t
      ..copy(_h)
      ..shr(33);
    _h
      ..xor(_t)
      ..mul(_p2);
    _t
      ..copy(_h)
      ..shr(29);
    _h
      ..xor(_t)
      ..mul(_p3);
    _t
      ..copy(_h)
      ..shr(32);
    _h.xor(_t);

    return Xxh64Digest(_h.hi, _h.lo);
  }

  void _stripe(Uint8List data, int offset) {
    _t.readLE64(data, offset);
    _t.mul(_p2);
    _v1
      ..add(_t)
      ..rotl(31)
      ..mul(_p1);

    _t.readLE64(data, offset + 8);
    _t.mul(_p2);
    _v2
      ..add(_t)
      ..rotl(31)
      ..mul(_p1);

    _t.readLE64(data, offset + 16);
    _t.mul(_p2);
    _v3
      ..add(_t)
      ..rotl(31)
      ..mul(_p1);

    _t.readLE64(data, offset + 24);
    _t.mul(_p2);
    _v4
      ..add(_t)
      ..rotl(31)
      ..mul(_p1);
  }

  void _merge(_U64 value) {
    _t
      ..copy(value)
      ..mul(_p2)
      ..rotl(31)
      ..mul(_p1);
    _h
      ..xor(_t)
      ..mul(_p1)
      ..add(_p4);
  }
}
