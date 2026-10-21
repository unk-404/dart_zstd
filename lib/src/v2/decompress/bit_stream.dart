/// Bit-level readers and small integer helpers used by the decoder.
///
/// Zstandard has two kinds of bit streams:
///
/// * forward, byte-aligned streams (FSE distribution tables), read
///   little-endian from the first byte to the last;
/// * backward streams (FSE/Huffman coded payloads), where the last byte holds
///   a final `1` bit and 0-7 padding bits, and the payload is decoded from the
///   highest useful bit down to bit 0 of the first byte.
///
/// Everything here is written with 32-bit-safe operations so that the same
/// source runs on the VM, dart2js and dart2wasm.
library;

import 'dart:typed_data';

import '../../common/errors.dart';

/// Exact powers of two, used instead of `1 << n` because JavaScript's shift
/// operators are 32-bit and would wrap for `n >= 31`.
const List<int> kPow2 = <int>[
  1,
  2,
  4,
  8,
  16,
  32,
  64,
  128,
  256,
  512,
  1024,
  2048,
  4096,
  8192,
  16384,
  32768,
  65536,
  131072,
  262144,
  524288,
  1048576,
  2097152,
  4194304,
  8388608,
  16777216,
  33554432,
  67108864,
  134217728,
  268435456,
  536870912,
  1073741824,
  2147483648,
  4294967296,
  8589934592,
  17179869184,
  34359738368,
  68719476736,
  137438953472,
  274877906944,
  549755813888,
  1099511627776,
  2199023255552,
];

/// Bit masks for widths `0..32`.
const List<int> kBitMasks = <int>[
  0,
  1,
  3,
  7,
  15,
  31,
  63,
  127,
  255,
  511,
  1023,
  2047,
  4095,
  8191,
  16383,
  32767,
  65535,
  131071,
  262143,
  524287,
  1048575,
  2097151,
  4194303,
  8388607,
  16777215,
  33554431,
  67108863,
  134217727,
  268435455,
  536870911,
  1073741823,
  2147483647,
  4294967295,
];

/// Index of the highest set bit of [value] (`value > 0`).
int highestSetBit(int value) {
  var v = value;
  var n = 0;
  while (v > 1) {
    v >>= 1;
    n++;
  }
  return n;
}

/// Reads `n` (0..32) bits at [bitOffset] from [data] starting at [start].
///
/// The bits are interpreted little-endian: the lowest bit of the byte at
/// [bitOffset] is the least significant bit of the result. The caller must
/// guarantee that `bitOffset + n` lies inside `[0, (data.length - start) * 8)`.
int readBitsLe(Uint8List data, int start, int bitOffset, int n) {
  if (n == 0) return 0;
  var bytePos = start + (bitOffset >> 3);
  var bitInByte = bitOffset & 7;
  var result = 0;
  var shift = 0;
  var left = n;
  while (left > 0) {
    var take = 8 - bitInByte;
    if (take > left) take = left;
    final bits = (data[bytePos] >> bitInByte) & ((1 << take) - 1);
    if (shift == 0) {
      result += bits;
    } else {
      result += bits * kPow2[shift];
    }
    shift += take;
    left -= take;
    bitInByte = 0;
    bytePos++;
  }
  return result;
}

/// Little-endian 24-bit read. 32-bit-safe on the web.
int readLe24(Uint8List data, int pos) =>
    data[pos] | (data[pos + 1] << 8) | (data[pos + 2] * 65536);

/// Little-endian 32-bit read. 32-bit-safe on the web.
int readLe32(Uint8List data, int pos) =>
    data[pos] |
    (data[pos + 1] << 8) |
    (data[pos + 2] * 65536) |
    (data[pos + 3] * 16777216);

/// Forward (byte-aligned, little-endian) bit reader over `data[start..end)`.
final class ForwardBitReader {
  ForwardBitReader(this.data, this.start, this.end) : _bit = 0;

  final Uint8List data;
  final int start;
  final int end;

  /// Bit position relative to [start].
  int _bit;

  /// Current byte position relative to [start].
  int get byteOffset => _bit >> 3;

  /// Absolute position of the first byte that has not been consumed, assuming
  /// the reader is byte aligned. Only meaningful after [alignToByte].
  int get position {
    if ((_bit & 7) != 0) {
      throw const ZstdException(
        ZstdErrorCode.invalidFseTable,
        'unaligned bit reader position',
      );
    }
    return start + (_bit >> 3);
  }

  int get remainingBytes => end - start - (_bit >> 3);

  int readBits(int n) {
    if (n < 0 || n > 32) {
      throw const ZstdException(
        ZstdErrorCode.invalidFseTable,
        'invalid bit count',
      );
    }
    final needed = _bit + n;
    if (((needed + 7) >> 3) > end - start) {
      throw const ZstdException(
        ZstdErrorCode.truncatedInput,
        'bit stream ended inside a field',
      );
    }
    final value = readBitsLe(data, start, _bit, n);
    _bit = needed;
    return value;
  }

  /// Steps back [n] bits (used by the FSE distribution parser).
  void rewindBits(int n) {
    if (n < 0 || n > _bit) {
      throw const ZstdException(
        ZstdErrorCode.invalidFseTable,
        'invalid bit rewind',
      );
    }
    _bit -= n;
  }

  /// Skips [n] whole bytes; the reader must be byte aligned.
  void skipBytes(int n) {
    if (n < 0 || (_bit & 7) != 0 || ((_bit >> 3) + n) > end - start) {
      throw const ZstdException(
        ZstdErrorCode.truncatedInput,
        'cannot skip past the end of the input',
      );
    }
    _bit += n * 8;
  }

  /// Skips the unused high bits of the current byte.
  void alignToByte() {
    _bit = (_bit + 7) & ~7;
    if ((_bit >> 3) > end - start) {
      throw const ZstdException(
        ZstdErrorCode.truncatedInput,
        'bit stream ended inside a field',
      );
    }
  }
}

/// True where `int` is a genuine 64-bit integer (VM, dart2wasm).
const bool kHasInt64 = (1 << 40) == 1099511627776;

/// Width of the backward-reader window.
const int kWindowBits = kHasInt64 ? 64 : 32;

/// Backward bit reader for FSE and Huffman payloads.
///
/// The v2 engine passes a scratch buffer with eight zero bytes before the frame
/// and sixteen after it, so window loads never need end-of-buffer checks.
/// On 64-bit platforms the window is eight bytes wide (four on dart2js).
final class BackwardBitReader {
  BackwardBitReader(this.data, this.start, this.end) {
    if (end <= start) {
      throw const ZstdException(
        ZstdErrorCode.truncatedInput,
        'empty backward bit stream',
      );
    }
    final lastByte = data[end - 1];
    if (lastByte == 0) {
      throw const ZstdException(
        ZstdErrorCode.truncatedInput,
        'last back-reference bit stream byte is zero',
      );
    }
    var windowStart = end - (kHasInt64 ? 8 : 4);
    if (windowStart < start) windowStart = start;
    ptr = windowStart;
    container = load(windowStart);
    final inWindow = (end - windowStart - 1) * 8 + highestSetBit(lastByte);
    bitsConsumed = kWindowBits - inWindow;
  }

  final Uint8List data;
  final int start;
  final int end;

  ByteData? _words;

  int ptr = 0;
  int container = 0;
  int bitsConsumed = 0;

  /// Number of unread bits (may be negative for truncated streams).
  int get bitPosition => (ptr - start) * 8 + kWindowBits - bitsConsumed;

  /// Bits currently available in the window without a refill.
  int get windowBits => kWindowBits - bitsConsumed;

  @pragma('vm:prefer-inline')
  int load(int at) {
    if (kHasInt64) {
      final words = _words ??= ByteData.sublistView(data);
      return words.getUint64(at, Endian.little);
    }
    final b0 = data[at];
    final b1 = data[at + 1];
    final b2 = data[at + 2];
    final b3 = data[at + 3];
    return b0 + (b1 << 8) + (b2 << 16) + b3 * 16777216;
  }

  @pragma('vm:prefer-inline')
  void refill() {
    if (ptr <= start) return;
    var nbBytes = bitsConsumed >> 3;
    if (nbBytes <= 0) return;
    final available = ptr - start;
    if (nbBytes > available) nbBytes = available;
    ptr -= nbBytes;
    bitsConsumed -= nbBytes * 8;
    container = load(ptr);
  }

  int readBits(int n) {
    if (n == 0) return 0;
    if (n < 0 || n > 32) {
      throw const ZstdException(
        ZstdErrorCode.invalidSequence,
        'invalid back-reference bit count',
      );
    }
    if (!kHasInt64 && n > 24) {
      final high = readBits(n - 8);
      final low = readBits(8);
      return high * 256 + low;
    }
    var available = kWindowBits - bitsConsumed;
    if (available < n) {
      refill();
      available = kWindowBits - bitsConsumed;
    }
    if (available < n) {
      final have = available < 0 ? 0 : available;
      final value = have == 0 ? 0 : (container & kBitMasks[have]);
      bitsConsumed += n;
      return value * kPow2[n - have];
    }
    final value =
        (container >>> (kWindowBits - bitsConsumed - n)) & kBitMasks[n];
    bitsConsumed += n;
    return value;
  }
}

/// Hot-loop view over a [BackwardBitReader].
final class BitWindow {
  BitWindow(this.reader)
    : container = reader.container,
      ptr = reader.ptr,
      bitsConsumed = reader.bitsConsumed;

  final BackwardBitReader reader;
  int container;
  int ptr;
  int bitsConsumed;

  int get bitPosition => (ptr - reader.start) * 8 + kWindowBits - bitsConsumed;

  int get windowBits => kWindowBits - bitsConsumed;

  @pragma('vm:prefer-inline')
  void refill() {
    final start = reader.start;
    if (ptr <= start) return;
    var nbBytes = bitsConsumed >> 3;
    if (nbBytes <= 0) return;
    final available = ptr - start;
    if (nbBytes > available) nbBytes = available;
    ptr -= nbBytes;
    bitsConsumed -= nbBytes * 8;
    container = reader.load(ptr);
  }

  void flush() {
    reader
      ..container = container
      ..ptr = ptr
      ..bitsConsumed = bitsConsumed;
  }

  @pragma('vm:prefer-inline')
  int readBits(int n) {
    if (n == 0) return 0;
    if (!kHasInt64 && n > 24) return _slowReadBits(n);
    if (kWindowBits - bitsConsumed < n) return _slowReadBits(n);
    final value =
        (container >>> (kWindowBits - bitsConsumed - n)) &
        (n <= 32 ? kBitMasks[n] : (1 << n) - 1);
    bitsConsumed += n;
    return value;
  }

  int _slowReadBits(int n) {
    if (!kHasInt64 && n > 24) {
      final high = readBits(n - 8);
      final low = readBits(8);
      return high * 256 + low;
    }
    refill();
    final available = kWindowBits - bitsConsumed;
    if (available < n) {
      final have = available < 0 ? 0 : available;
      final value = have == 0
          ? 0
          : (container & (have <= 32 ? kBitMasks[have] : (1 << have) - 1));
      bitsConsumed += n;
      return value * (kHasInt64 ? (1 << (n - have)) : kPow2[n - have]);
    }
    final value =
        (container >>> (kWindowBits - bitsConsumed - n)) &
        (n <= 32 ? kBitMasks[n] : (1 << n) - 1);
    bitsConsumed += n;
    return value;
  }
}
