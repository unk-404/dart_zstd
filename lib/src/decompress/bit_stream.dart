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

import '../common/errors.dart';

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

/// Backward bit reader for FSE and Huffman payloads.
///
/// The reader keeps a 32-bit little-endian window ("container") covering four
/// input bytes and refills it backwards a whole number of bytes at a time,
/// exactly like libzstd's 32-bit `BIT_DStream_t`. This turns the hot
/// `readBits` path into a shift, a mask and two field updates.
///
/// [end] is exclusive. The last byte must contain the final `1` flag, so it
/// cannot be zero. `bitPosition` counts the remaining useful bits; it may go
/// negative when a truncated stream is read, and the zero-bit padding then
/// models the end of stream exactly like libzstd.
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
    // The window covers the last (up to) four bytes of the stream; bytes past
    // `end` read as zero, which gives the same padding as libzstd.
    var windowStart = end - 4;
    if (windowStart < start) windowStart = start;
    _ptr = windowStart;
    _container = _loadContainer(windowStart);
    final inWindow = (end - windowStart - 1) * 8 + highestSetBit(lastByte);
    _bitsConsumed = 32 - inWindow;
  }

  final Uint8List data;
  final int start;
  final int end;

  int _ptr = 0;
  int _container = 0;
  int _bitsConsumed = 0;

  /// Number of unread bits (may be negative for truncated streams).
  int get bitPosition => (_ptr - start) * 8 + 32 - _bitsConsumed;

  /// Bits currently available in the window without a refill.
  int get windowBits => 32 - _bitsConsumed;

  /// Window state accessors used by [BitWindow] (which copies the fields into
  /// locals for the hot loops).
  int get windowContainer => _container;
  int get windowPtr => _ptr;
  int get windowConsumed => _bitsConsumed;

  void restoreWindow(int container, int ptr, int bitsConsumed) {
    _container = container;
    _ptr = ptr;
    _bitsConsumed = bitsConsumed;
  }

  int _loadContainer(int windowStart) {
    final b0 = windowStart < end ? data[windowStart] : 0;
    final b1 = windowStart + 1 < end ? data[windowStart + 1] : 0;
    final b2 = windowStart + 2 < end ? data[windowStart + 2] : 0;
    final b3 = windowStart + 3 < end ? data[windowStart + 3] : 0;
    return b0 + (b1 << 8) + (b2 << 16) + b3 * 16777216;
  }

  /// Slides the window towards [start] by whole consumed bytes.
  void _refill() {
    if (_ptr <= start) return;
    var nbBytes = _bitsConsumed >> 3;
    if (nbBytes <= 0) return;
    final available = _ptr - start;
    if (nbBytes > available) nbBytes = available;
    _ptr -= nbBytes;
    _bitsConsumed -= nbBytes * 8;
    _container = _loadContainer(_ptr);
  }

  int readBits(int n) {
    if (n == 0) return 0;
    if (n < 0 || n > 32) {
      throw const ZstdException(
        ZstdErrorCode.invalidSequence,
        'invalid back-reference bit count',
      );
    }
    if (n > 24) {
      // A 32-bit window guarantees 25 bits after a refill; longer fields are
      // read as a high part plus an 8-bit low part (same bit order).
      final high = readBits(n - 8);
      final low = readBits(8);
      return high * 256 + low;
    }
    var available = 32 - _bitsConsumed;
    if (available < n) {
      _refill();
      available = 32 - _bitsConsumed;
    }
    if (available < n) {
      // Reading past the start: the low-order bits are zero-extended, the
      // remaining stream bits are shifted up (identical to libzstd).
      final have = available < 0 ? 0 : available;
      final value = have == 0 ? 0 : (_container & kBitMasks[have]);
      _bitsConsumed += n;
      return value * kPow2[n - have];
    }
    final value = (_container >>> (32 - _bitsConsumed - n)) & kBitMasks[n];
    _bitsConsumed += n;
    return value;
  }
}

/// Hot-loop view over a [BackwardBitReader].
///
/// The FSE and Huffman decoders read several small fields per step. Copying the
/// three window fields into locals and reading through the small
/// [readBits] method lets the optimizer inline the common path; the rare
/// refill/end-of-stream path lives in a separate method so it does not bloat
/// the hot code.
final class BitWindow {
  BitWindow(this.reader)
    : container = reader.windowContainer,
      ptr = reader.windowPtr,
      bitsConsumed = reader.windowConsumed;

  final BackwardBitReader reader;
  int container;
  int ptr;
  int bitsConsumed;

  /// Number of unread bits; may be negative for truncated streams.
  int get bitPosition => (ptr - reader.start) * 8 + 32 - bitsConsumed;

  int get windowBits => 32 - bitsConsumed;

  /// Writes the window state back to the owning reader.
  void flush() {
    reader.restoreWindow(container, ptr, bitsConsumed);
  }

  @pragma('vm:prefer-inline')
  int readBits(int n) {
    if (n == 0) return 0;
    if (32 - bitsConsumed < n) return _slowReadBits(n);
    final value = (container >>> (32 - bitsConsumed - n)) & kBitMasks[n];
    bitsConsumed += n;
    return value;
  }

  int _slowReadBits(int n) {
    if (n > 24) {
      final high = readBits(n - 8);
      final low = readBits(8);
      return high * 256 + low;
    }
    final start = reader.start;
    if (ptr > start) {
      var nbBytes = bitsConsumed >> 3;
      if (nbBytes <= 0) nbBytes = 0;
      final available = ptr - start;
      if (nbBytes > available) nbBytes = available;
      if (nbBytes > 0) {
        ptr -= nbBytes;
        bitsConsumed -= nbBytes * 8;
        container = reader._loadContainer(ptr);
      }
    }
    if (32 - bitsConsumed < n) {
      // End of stream: low-order bits are zero-extended.
      final have = 32 - bitsConsumed;
      final present = have < 0 ? 0 : have;
      final value = present == 0 ? 0 : (container & kBitMasks[present]);
      bitsConsumed += n;
      return value * kPow2[n - present];
    }
    final value = (container >>> (32 - bitsConsumed - n)) & kBitMasks[n];
    bitsConsumed += n;
    return value;
  }
}
