import 'dart:convert';
import 'dart:typed_data';

import '../common/xxh64.dart';
import 'block_encoder.dart';
import 'byte_writer.dart';
import 'frame.dart';
import 'match_finder.dart';

/// Streaming-capable Zstandard encoder.
///
/// This is the public surface; the format implementation lives in the other
/// files of this directory.
///
/// ```dart
/// final encoder = ZstdEncoder(level: 3, checksum: true);
/// final compressed = encoder.convert(utf8.encode('hello'));
/// ```
///
/// v0.1.0 implements levels 1..3, raw/RLE literals and the predefined FSE
/// sequence distributions. It always produces valid frames, falling back to
/// raw blocks whenever entropy coding would not pay off.
final class ZstdEncoder extends Converter<List<int>, List<int>> {
  ZstdEncoder({this.level = 3, this.checksum = false}) {
    if (level < 1) {
      throw ArgumentError.value(level, 'level', 'must be >= 1');
    }
    if (level > 3) {
      throw UnsupportedError(
        'zstd_neo v0.1.0 implements levels 1..3; level $level is not '
        'available yet',
      );
    }
  }

  final int level;
  final bool checksum;

  /// Fast path: compress a contiguous byte buffer.
  Uint8List compress(Uint8List input) {
    final parameters = compressionParametersFor(level, input.length);
    final configuredWindow = parameters.windowSize;
    // Small inputs are stored as a single segment, which makes the content
    // size the window size and saves the window descriptor byte. Large inputs
    // keep a bounded window so decoders never have to allocate the whole
    // content up front.
    final singleSegment = input.length <= configuredWindow;

    final output = ByteWriter(input.length ~/ 2 + 64);
    writeFrameHeader(
      output,
      contentSize: input.length,
      windowSize: configuredWindow,
      singleSegment: singleSegment,
      checksum: checksum,
    );

    final blockEncoder = BlockEncoder(parameters);
    final checksumState = checksum ? Xxh64() : null;

    if (input.isEmpty) {
      blockEncoder.writeBlock(output, input, 0, 0, 0, last: true);
    } else {
      final step = parameters.blockSize;
      var position = 0;
      while (position < input.length) {
        final end = position + step < input.length
            ? position + step
            : input.length;
        blockEncoder.writeBlock(
          output,
          input,
          position,
          end,
          0,
          last: end == input.length,
        );
        checksumState?.update(input, position, end);
        position = end;
      }
    }

    if (checksumState != null) {
      output.writeUint32(checksumState.digest().low32);
    }
    return output.takeBytes();
  }

  @override
  Uint8List convert(List<int> input) =>
      compress(input is Uint8List ? input : Uint8List.fromList(input));

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) =>
      _ZstdEncoderSink(this, sink);
}

/// Streaming encoder state.
///
/// Bytes are buffered until a complete block is available, so memory use is
/// bounded by `Window_Size + Block_Maximum_Size` rather than by the input size.
final class _ZstdEncoderSink extends ByteConversionSink {
  _ZstdEncoderSink(this._encoder, this._output)
    : _parameters = compressionParametersForStreaming(_encoder.level),
      _checksum = _encoder.checksum ? Xxh64() : null {
    _blockEncoder = BlockEncoder(_parameters);
    _buffer = Uint8List(_parameters.windowSize + _parameters.blockSize);
  }

  final ZstdEncoder _encoder;
  final Sink<List<int>> _output;
  final CompressionParameters _parameters;
  final Xxh64? _checksum;

  late final BlockEncoder _blockEncoder;
  late final Uint8List _buffer;
  final ByteWriter _blockOutput = ByteWriter(zstdBlockBufferSize);

  int _bufferLength = 0;
  int _blockStart = 0;
  int _streamBase = 0;
  bool _headerWritten = false;
  bool _closed = false;

  @override
  void add(List<int> chunk) {
    if (_closed) {
      throw StateError('add() called after close()');
    }
    final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    if (bytes.isEmpty) return;
    _addBytes(bytes, 0, bytes.length);
  }

  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    if (_closed) {
      throw StateError('addSlice() called after close()');
    }
    RangeError.checkValidRange(start, end, chunk.length);
    final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    if (end > start) {
      _addBytes(bytes, start, end);
    }
    if (isLast) {
      close();
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _ensureHeader();
    _blockOutput.clear();
    _blockEncoder.writeBlock(
      _blockOutput,
      _buffer,
      _blockStart,
      _bufferLength,
      _streamBase,
      last: true,
    );
    _blockStart = _bufferLength;
    _output.add(_blockOutput.takeBytes());
    if (_checksum != null) {
      final tail = ByteWriter(4);
      tail.writeUint32(_checksum.digest().low32);
      _output.add(tail.takeBytes());
    }
    _output.close();
  }

  void _ensureHeader() {
    if (_headerWritten) return;
    _headerWritten = true;
    final header = ByteWriter(32);
    writeFrameHeader(
      header,
      contentSize: null,
      windowSize: _parameters.windowSize,
      singleSegment: false,
      checksum: _encoder.checksum,
    );
    _output.add(header.takeBytes());
  }

  void _addBytes(Uint8List bytes, int start, int end) {
    _ensureHeader();
    _checksum?.update(bytes, start, end);
    final blockSize = _parameters.blockSize;
    while (start < end) {
      if (_bufferLength - _blockStart == blockSize) {
        _emitFullBlock();
        _compact();
        continue;
      }
      final pending = _bufferLength - _blockStart;
      final roomForBlock = blockSize - pending;
      final free = _buffer.length - _bufferLength;
      var take = free < roomForBlock ? free : roomForBlock;
      final remaining = end - start;
      if (take > remaining) take = remaining;
      if (take <= 0) {
        // Defensive; the buffer math guarantees forward progress.
        _compact();
        continue;
      }
      _buffer.setRange(_bufferLength, _bufferLength + take, bytes, start);
      _bufferLength += take;
      start += take;
    }
  }

  void _emitFullBlock() {
    final end = _blockStart + _parameters.blockSize;
    _blockOutput.clear();
    _blockEncoder.writeBlock(
      _blockOutput,
      _buffer,
      _blockStart,
      end,
      _streamBase,
      last: false,
    );
    _blockStart = end;
    _output.add(_blockOutput.takeBytes());
  }

  /// Drops history older than the configured window.
  void _compact() {
    final keepFrom = _blockStart - _parameters.windowSize;
    if (keepFrom <= 0) return;
    final remaining = _bufferLength - keepFrom;
    _buffer.setRange(0, remaining, _buffer, keepFrom);
    _bufferLength = remaining;
    _blockStart -= keepFrom;
    _streamBase += keepFrom;
  }
}

/// Default capacity for a reusable block assembly buffer.
const int zstdBlockBufferSize = 128 * 1024 + 64;
