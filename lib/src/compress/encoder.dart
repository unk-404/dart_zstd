import 'dart:convert';
import 'dart:typed_data';

import '../common/xxh64.dart';
import '../v2/compress/encoder.dart';
import 'block_encoder.dart';
import 'byte_writer.dart';
import 'dictionary.dart';
import 'fast_flag.dart' if (dart.library.js_interop) 'fast_flag_web.dart';
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
/// Levels 1..19 are implemented. Levels up to 9 use fast/double-fast, greedy,
/// lazy and lazy2 parsers; levels 10..19 use the same lazy2 parser with
/// progressively deeper chain searches (the reference implementation's bt*
/// optimal parsers are approximated, so very high levels may trail libzstd on
/// ratio). Entropy coding covers Huffman literals (including treeless repeat)
/// and predefined/custom/RLE/repeat FSE sequence tables.
final class ZstdEncoder extends Converter<List<int>, List<int>> {
  ZstdEncoder({this.level = 3, this.checksum = false, this.dictionary}) {
    if (level < 1 || level > 19) {
      throw ArgumentError.value(level, 'level', 'must be in 1..19');
    }
  }

  /// Compression level, 1..19.
  final int level;

  /// Whether the encoder appends the 4-byte XXH64 content checksum.
  final bool checksum;

  /// Optional raw-content or formatted zstd dictionary.
  final Uint8List? dictionary;

  /// Cached single-shot v2 encoder (streaming still uses this v1 engine).
  ZstdV2Encoder? _fastEncoder;

  /// Fast path: compress a contiguous byte buffer.
  Uint8List compress(Uint8List input) {
    if (kUseFastEncoder) {
      final dictionary = this.dictionary;
      return (_fastEncoder ??= ZstdV2Encoder(
        level: level,
        checksum: checksum,
        dictionary: dictionary != null && dictionary.isNotEmpty
            ? dictionary
            : null,
      )).compress(input);
    }
    return _compressV1(input);
  }

  Uint8List _compressV1(Uint8List input) {
    final parsedDictionary = dictionary == null
        ? null
        : EncoderDictionary.parse(dictionary!);
    final parameters = compressionParametersFor(level, input.length);
    final configuredWindow = parameters.windowSize;
    final prefixLength = parsedDictionary == null
        ? 0
        : _min(parsedDictionary.content.length, configuredWindow);
    // Small inputs without a dictionary are stored as a single segment, which
    // makes the content size the window size and saves the window descriptor.
    // Dictionary frames always keep an explicit window so that dictionary
    // references stay inside it.
    final singleSegment =
        parsedDictionary == null && input.length <= configuredWindow;

    final output = ByteWriter(input.length ~/ 2 + 64);
    writeFrameHeader(
      output,
      contentSize: parsedDictionary == null || input.length >= 256
          ? input.length
          : null,
      windowSize: configuredWindow,
      singleSegment: singleSegment,
      checksum: checksum,
      dictionaryId: parsedDictionary?.dictionaryId ?? 0,
    );

    final blockEncoder = BlockEncoder(
      parameters,
      initialRepCodes: parsedDictionary?.repOffsets,
    );
    final checksumState = checksum ? Xxh64() : null;

    Uint8List data;
    int blockBase;
    if (prefixLength == 0) {
      data = input;
      blockBase = 0;
    } else {
      data = Uint8List(prefixLength + input.length);
      data.setRange(
        0,
        prefixLength,
        parsedDictionary!.content,
        parsedDictionary.content.length - prefixLength,
      );
      data.setRange(prefixLength, data.length, input);
      blockBase = prefixLength;
      blockEncoder.loadPrefix(data, 0, prefixLength, 0);
    }

    if (input.isEmpty && prefixLength == 0) {
      blockEncoder.writeBlock(output, data, 0, 0, 0, last: true);
    } else {
      final step = parameters.blockSize;
      var position = 0;
      while (position < input.length) {
        final end = position + step < input.length
            ? position + step
            : input.length;
        final last = end == input.length;
        blockEncoder.writeBlock(
          output,
          data,
          blockBase + position,
          blockBase + end,
          0,
          last: last,
        );
        checksumState?.update(input, position, end);
        position = end;
      }
      if (input.isEmpty) {
        // Empty input with a dictionary: one empty last block.
        blockEncoder.writeBlock(
          output,
          data,
          blockBase,
          blockBase,
          0,
          last: true,
        );
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
    final parsedDictionary = _encoder.dictionary == null
        ? null
        : EncoderDictionary.parse(_encoder.dictionary!);
    _dictionaryId = parsedDictionary?.dictionaryId ?? 0;
    final repCodes = parsedDictionary?.repOffsets;
    _blockEncoder = BlockEncoder(_parameters, initialRepCodes: repCodes);
    _buffer = Uint8List(_parameters.windowSize + _parameters.blockSize);
    if (parsedDictionary != null) {
      final prefixLength = _min(
        parsedDictionary.content.length,
        _parameters.windowSize,
      );
      if (prefixLength > 0) {
        _buffer.setRange(
          0,
          prefixLength,
          parsedDictionary.content,
          parsedDictionary.content.length - prefixLength,
        );
        _blockEncoder.loadPrefix(_buffer, 0, prefixLength, 0);
        _bufferLength = prefixLength;
        _blockStart = prefixLength;
      }
    }
  }

  final ZstdEncoder _encoder;
  final Sink<List<int>> _output;
  final CompressionParameters _parameters;
  final Xxh64? _checksum;

  late final BlockEncoder _blockEncoder;
  late final Uint8List _buffer;
  final ByteWriter _blockOutput = ByteWriter(zstdBlockBufferSize);

  int _dictionaryId = 0;
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
      dictionaryId: _dictionaryId,
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

int _min(int a, int b) => a < b ? a : b;
