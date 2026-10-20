import 'byte_writer.dart';

/// Writes a zstd bitstream.
///
/// Zstandard bitstreams are read backwards by the decoder: the compressor
/// appends bit fields in the order they are later read, least-significant bit
/// first, into a forward-growing byte stream. After the last useful bit a
/// single `1` bit is appended as an end marker, then the final byte is padded
/// with zeroes.
///
/// The implementation keeps only a few bits in the register and flushes whole
/// bytes eagerly. This produces exactly the same bytes as the reference
/// implementation's wider accumulator, while staying within 32-bit integer
/// semantics so it behaves identically on the VM, dart2js and dartwasm.
final class BitWriter {
  BitWriter(this._output);

  final ByteWriter _output;

  int _container = 0;
  int _bitCount = 0;

  /// Number of bits currently buffered (always `< 8` between calls).
  int get bitCount => _bitCount;

  /// Appends the low [bitCount] bits of [value], least-significant bit first.
  ///
  /// [bitCount] must be at most 25, which covers every field the sequence
  /// encoder writes (offset codes are capped by the frame window).
  void addBits(int value, int bitCount) {
    if (bitCount == 0) return;
    final mask = (1 << bitCount) - 1;
    _container |= (value & mask) << _bitCount;
    _bitCount += bitCount;
    while (_bitCount >= 8) {
      _output.writeByte(_container & 0xFF);
      _container >>>= 8;
      _bitCount -= 8;
    }
  }

  /// Appends the mandatory end marker and flushes the trailing partial byte.
  void finish() {
    addBits(1, 1);
    if (_bitCount > 0) {
      _output.writeByte(_container & 0xFF);
    }
    _container = 0;
    _bitCount = 0;
  }
}
