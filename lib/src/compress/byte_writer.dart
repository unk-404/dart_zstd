import 'dart:typed_data';

/// A small growable byte buffer used to assemble frames and blocks.
///
/// The writer is deliberately minimal: appending bytes is the hot path, so it
/// works directly on a [Uint8List] and grows by doubling. It also supports
/// patching an already written little-endian integer, which lets the block
/// writer reserve a block header before it knows whether the block will end up
/// compressed or raw.
final class ByteWriter {
  ByteWriter([int initialCapacity = 256])
    : _buffer = Uint8List(initialCapacity < 16 ? 16 : initialCapacity);

  Uint8List _buffer;
  int _length = 0;

  /// Number of bytes written so far.
  int get length => _length;

  /// Discards all bytes while keeping the allocated capacity.
  void clear() {
    _length = 0;
  }

  void _ensure(int extra) {
    final required = _length + extra;
    if (required <= _buffer.length) return;
    var capacity = _buffer.length * 2;
    while (capacity < required) {
      capacity *= 2;
    }
    final grown = Uint8List(capacity);
    grown.setRange(0, _length, _buffer);
    _buffer = grown;
  }

  /// Appends the low 8 bits of [value].
  void writeByte(int value) {
    _ensure(1);
    _buffer[_length++] = value & 0xFF;
  }

  /// Appends `source[start..end)`.
  void writeBytes(Uint8List source, [int start = 0, int? end]) {
    final stop = end ?? source.length;
    if (stop <= start) return;
    final count = stop - start;
    _ensure(count);
    _buffer.setRange(_length, _length + count, source, start);
    _length += count;
  }

  /// Appends [value] as an unsigned 16-bit little-endian integer.
  void writeUint16(int value) {
    writeByte(value);
    writeByte(value >>> 8);
  }

  /// Appends [value] as an unsigned 24-bit little-endian integer.
  void writeUint24(int value) {
    writeByte(value);
    writeByte(value >>> 8);
    writeByte(value >>> 16);
  }

  /// Appends [value] as an unsigned 32-bit little-endian integer.
  void writeUint32(int value) {
    writeByte(value);
    writeByte(value >>> 8);
    writeByte(value >>> 16);
    writeByte(value >>> 24);
  }

  /// Appends [value] as an unsigned 64-bit little-endian integer.
  ///
  /// Only values that are exactly representable as a Dart [int] on the web
  /// (up to 2^53) can occur for frame content sizes.
  void writeUint64(int value) {
    writeUint32(value & 0xFFFFFFFF);
    writeUint32(value ~/ 0x100000000);
  }

  /// Overwrites the three bytes at [offset] with a 24-bit little-endian value.
  void patchUint24(int offset, int value) {
    RangeError.checkValidRange(offset, offset + 3, _length);
    _buffer[offset] = value & 0xFF;
    _buffer[offset + 1] = (value >>> 8) & 0xFF;
    _buffer[offset + 2] = (value >>> 16) & 0xFF;
  }

  /// Truncates the buffer to its first [length] bytes.
  void truncate(int length) {
    RangeError.checkValidRange(0, length, _length);
    _length = length;
  }

  /// Returns a copy of the written bytes.
  Uint8List takeBytes() {
    final out = Uint8List(_length);
    out.setRange(0, _length, _buffer);
    return out;
  }
}
