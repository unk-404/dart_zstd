/// One-shot XXH64 for the v2 decoder.
///
/// The v0.1.2 streaming hasher is general-purpose. The v2 decoder hashes one
/// contiguous output range, so this version avoids the chunked-state object and
/// reads 32-byte stripes through a [Uint64List] view when the range is aligned.
library;

import 'dart:typed_data';

const int _p1 = 0x9E3779B1 * 4294967296 + 0x85EBCA87;
const int _p2 = 0xC2B2AE3D * 4294967296 + 0x27D4EB4F;
const int _p3 = 0x165667B1 * 4294967296 + 0x9E3779F9;
const int _p4 = 0x85EBCA77 * 4294967296 + 0xC2B2AE63;
const int _p5 = 0x27D4EB2F * 4294967296 + 0x165667C5;

int _rotl(int value, int bits) => (value << bits) | (value >>> (64 - bits));

int _round(int acc, int input) {
  acc += input * _p2;
  acc = _rotl(acc, 31);
  return acc * _p1;
}

int _mergeRound(int acc, int value) {
  value = _round(0, value);
  acc ^= value;
  return acc * _p1 + _p4;
}

/// Lower 32 bits of XXH64 over `data[start..end)` with seed 0.
@pragma('vm:unsafe:no-bounds-checks')
int xxh64Low32(Uint8List data, int start, int end) {
  if (end <= start) return xxh64Low32Empty;
  final length = end - start;
  int h;
  var i = start;
  if (length >= 32) {
    var v1 = _p1 + _p2;
    var v2 = _p2;
    var v3 = 0;
    var v4 = -_p1;
    final words = (data.offsetInBytes + start) & 7;
    if (words == 0) {
      final view = Uint64List.view(
        data.buffer,
        data.offsetInBytes + start,
        (end - start) >> 3,
      );
      final stripeWords = ((end - start) >> 5) << 2;
      var wi = 0;
      while (wi < stripeWords) {
        v1 = _round(v1, view[wi]);
        v2 = _round(v2, view[wi + 1]);
        v3 = _round(v3, view[wi + 2]);
        v4 = _round(v4, view[wi + 3]);
        wi += 4;
      }
      i = start + (stripeWords << 3);
    } else {
      final bytes = ByteData.sublistView(data);
      final limit = end - 32;
      while (i <= limit) {
        v1 = _round(v1, bytes.getUint64(i, Endian.little));
        v2 = _round(v2, bytes.getUint64(i + 8, Endian.little));
        v3 = _round(v3, bytes.getUint64(i + 16, Endian.little));
        v4 = _round(v4, bytes.getUint64(i + 24, Endian.little));
        i += 32;
      }
    }
    h = _rotl(v1, 1) + _rotl(v2, 7) + _rotl(v3, 12) + _rotl(v4, 18);
    h = _mergeRound(h, v1);
    h = _mergeRound(h, v2);
    h = _mergeRound(h, v3);
    h = _mergeRound(h, v4);
  } else {
    h = _p5;
  }
  h += length;

  final bytes = ByteData.sublistView(data);
  while (i + 8 <= end) {
    h ^= _round(0, bytes.getUint64(i, Endian.little));
    h = _rotl(h, 27) * _p1 + _p4;
    i += 8;
  }
  if (i + 4 <= end) {
    h ^= bytes.getUint32(i, Endian.little) * _p1;
    h = _rotl(h, 23) * _p2 + _p3;
    i += 4;
  }
  while (i < end) {
    h ^= data[i] * _p5;
    h = _rotl(h, 11) * _p1;
    i++;
  }

  h ^= h >>> 33;
  h *= _p2;
  h ^= h >>> 29;
  h *= _p3;
  h ^= h >>> 32;
  return h & 0xFFFFFFFF;
}

/// XXH64 of an empty input (seed 0), lower 32 bits.
const int xxh64Low32Empty = 0x51D8E999;
