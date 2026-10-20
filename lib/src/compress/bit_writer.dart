import 'dart:typed_data';

/// Writes a zstd bitstream.
///
/// Zstandard bitstreams are read backwards by the decoder: the compressor
/// appends bit fields in the order they are later read, least-significant bit
/// first, into a forward-growing byte stream. After the last useful bit a
/// single `1` bit is appended as an end marker, then the final byte is padded
/// with zeroes.
///
/// Bytes accumulate in an internal flat `Uint8List` so the encoder's hottest
/// paths avoid a method call per output byte. [finish] returns the number of
/// bytes produced and [bytes] exposes them as a view; call [reset] before
/// reusing the writer.
final class BitWriter {
  BitWriter([int initialCapacity = 1024])
    : _buffer = Uint8List(initialCapacity < 16 ? 16 : initialCapacity);

  Uint8List _buffer;
  int _length = 0;
  int _container = 0;
  int _bitCount = 0;

  /// Number of complete bytes produced so far.
  int get length => _length;

  /// Number of bits buffered in the register (`< 8` between calls).
  int get bitCount => _bitCount;

  /// The bytes produced by [finish]; valid until [reset] or the next write.
  Uint8List get bytes => Uint8List.sublistView(_buffer, 0, _length);

  void _grow() {
    final grown = Uint8List(_buffer.length * 2);
    grown.setRange(0, _length, _buffer);
    _buffer = grown;
  }

  /// Appends the low [bitCount] bits of [value], least-significant bit first.
  @pragma('vm:prefer-inline')
  void addBits(int value, int bitCount) {
    if (bitCount == 0) return;
    _container |= (value & ((1 << bitCount) - 1)) << _bitCount;
    _bitCount += bitCount;
    while (_bitCount >= 8) {
      if (_length == _buffer.length) _grow();
      _buffer[_length++] = _container & 0xFF;
      _container >>>= 8;
      _bitCount -= 8;
    }
  }

  /// Appends the mandatory end marker and flushes the trailing partial byte.
  ///
  /// Returns the number of bytes produced. The writer is not reset; call
  /// [reset] when reusing it.
  int finish() {
    addBits(1, 1);
    if (_bitCount > 0) {
      if (_length == _buffer.length) _grow();
      _buffer[_length++] = _container & 0xFF;
      _container = 0;
      _bitCount = 0;
    }
    return _length;
  }

  /// Clears the produced bytes while keeping the allocated capacity.
  void reset() {
    _length = 0;
    _container = 0;
    _bitCount = 0;
  }
}
