import 'dart:convert';
import 'dart:typed_data';

import '../../common/xxh64.dart';
import 'block_encoder.dart';
import 'byte_writer.dart';
import 'dictionary.dart';
import 'frame.dart';
import 'match_finder.dart';

/// Streaming-capable Zstandard encoder.
///
/// This is the public surface; the format implementation lives in the other
/// files of this directory.
///
/// ```dart
/// final encoder = ZstdV2Encoder(level: 3, checksum: true);
/// final compressed = encoder.convert(utf8.encode('hello'));
/// ```
///
/// Levels 1..19 are implemented. Levels up to 9 use fast/double-fast, greedy,
/// lazy and lazy2 parsers; levels 10..19 use the same lazy2 parser with
/// progressively deeper chain searches (the reference implementation's bt*
/// optimal parsers are approximated, so very high levels may trail libzstd on
/// ratio). Entropy coding covers Huffman literals (including treeless repeat)
/// and predefined/custom/RLE/repeat FSE sequence tables.
final class ZstdV2Encoder extends Converter<List<int>, List<int>> {
  ZstdV2Encoder({this.level = 3, this.checksum = false, this.dictionary}) {
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

  /// Fast path: compress a contiguous byte buffer.
  Uint8List compress(Uint8List input) {
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
      blockEncoder.loadPrefix(data, 0, prefixLength);
    }

    if (input.isEmpty && prefixLength == 0) {
      blockEncoder.writeBlock(output, data, 0, 0, last: true);
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
          last: last,
        );
        checksumState?.update(input, position, end);
        position = end;
      }
      if (input.isEmpty) {
        // Empty input with a dictionary: one empty last block.
        blockEncoder.writeBlock(output, data, blockBase, blockBase, last: true);
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
      _ZstdV2EncoderSink(this, sink);
}

/// Streaming encoder state.
///
/// The v2 engine compresses complete buffers, so this adapter collects the
/// chunks and emits one frame on close (checking the checksum end-to-end).
/// The trade-off is that the sink holds the whole input in memory, which keeps
/// the encoder core free of buffer sliding/rebasing logic.
final class _ZstdV2EncoderSink extends ByteConversionSink {
  _ZstdV2EncoderSink(this._encoder, this._output);

  final ZstdV2Encoder _encoder;
  final Sink<List<int>> _output;
  final BytesBuilder _buffer = BytesBuilder();
  bool _closed = false;

  @override
  void add(List<int> chunk) {
    if (_closed) {
      throw StateError('add() called after close()');
    }
    _buffer.add(chunk);
  }

  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    if (_closed) {
      throw StateError('addSlice() called after close()');
    }
    RangeError.checkValidRange(start, end, chunk.length);
    if (end > start) {
      _buffer.add(chunk.sublist(start, end));
    }
    if (isLast) close();
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _output.add(_encoder.compress(_buffer.takeBytes()));
    _output.close();
  }
}

/// Default capacity for a reusable block assembly buffer.
const int zstdBlockBufferSize = 128 * 1024 + 64;

int _min(int a, int b) => a < b ? a : b;
