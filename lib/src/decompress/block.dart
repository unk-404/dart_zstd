/// Compressed block decoding: literals section, sequences section, execution.
library;

import 'dart:typed_data';

import '../common/errors.dart';
import 'bit_stream.dart';
import 'frame.dart';
import 'fse.dart';
import 'huffman.dart';
import 'window.dart';

/// Literals length code baselines (codes 0..35).
const List<int> kLiteralsLengthBase = <int>[
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, //
  16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096, //
  8192, 16384, 32768, 65536,
];

/// Number of additional bits for each literals length code.
const List<int> kLiteralsLengthExtra = <int>[
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, //
  13, 14, 15, 16,
];

/// Match length code baselines (codes 0..52).
const List<int> kMatchLengthBase = <int>[
  3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, //
  17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, //
  31, 32, 33, 34, 35, 37, 39, 41, 43, 47, 51, 59, 67, 83, //
  99, 131, 259, 515, 1027, 2051, 4099, 8195, 16387, 32771, 65539,
];

const List<int> _kMlPacked = <int>[
  3,
  4,
  5,
  6,
  7,
  8,
  9,
  10,
  11,
  12,
  13,
  14,
  15,
  16,
  17,
  18,
  19,
  20,
  21,
  22,
  23,
  24,
  25,
  26,
  27,
  28,
  29,
  30,
  31,
  32,
  33,
  34,
  131107,
  131109,
  131111,
  131113,
  262187,
  262191,
  393267,
  393275,
  524355,
  524371,
  655459,
  917635,
  1048835,
  1180163,
  1311747,
  1443843,
  1576963,
  1712131,
  1851395,
  1998851,
  2162691,
];

const List<int> _kLlPacked = <int>[
  0,
  1,
  2,
  3,
  4,
  5,
  6,
  7,
  8,
  9,
  10,
  11,
  12,
  13,
  14,
  15,
  131088,
  131090,
  131092,
  131094,
  262168,
  262172,
  393248,
  393256,
  524336,
  786496,
  917632,
  1048832,
  1180160,
  1311744,
  1443840,
  1576960,
  1712128,
  1851392,
  1998848,
  2162688,
];

/// Number of additional bits for each match length code.
const List<int> kMatchLengthExtra = <int>[
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, //
  12, 13, 14, 15, 16,
];

/// Decoded literals, possibly a view into the compressed input.
final class BlockLiterals {
  BlockLiterals(this.bytes, this.start, this.length);

  final Uint8List bytes;
  final int start;
  final int length;
}

/// Reads [n] bits from [window]'s fast path, falling back to the full reader
/// only when the window is exhausted. Kept tiny so AOT/dart2js inline it.
@pragma('vm:prefer-inline')
int _readBits(BitWindow window, int n) {
  final available = 32 - window.bitsConsumed;
  if (available >= n) {
    final value = (window.container >>> (available - n)) & kBitMasks[n];
    window.bitsConsumed += n;
    return value;
  }
  return window.readBits(n);
}

/// Destination for the literals and matches of one compressed block.
///
/// One concrete class is used for both one-shot (contiguous frame buffer) and
/// streaming (ring buffer) decoding. Keeping a single receiver type lets the
/// optimizing compiler devirtualize and inline the two hot methods.
final class BlockOutput {
  BlockOutput.contiguous(this.context, this.buffer, int startPosition)
    : ring = null,
      position = startPosition,
      frameOut = context.frameOut,
      windowSize = context.windowSize,
      dictionary = context.dictionaryContent;

  BlockOutput.ring(this.context, this.ring)
    : buffer = _emptyBuffer,
      position = 0,
      frameOut = context.frameOut,
      windowSize = context.windowSize,
      dictionary = context.dictionaryContent;

  final FrameContext context;
  final Uint8List buffer;
  final RingWindow? ring;
  int position;

  /// Frame bytes decoded before this block (constant while the block decodes).
  final int frameOut;
  final int windowSize;
  final Uint8List dictionary;

  /// Bytes produced by this block. Kept writable so the sequence hot loop can
  /// update it directly and avoid a method call per sequence.
  int blockOut = 0;

  static final Uint8List _emptyBuffer = Uint8List(0);

  void writeLiterals(Uint8List src, int srcStart, int length) {
    final r = ring;
    if (r == null) {
      final b = buffer;
      final at = position;
      if (length <= 3) {
        for (var i = 0; i < length; i++) {
          b[at + i] = src[srcStart + i];
        }
      } else {
        b.setRange(at, at + length, src, srcStart);
      }
      position = at + length;
    } else {
      r.writeRaw(src, srcStart, length);
    }
    blockOut += length;
  }

  void copyMatch(int offset, int length) {
    final r = ring;
    if (r == null) {
      _copyContiguous(offset, length);
    } else {
      _copyRing(r, offset, length);
    }
  }

  void _copyContiguous(int offset, int length) {
    final available = frameOut + blockOut;
    if (available <= windowSize) {
      if (offset > available + dictionary.length) {
        throw const ZstdException(
          ZstdErrorCode.invalidSequence,
          'match offset exceeds the available history and dictionary',
        );
      }
      if (offset > available) {
        final dictionaryCopy = offset - available < length
            ? offset - available
            : length;
        final dictionaryOffset = dictionary.length - (offset - available);
        buffer.setRange(
          position,
          position + dictionaryCopy,
          dictionary,
          dictionaryOffset,
        );
        position += dictionaryCopy;
        blockOut += dictionaryCopy;
        length -= dictionaryCopy;
      }
    } else if (offset > windowSize) {
      throw const ZstdException(
        ZstdErrorCode.invalidSequence,
        'match offset exceeds the frame window',
      );
    }
    if (length <= 0) return;
    final b = buffer;
    final start = position;
    final source = start - offset;
    if (source < 0) {
      throw const ZstdException(
        ZstdErrorCode.invalidSequence,
        'match offset reaches before the frame start',
      );
    }
    if (offset == 1) {
      b.fillRange(start, start + length, b[source]);
    } else if (offset >= length) {
      if (length <= 7) {
        for (var i = 0; i < length; i++) {
          b[start + i] = b[source + i];
        }
      } else {
        b.setRange(start, start + length, b, source);
      }
    } else if (length >= 192) {
      // Overlapping copy: copy the pattern, then double it. Every source range
      // ends where the destination range starts, so no copy overlaps itself.
      var copied = offset < length ? offset : length;
      b.setRange(start, start + copied, b, source);
      while (copied < length) {
        var next = copied;
        final remaining = length - copied;
        if (next > remaining) next = remaining;
        b.setRange(start + copied, start + copied + next, b, start);
        copied += next;
      }
    } else {
      for (var i = 0; i < length; i++) {
        b[start + i] = b[source + i];
      }
    }
    position = start + length;
    blockOut += length;
  }

  void _copyRing(RingWindow ring, int offset, int length) {
    final available = frameOut + blockOut;
    if (available <= windowSize) {
      if (offset > available + dictionary.length) {
        throw const ZstdException(
          ZstdErrorCode.invalidSequence,
          'match offset exceeds the available history and dictionary',
        );
      }
      if (offset > available) {
        final dictionaryCopy = offset - available < length
            ? offset - available
            : length;
        final dictionaryOffset = dictionary.length - (offset - available);
        ring.writeRaw(dictionary, dictionaryOffset, dictionaryCopy);
        blockOut += dictionaryCopy;
        length -= dictionaryCopy;
      }
    } else if (offset > windowSize) {
      throw const ZstdException(
        ZstdErrorCode.invalidSequence,
        'match offset exceeds the frame window',
      );
    }
    if (length <= 0) return;
    if (offset == 1) {
      ring.fill(ring.buffer[(ring.position - 1) & ring.mask], length);
    } else {
      ring.copyMatch(offset, length);
    }
    blockOut += length;
  }
}

/// Decodes one compressed block into [output].
///
/// [start] points at the first byte of the block content and [end] is
/// exclusive. All failures are reported as [ZstdException].
void decodeCompressedBlock(
  FrameContext context,
  Uint8List data,
  int start,
  int end,
  BlockOutput output,
) {
  if (end - start < 2) {
    throw const ZstdException(
      ZstdErrorCode.invalidBlockHeader,
      'compressed block is too small',
    );
  }
  final literals = _decodeLiterals(context, data, start, end);
  final sequencesStart = literals.next;
  if (sequencesStart >= end) {
    throw const ZstdException(
      ZstdErrorCode.invalidSequence,
      'compressed block has no sequences section',
    );
  }
  _decodeSequences(
    context,
    data,
    sequencesStart,
    end,
    literals.literals,
    output,
  );
  if (output.blockOut > context.blockMax) {
    throw const ZstdException(
      ZstdErrorCode.invalidSequence,
      'block output exceeds the block maximum size',
    );
  }
}

final class _LiteralsResult {
  _LiteralsResult(this.literals, this.next);

  final BlockLiterals literals;
  final int next;
}

_LiteralsResult _decodeLiterals(
  FrameContext context,
  Uint8List data,
  int start,
  int end,
) {
  final first = data[start];
  final blockType = first & 3;
  final sizeFormat = (first >> 2) & 3;
  final blockSize = end - start;

  if (blockType <= 1) {
    int regeneratedSize;
    int headerSize;
    if (sizeFormat == 0 || sizeFormat == 2) {
      headerSize = 1;
      regeneratedSize = first >> 3;
    } else if (sizeFormat == 1) {
      headerSize = 2;
      if (blockSize < 2) {
        throw const ZstdException(
          ZstdErrorCode.truncatedInput,
          'truncated literals header',
        );
      }
      regeneratedSize = (data[start] | (data[start + 1] << 8)) >> 4;
    } else {
      headerSize = 3;
      if (blockSize < 3) {
        throw const ZstdException(
          ZstdErrorCode.truncatedInput,
          'truncated literals header',
        );
      }
      regeneratedSize = readLe24(data, start) >> 4;
    }
    if (regeneratedSize > context.blockMax) {
      throw const ZstdException(
        ZstdErrorCode.invalidLiterals,
        'literal size exceeds the block maximum size',
      );
    }

    if (blockType == 0) {
      if (headerSize + regeneratedSize > blockSize) {
        throw const ZstdException(
          ZstdErrorCode.truncatedInput,
          'truncated raw literals',
        );
      }
      return _LiteralsResult(
        BlockLiterals(data, start + headerSize, regeneratedSize),
        start + headerSize + regeneratedSize,
      );
    }

    if (headerSize + 1 > blockSize) {
      throw const ZstdException(
        ZstdErrorCode.truncatedInput,
        'truncated RLE literals',
      );
    }
    final scratch = context.literalsScratch(regeneratedSize);
    final value = data[start + headerSize];
    if (regeneratedSize > 0) {
      scratch.fillRange(0, regeneratedSize, value);
    }
    return _LiteralsResult(
      BlockLiterals(scratch, 0, regeneratedSize),
      start + headerSize + 1,
    );
  }

  // Compressed or treeless Huffman literals.
  int regeneratedSize;
  int compressedSize;
  int headerSize;
  switch (sizeFormat) {
    case 0:
    case 1:
      headerSize = 3;
      break;
    case 2:
      headerSize = 4;
      break;
    default:
      headerSize = 5;
      break;
  }
  final singleStream = sizeFormat == 0;
  final minimumRead = headerSize < 4 ? 4 : headerSize;
  if (blockSize < minimumRead) {
    throw const ZstdException(
      ZstdErrorCode.truncatedInput,
      'truncated literals header',
    );
  }
  final lhc = readLe32(data, start);
  if (sizeFormat <= 1) {
    regeneratedSize = (lhc ~/ 16) & 0x3FF;
    compressedSize = (lhc ~/ 16384) & 0x3FF;
  } else if (sizeFormat == 2) {
    regeneratedSize = (lhc ~/ 16) & 0x3FFF;
    compressedSize = lhc ~/ 262144;
  } else {
    regeneratedSize = (lhc ~/ 16) & 0x3FFFF;
    compressedSize = (lhc ~/ 4194304) + data[start + 4] * 1024;
  }

  if (regeneratedSize > context.blockMax) {
    throw const ZstdException(
      ZstdErrorCode.invalidLiterals,
      'literal size exceeds the block maximum size',
    );
  }
  if (!singleStream && regeneratedSize < 6) {
    throw const ZstdException(
      ZstdErrorCode.invalidLiterals,
      'not enough literals for the 4-streams mode',
    );
  }
  if (compressedSize <= 0 || headerSize + compressedSize > blockSize) {
    throw const ZstdException(
      ZstdErrorCode.invalidLiterals,
      'compressed literals size is invalid',
    );
  }

  final payloadStart = start + headerSize;
  final payloadEnd = payloadStart + compressedSize;
  HuffmanTable? table;
  var treeSize = 0;
  if (blockType == 2) {
    final reader = ForwardBitReader(data, payloadStart, payloadEnd);
    table = HuffmanTable.readFrom(reader);
    treeSize = reader.position - payloadStart;
    context.huffman = table;
  } else {
    table = context.huffman;
    if (table == null) {
      throw const ZstdException(
        ZstdErrorCode.invalidLiterals,
        'treeless literals block without a previous Huffman table',
      );
    }
  }

  final streamsSize = compressedSize - treeSize;
  if (streamsSize < 1) {
    throw const ZstdException(
      ZstdErrorCode.truncatedInput,
      'compressed literals payload is empty',
    );
  }
  final streamsStart = payloadStart + treeSize;
  final scratch = context.literalsScratch(regeneratedSize);

  if (singleStream) {
    final bits = BackwardBitReader(data, streamsStart, payloadEnd);
    HuffmanTable.decodeStream(bits, table, scratch, 0, regeneratedSize);
  } else {
    if (streamsSize < 10) {
      throw const ZstdException(
        ZstdErrorCode.invalidLiterals,
        'compressed literals block is too small for 4 streams',
      );
    }
    final length1 = data[streamsStart] | (data[streamsStart + 1] << 8);
    final length2 = data[streamsStart + 2] | (data[streamsStart + 3] << 8);
    final length3 = data[streamsStart + 4] | (data[streamsStart + 5] << 8);
    final length4 = streamsSize - 6 - length1 - length2 - length3;
    if (length4 <= 0) {
      throw const ZstdException(
        ZstdErrorCode.invalidLiterals,
        'invalid Huffman jump table',
      );
    }
    final segmentSize = (regeneratedSize + 3) >> 2;
    if (segmentSize * 4 < regeneratedSize ||
        regeneratedSize - 3 * segmentSize < 0) {
      throw const ZstdException(
        ZstdErrorCode.invalidLiterals,
        'invalid Huffman stream decomposition',
      );
    }
    final fourthSize = regeneratedSize - 3 * segmentSize;
    final stream1 = streamsStart + 6;
    final stream2 = stream1 + length1;
    final stream3 = stream2 + length2;
    final stream4 = stream3 + length3;
    final bits1 = BackwardBitReader(data, stream1, stream2);
    HuffmanTable.decodeStream(bits1, table, scratch, 0, segmentSize);
    final bits2 = BackwardBitReader(data, stream2, stream3);
    HuffmanTable.decodeStream(bits2, table, scratch, segmentSize, segmentSize);
    final bits3 = BackwardBitReader(data, stream3, stream4);
    HuffmanTable.decodeStream(
      bits3,
      table,
      scratch,
      2 * segmentSize,
      segmentSize,
    );
    final bits4 = BackwardBitReader(data, stream4, payloadEnd);
    HuffmanTable.decodeStream(
      bits4,
      table,
      scratch,
      3 * segmentSize,
      fourthSize,
    );
  }

  return _LiteralsResult(
    BlockLiterals(scratch, 0, regeneratedSize),
    payloadEnd,
  );
}

void _decodeSequences(
  FrameContext context,
  Uint8List data,
  int start,
  int end,
  BlockLiterals literals,
  BlockOutput output,
) {
  var cursor = start;
  final byte0 = data[cursor++];
  int numberOfSequences;
  if (byte0 < 128) {
    numberOfSequences = byte0;
  } else if (byte0 < 255) {
    if (cursor >= end) {
      throw const ZstdException(
        ZstdErrorCode.truncatedInput,
        'truncated sequences count',
      );
    }
    numberOfSequences = ((byte0 - 128) << 8) + data[cursor++];
  } else {
    if (cursor + 2 > end) {
      throw const ZstdException(
        ZstdErrorCode.truncatedInput,
        'truncated sequences count',
      );
    }
    numberOfSequences = (data[cursor] | (data[cursor + 1] << 8)) + 0x7F00;
    cursor += 2;
  }

  if (numberOfSequences == 0) {
    if (cursor != end) {
      throw const ZstdException(
        ZstdErrorCode.invalidSequence,
        'extraneous data present in the sequences section',
      );
    }
    if (literals.length > 0) {
      output.writeLiterals(literals.bytes, literals.start, literals.length);
      if (output.blockOut > context.blockMax) {
        throw const ZstdException(
          ZstdErrorCode.invalidSequence,
          'block output exceeds the block maximum size',
        );
      }
    }
    return;
  }
  if (numberOfSequences * 3 > context.blockMax) {
    throw const ZstdException(
      ZstdErrorCode.invalidSequence,
      'too many sequences for the block size',
    );
  }
  if (cursor >= end) {
    throw const ZstdException(
      ZstdErrorCode.truncatedInput,
      'missing sequence compression modes',
    );
  }

  final modes = data[cursor++];
  if ((modes & 3) != 0) {
    throw ZstdException(
      ZstdErrorCode.reservedField,
      'sequence compression modes reserved bits are set',
      offset: cursor - 1,
    );
  }

  final reader = ForwardBitReader(data, cursor, end);
  final llMode = (modes >> 6) & 3;
  final ofMode = (modes >> 4) & 3;
  final mlMode = (modes >> 2) & 3;
  final llTable = _readSequenceTable(
    context,
    reader,
    _SeqPart.literalLength,
    llMode,
    context.llTable,
  );
  final ofTable = _readSequenceTable(
    context,
    reader,
    _SeqPart.offset,
    ofMode,
    context.ofTable,
  );
  final mlTable = _readSequenceTable(
    context,
    reader,
    _SeqPart.matchLength,
    mlMode,
    context.mlTable,
  );
  context.llTable = llTable;
  context.ofTable = ofTable;
  context.mlTable = mlTable;

  final streamsStart = reader.position;
  if (streamsStart >= end) {
    throw const ZstdException(
      ZstdErrorCode.truncatedInput,
      'missing sequence bit stream',
    );
  }
  final bits = BackwardBitReader(data, streamsStart, end);
  final window = BitWindow(bits);

  var llState = window.readBits(llTable.accuracyLog);
  var ofState = window.readBits(ofTable.accuracyLog);
  var mlState = window.readBits(mlTable.accuracyLog);

  var literalPosition = 0;
  final literalsBytes = literals.bytes;
  final literalsStart = literals.start;
  final literalsLength = literals.length;
  final blockMax = context.blockMax;
  final outBuffer = output.ring == null ? output.buffer : null;
  final frameOut = output.frameOut;
  final windowSize = output.windowSize;
  var rep0 = context.repOffsets[0];
  var rep1 = context.repOffsets[1];
  var rep2 = context.repOffsets[2];
  final llEntries = llTable.entries;
  final ofEntries = ofTable.entries;
  final mlEntries = mlTable.entries;

  for (var i = 0; i < numberOfSequences; i++) {
    final ofEntry = ofEntries[ofState];
    final llEntry = llEntries[llState];
    final mlEntry = mlEntries[mlState];
    final ofCode = ofEntry & 0xFF;
    final llCode = llEntry & 0xFF;
    final mlCode = mlEntry & 0xFF;
    if (llCode > kMaxLlCode || mlCode > kMaxMlCode || ofCode > kMaxOffsetCode) {
      throw const ZstdException(
        ZstdErrorCode.invalidSequence,
        'sequence code out of range',
      );
    }

    final ofExtraBits = ofCode;
    final mlPacked = _kMlPacked[mlCode];
    final mlExtraBits = mlPacked >>> 17;
    final llPacked = _kLlPacked[llCode];
    final llExtraBits = llPacked >>> 17;
    final extraBits = ofExtraBits + mlExtraBits + llExtraBits;
    final int offsetValue;
    final int matchLength;
    final int literalLength;
    if (extraBits <= 24) {
      // Fast path: the three extra fields are contiguous, so a single window
      // read plus shifts replaces three reader calls.
      final extraValue = extraBits > 0 ? _readBits(window, extraBits) : 0;
      final llPart = extraValue & kBitMasks[llExtraBits];
      final mlPart = (extraValue >>> llExtraBits) & kBitMasks[mlExtraBits];
      final ofPart = extraValue >>> (llExtraBits + mlExtraBits);
      offsetValue = kPow2[ofCode] + ofPart;
      matchLength = (mlPacked & 0x1FFFF) + mlPart;
      literalLength = (llPacked & 0x1FFFF) + llPart;
    } else {
      offsetValue =
          kPow2[ofCode] +
          (ofExtraBits > 0 ? _readBits(window, ofExtraBits) : 0);
      matchLength =
          (mlPacked & 0x1FFFF) +
          (mlExtraBits > 0 ? _readBits(window, mlExtraBits) : 0);
      literalLength =
          (llPacked & 0x1FFFF) +
          (llExtraBits > 0 ? _readBits(window, llExtraBits) : 0);
    }

    // Repeated-offset resolution, inlined with local registers.
    int offset;
    if (offsetValue > 3) {
      offset = offsetValue - 3;
      rep2 = rep1;
      rep1 = rep0;
      rep0 = offset;
    } else {
      var index = offsetValue - 1;
      if (literalLength == 0) index++;
      if (index == 0) {
        offset = rep0;
      } else {
        offset = index == 3 ? rep0 - 1 : (index == 1 ? rep1 : rep2);
        if (index > 1) rep2 = rep1;
        rep1 = rep0;
        rep0 = offset;
      }
    }
    if (offset <= 0) {
      throw const ZstdException(
        ZstdErrorCode.invalidSequence,
        'repeat offset resolved to a non-positive distance',
      );
    }

    if (literalLength > literalsLength - literalPosition) {
      throw const ZstdException(
        ZstdErrorCode.invalidSequence,
        'sequence consumes more literals than available',
      );
    }
    if (literalLength + matchLength > blockMax - output.blockOut) {
      throw const ZstdException(
        ZstdErrorCode.invalidSequence,
        'block output exceeds the block maximum size',
      );
    }

    if (literalLength > 0) {
      if (outBuffer != null) {
        final at = output.position;
        if (literalLength <= 3) {
          final source = literalsStart + literalPosition;
          for (var k = 0; k < literalLength; k++) {
            outBuffer[at + k] = literalsBytes[source + k];
          }
        } else {
          outBuffer.setRange(
            at,
            at + literalLength,
            literalsBytes,
            literalsStart + literalPosition,
          );
        }
        output.position = at + literalLength;
        output.blockOut += literalLength;
      } else {
        output.writeLiterals(
          literalsBytes,
          literalsStart + literalPosition,
          literalLength,
        );
      }
      literalPosition += literalLength;
    }
    final available = frameOut + output.blockOut;
    if (outBuffer != null &&
        offset <= available &&
        (available <= windowSize || offset <= windowSize) &&
        offset != 1) {
      final at = output.position;
      final source = at - offset;
      if (offset >= matchLength) {
        if (matchLength <= 7) {
          for (var k = 0; k < matchLength; k++) {
            outBuffer[at + k] = outBuffer[source + k];
          }
        } else {
          outBuffer.setRange(at, at + matchLength, outBuffer, source);
        }
      } else if (matchLength >= 192) {
        var copied = offset < matchLength ? offset : matchLength;
        outBuffer.setRange(at, at + copied, outBuffer, source);
        while (copied < matchLength) {
          var next = copied;
          final remaining = matchLength - copied;
          if (next > remaining) next = remaining;
          outBuffer.setRange(at + copied, at + copied + next, outBuffer, at);
          copied += next;
        }
      } else {
        for (var k = 0; k < matchLength; k++) {
          outBuffer[at + k] = outBuffer[source + k];
        }
      }
      output.position = at + matchLength;
      output.blockOut += matchLength;
    } else {
      output.copyMatch(offset, matchLength);
    }

    if (i != numberOfSequences - 1) {
      final llNb = (llEntry >>> 8) & 0xF;
      final mlNb = (mlEntry >>> 8) & 0xF;
      final ofNb = (ofEntry >>> 8) & 0xF;
      final nbTotal = llNb + mlNb + ofNb;
      if (nbTotal <= 24) {
        final nbValue = nbTotal > 0 ? _readBits(window, nbTotal) : 0;
        llState = (llEntry >>> 12) + (nbValue >>> (ofNb + mlNb));
        mlState = (mlEntry >>> 12) + ((nbValue >>> ofNb) & kBitMasks[mlNb]);
        ofState = (ofEntry >>> 12) + (nbValue & kBitMasks[ofNb]);
      } else {
        llState = (llEntry >>> 12) + _readBits(window, llNb);
        mlState = (mlEntry >>> 12) + _readBits(window, mlNb);
        ofState = (ofEntry >>> 12) + _readBits(window, ofNb);
      }
    }
  }

  window.flush();
  context.repOffsets[0] = rep0;
  context.repOffsets[1] = rep1;
  context.repOffsets[2] = rep2;

  if (bits.bitPosition != 0) {
    throw const ZstdException(
      ZstdErrorCode.invalidSequence,
      'sequence bit stream was not consumed exactly',
    );
  }

  final remaining = literalsLength - literalPosition;
  if (remaining > 0) {
    if (remaining > blockMax - output.blockOut) {
      throw const ZstdException(
        ZstdErrorCode.invalidSequence,
        'block output exceeds the block maximum size',
      );
    }
    output.writeLiterals(
      literalsBytes,
      literalsStart + literalPosition,
      remaining,
    );
  }
}

enum _SeqPart { literalLength, offset, matchLength }

FseTable _readSequenceTable(
  FrameContext context,
  ForwardBitReader reader,
  _SeqPart part,
  int mode,
  FseTable? previous,
) {
  switch (mode) {
    case 0:
      switch (part) {
        case _SeqPart.literalLength:
          return FseTable.llPredefined;
        case _SeqPart.offset:
          return FseTable.offsetPredefined;
        case _SeqPart.matchLength:
          return FseTable.mlPredefined;
      }
    case 1:
      final symbol = reader.readBits(8);
      final maxSymbol = switch (part) {
        _SeqPart.literalLength => kMaxLlCode,
        _SeqPart.offset => kMaxOffsetCode,
        _SeqPart.matchLength => kMaxMlCode,
      };
      if (symbol > maxSymbol) {
        throw const ZstdException(
          ZstdErrorCode.invalidFseTable,
          'RLE sequence symbol out of range',
        );
      }
      return FseTable.rle(symbol);
    case 2:
      switch (part) {
        case _SeqPart.literalLength:
          return FseTable.readFrom(reader, kMaxLlCode, kMaxLlMlAccuracyLog);
        case _SeqPart.offset:
          return FseTable.readFrom(
            reader,
            kMaxOffsetCode,
            kMaxOffsetAccuracyLog,
          );
        case _SeqPart.matchLength:
          return FseTable.readFrom(reader, kMaxMlCode, kMaxLlMlAccuracyLog);
      }
    default:
      if (previous == null) {
        throw const ZstdException(
          ZstdErrorCode.invalidFseTable,
          'repeat mode without a previous sequence table',
        );
      }
      return previous;
  }
}
