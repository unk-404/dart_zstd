/// Bounded ring buffer used by the streaming decoder.
///
/// The buffer keeps at most `window + block` bytes: history that can still be
/// referenced plus the block being decoded. Capacity is a power of two so that
/// indexes (which stay below 2^31) can be masked, including on the web.
library;

import 'dart:typed_data';

import '../common/errors.dart';

final class RingWindow {
  RingWindow(this.windowSize);

  final int windowSize;

  Uint8List _buffer = Uint8List(0);
  int _mask = 0;
  int _pos = 0;

  Uint8List get buffer => _buffer;
  int get mask => _mask;
  int get capacity => _buffer.length;

  /// Write position in the ring; also the start of the next block to be
  /// written.
  int get position => _pos;

  /// Makes room for [historyKeep] bytes of history followed by [extra] new
  /// bytes. Reallocates geometrically and re-lays the retained history at the
  /// beginning of the new buffer.
  void ensure(int historyKeep, int extra) {
    final needed = historyKeep + extra;
    if (_buffer.length >= needed && _buffer.isNotEmpty) return;
    var cap = _buffer.isEmpty ? 1 : _buffer.length;
    while (cap < needed) {
      cap <<= 1;
    }
    final grown = Uint8List(cap);
    if (historyKeep > 0) {
      final oldMask = _mask;
      var read = (_pos - historyKeep) & oldMask;
      for (var i = 0; i < historyKeep; i++) {
        grown[i] = _buffer[read];
        read = (read + 1) & oldMask;
      }
    }
    _buffer = grown;
    _mask = cap - 1;
    _pos = historyKeep;
  }

  void advance(int length) {
    _pos = (_pos + length) & _mask;
  }

  /// Writes raw bytes at the current position.
  void writeRaw(Uint8List src, int srcStart, int length) {
    if (length <= 0) return;
    final room = _buffer.length - _pos;
    final first = length < room ? length : room;
    _buffer.setRange(_pos, _pos + first, src, srcStart);
    if (length > first) {
      _buffer.setRange(0, length - first, src, srcStart + first);
    }
    _pos = (_pos + length) & _mask;
  }

  /// Writes one byte repeated [length] times.
  void fill(int byte, int length) {
    if (length <= 0) return;
    final room = _buffer.length - _pos;
    final first = length < room ? length : room;
    _buffer.fillRange(_pos, _pos + first, byte);
    if (length > first) {
      _buffer.fillRange(0, length - first, byte);
    }
    _pos = (_pos + length) & _mask;
  }

  /// Copies [length] bytes from [offset] back (already validated by the
  /// caller). Handles overlap and wrap-around.
  void copyMatch(int offset, int length) {
    if (length <= 0) return;
    if (offset <= 0) {
      throw const ZstdException(
        ZstdErrorCode.invalidSequence,
        'non-positive match offset',
      );
    }
    final cap = _buffer.length;
    final mask = _mask;
    final writeStart = _pos;
    final readStart = (_pos - offset) & mask;
    if (offset >= length &&
        writeStart + length <= cap &&
        readStart + length <= cap) {
      _buffer.setRange(writeStart, writeStart + length, _buffer, readStart);
      _pos = (writeStart + length) & mask;
      return;
    }
    var write = writeStart;
    var read = readStart;
    for (var i = 0; i < length; i++) {
      _buffer[write] = _buffer[read];
      write = (write + 1) & mask;
      read = (read + 1) & mask;
    }
    _pos = write;
  }

  /// Visits the [length] bytes starting at physical position [start], split in
  /// at most two contiguous views.
  void forEachSegment(
    int start,
    int length,
    void Function(Uint8List bytes) visit,
  ) {
    if (length <= 0) return;
    final room = _buffer.length - start;
    final first = length < room ? length : room;
    if (first > 0) {
      visit(Uint8List.sublistView(_buffer, start, start + first));
    }
    if (length > first) {
      visit(Uint8List.sublistView(_buffer, 0, length - first));
    }
  }
}
