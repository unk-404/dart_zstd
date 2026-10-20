/// XXH64 for the Dart VM (64-bit two's-complement integers).
library;

import 'dart:typed_data';

const int _prime1 = 0x9E3779B185EBCA87;
const int _prime2 = 0xC2B2AE3D27D4EB4F;
const int _prime3 = 0x165667B19E3779F9;
const int _prime4 = 0x85EBCA77C2B2AE63;
const int _prime5 = 0x27D4EB2F165667C5;

/// The 64-bit XXH64 result, split into two 32-bit halves so that it is
/// representable on every Dart platform.
final class Xxh64Digest {
  const Xxh64Digest(this.high32, this.low32);

  final int high32;
  final int low32;

  /// Lowercase, zero-padded, 16 hex digits.
  String toHexString() {
    final value = (BigInt.from(high32) << 32) | BigInt.from(low32 & 0xFFFFFFFF);
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

/// Streaming XXH64 state.
///
/// The VM implementation reads 32-bit and 64-bit words through [ByteData],
/// which compiles to single unaligned loads instead of four byte loads plus
/// shifts per word.
final class Xxh64 {
  Xxh64([int seed = 0])
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
