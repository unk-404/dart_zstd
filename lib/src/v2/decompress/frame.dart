/// Frame header parsing and the per-frame decoding state.
library;

import 'dart:typed_data';

import '../../common/constants.dart';
import '../../common/errors.dart';
import 'bit_stream.dart';
import 'dictionary.dart';
import 'fse.dart';
import 'huffman.dart';

/// Hard implementation limit on the window: rings are indexed with 32-bit-safe
/// arithmetic. The default `maxWindowSize` (64 MiB) is well below it.
const int kDecoderMaxWindowSize = 1 << 30;

/// Parsed `Frame_Header`.
final class FrameHeader {
  FrameHeader({
    required this.windowSize,
    required this.frameContentSize,
    required this.dictionaryId,
    required this.contentChecksum,
    required this.singleSegment,
    required this.headerEnd,
  });

  /// Maximum back-reference distance allowed by this frame.
  final int windowSize;

  /// Declared decompressed size, or -1 when absent.
  final int frameContentSize;

  final int dictionaryId;
  final bool contentChecksum;
  final bool singleSegment;

  /// Absolute input offset of the first block header.
  final int headerEnd;

  bool get hasContentSize => frameContentSize >= 0;
}

/// Parses a frame header whose descriptor starts at [pos] (the magic number has
/// already been consumed). [end] is exclusive.
FrameHeader parseFrameHeader(
  Uint8List data,
  int pos,
  int end,
  int maxWindowSize,
) {
  if (pos >= end) {
    throw const ZstdException(
      ZstdErrorCode.truncatedInput,
      'missing frame header descriptor',
    );
  }
  final descriptor = data[pos];
  if ((descriptor & 0x08) != 0) {
    throw ZstdException(
      ZstdErrorCode.reservedField,
      'frame header reserved bit is set',
      offset: pos,
    );
  }
  final fcsFlag = descriptor >> 6;
  final singleSegment = (descriptor >> 5) & 1;
  final contentChecksum = (descriptor >> 2) & 1;
  final dictionaryIdFlag = descriptor & 3;

  final fcsSize = fcsFlag == 0
      ? (singleSegment != 0 ? 1 : 0)
      : (fcsFlag == 1
            ? 2
            : fcsFlag == 2
            ? 4
            : 8);
  final didSize = dictionaryIdFlag == 0
      ? 0
      : (dictionaryIdFlag == 1
            ? 1
            : dictionaryIdFlag == 2
            ? 2
            : 4);
  final headerSize = 1 + (singleSegment != 0 ? 0 : 1) + didSize + fcsSize;
  if (end - pos < headerSize) {
    throw ZstdException(
      ZstdErrorCode.truncatedInput,
      'truncated frame header',
      offset: pos,
    );
  }

  var cursor = pos + 1;
  var windowSize = 0;
  if (singleSegment == 0) {
    final windowDescriptor = data[cursor++];
    final exponent = windowDescriptor >> 3;
    final mantissa = windowDescriptor & 7;
    final windowBase = kPow2[10 + exponent];
    windowSize = windowBase + (windowBase ~/ 8) * mantissa;
  }

  var dictionaryId = 0;
  if (didSize == 1) {
    dictionaryId = data[cursor];
  } else if (didSize == 2) {
    dictionaryId = data[cursor] | (data[cursor + 1] << 8);
  } else if (didSize == 4) {
    dictionaryId = readLe32(data, cursor);
  }
  cursor += didSize;

  var frameContentSize = -1;
  if (fcsSize > 0) {
    if (fcsSize == 8) {
      final hi = readLe32(data, cursor + 4);
      // Keep the value exactly representable on every platform (2^53 - 1).
      if (hi > 0x1FFFFF) {
        throw ZstdException(
          ZstdErrorCode.outputTooLarge,
          'frame content size is not representable on all platforms',
          offset: pos,
        );
      }
      frameContentSize = hi * 4294967296 + readLe32(data, cursor);
    } else if (fcsSize == 4) {
      frameContentSize = readLe32(data, cursor);
    } else if (fcsSize == 2) {
      frameContentSize = (data[cursor] | (data[cursor + 1] << 8)) + 256;
    } else {
      frameContentSize = data[cursor];
    }
    cursor += fcsSize;
  }

  if (singleSegment != 0) {
    // "the maximum back-reference distance is the content size itself".
    windowSize = frameContentSize;
  }

  if (windowSize > maxWindowSize) {
    throw ZstdException(
      ZstdErrorCode.windowTooLarge,
      'frame window $windowSize exceeds maxWindowSize $maxWindowSize',
      offset: pos,
    );
  }
  if (windowSize > kDecoderMaxWindowSize) {
    throw ZstdException(
      ZstdErrorCode.windowTooLarge,
      'frame window $windowSize exceeds the decoder limit '
      '$kDecoderMaxWindowSize',
      offset: pos,
    );
  }
  if (frameContentSize > 0x1FFFFFFFFFFFFF) {
    throw ZstdException(
      ZstdErrorCode.outputTooLarge,
      'frame content size is not representable on all platforms',
      offset: pos,
    );
  }

  return FrameHeader(
    windowSize: windowSize,
    frameContentSize: frameContentSize,
    dictionaryId: dictionaryId,
    contentChecksum: contentChecksum != 0,
    singleSegment: singleSegment != 0,
    headerEnd: cursor,
  );
}

/// Mutable state carried across the blocks of one frame.
final class FrameContext {
  FrameContext(this.header, this.dictionary) {
    final dict = dictionary;
    if (dict != null && dict.isFormatted) {
      huffman = dict.huffman;
      ofTable = dict.ofTable;
      mlTable = dict.mlTable;
      llTable = dict.llTable;
      final reps = dict.repOffsets;
      if (reps != null) {
        repOffsets[0] = reps[0];
        repOffsets[1] = reps[1];
        repOffsets[2] = reps[2];
      }
    }
  }

  final FrameHeader header;
  final ParsedDictionary? dictionary;

  /// Entropy state reused by `Repeat_Mode` and `Treeless_Literals_Block`.
  HuffmanTable? huffman;
  FseTable? llTable;
  FseTable? ofTable;
  FseTable? mlTable;

  /// Repeated offsets, most recent first.
  final List<int> repOffsets = <int>[1, 4, 8];

  /// Bytes produced by this frame so far, and by the block being decoded.
  int frameOut = 0;
  int blockOut = 0;

  Uint8List _literalsScratch = Uint8List(0);

  int get windowSize => header.windowSize;

  /// `Block_Maximum_Size`: the smaller of the window and 128 KiB.
  int get blockMax => header.windowSize < zstdBlockSizeMax
      ? header.windowSize
      : zstdBlockSizeMax;

  Uint8List get dictionaryContent => dictionary?.content ?? _emptyBytes;

  static final Uint8List _emptyBytes = Uint8List(0);

  /// A reusable buffer for decoded literals of at least [size] bytes.
  Uint8List literalsScratch(int size) {
    if (_literalsScratch.length >= size) return _literalsScratch;
    final grown = Uint8List(size < 1024 ? 1024 : size);
    _literalsScratch = grown;
    return grown;
  }
}
