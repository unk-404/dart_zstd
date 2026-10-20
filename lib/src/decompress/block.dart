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

/// Destination for the literals and matches of one compressed block.
abstract interface class BlockOutput {
  /// Bytes produced by the block decoded so far.
  int get blockOut;

  void writeLiterals(Uint8List src, int srcStart, int length);

  void copyMatch(int offset, int length);
}

/// Block output writing into one contiguous (one-shot) frame buffer.
final class ContiguousBlockOutput implements BlockOutput {
  ContiguousBlockOutput(this.context, this.buffer, this.position);

  final FrameContext context;
  final Uint8List buffer;
  int position;
  int _blockOut = 0;

  @override
  int get blockOut => _blockOut;

  @override
  void writeLiterals(Uint8List src, int srcStart, int length) {
    buffer.setRange(position, position + length, src, srcStart);
    position += length;
    _blockOut += length;
  }

  @override
  void copyMatch(int offset, int length) {
    final available = context.frameOut + _blockOut;
    final dictionary = context.dictionaryContent;
    if (available <= context.windowSize) {
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
        _blockOut += dictionaryCopy;
        length -= dictionaryCopy;
      }
    } else if (offset > context.windowSize) {
      throw const ZstdException(
        ZstdErrorCode.invalidSequence,
        'match offset exceeds the frame window',
      );
    }

    if (length > 0) {
      final source = position - offset;
      if (source < 0) {
        throw const ZstdException(
          ZstdErrorCode.invalidSequence,
          'match offset reaches before the frame start',
        );
      }
      if (offset >= length) {
        buffer.setRange(position, position + length, buffer, source);
      } else if (length >= 192) {
        // Overlapping copy. First copy the pattern (at most `offset` bytes),
        // then repeatedly double it. Every setRange source range ends at or
        // before its destination range starts, so no copy overlaps itself.
        var copied = offset < length ? offset : length;
        buffer.setRange(position, position + copied, buffer, source);
        while (copied < length) {
          var next = copied;
          final remaining = length - copied;
          if (next > remaining) next = remaining;
          buffer.setRange(
            position + copied,
            position + copied + next,
            buffer,
            position,
          );
          copied += next;
        }
      } else {
        for (var i = 0; i < length; i++) {
          buffer[position + i] = buffer[source + i];
        }
      }
      position += length;
      _blockOut += length;
    }
  }
}

/// Block output writing into the streaming ring buffer.
final class RingBlockOutput implements BlockOutput {
  RingBlockOutput(this.context, this.ring);

  final FrameContext context;
  final RingWindow ring;
  int _blockOut = 0;

  @override
  int get blockOut => _blockOut;

  @override
  void writeLiterals(Uint8List src, int srcStart, int length) {
    ring.writeRaw(src, srcStart, length);
    _blockOut += length;
  }

  @override
  void copyMatch(int offset, int length) {
    final available = context.frameOut + _blockOut;
    final dictionary = context.dictionaryContent;
    if (available <= context.windowSize) {
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
        _blockOut += dictionaryCopy;
        length -= dictionaryCopy;
      }
    } else if (offset > context.windowSize) {
      throw const ZstdException(
        ZstdErrorCode.invalidSequence,
        'match offset exceeds the frame window',
      );
    }

    if (length > 0) {
      ring.copyMatch(offset, length);
      _blockOut += length;
    }
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

  var llState = bits.readBits(llTable.accuracyLog);
  var ofState = bits.readBits(ofTable.accuracyLog);
  var mlState = bits.readBits(mlTable.accuracyLog);

  var literalPosition = 0;
  final literalsBytes = literals.bytes;
  final literalsStart = literals.start;
  final literalsLength = literals.length;
  final repetitions = context.repOffsets;
  final llEntries = llTable.entries;
  final llBase = llTable.stateBase;
  final ofEntries = ofTable.entries;
  final ofBase = ofTable.stateBase;
  final mlEntries = mlTable.entries;
  final mlBase = mlTable.stateBase;

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
    final offsetValue =
        kPow2[ofCode] + (ofExtraBits > 0 ? bits.readBits(ofExtraBits) : 0);

    final mlExtraBits = kMatchLengthExtra[mlCode];
    final matchLength =
        kMatchLengthBase[mlCode] +
        (mlExtraBits > 0 ? bits.readBits(mlExtraBits) : 0);

    final llExtraBits = kLiteralsLengthExtra[llCode];
    final literalLength =
        kLiteralsLengthBase[llCode] +
        (llExtraBits > 0 ? bits.readBits(llExtraBits) : 0);

    final offset = _resolveOffset(offsetValue, literalLength, repetitions);

    if (literalLength > literalsLength - literalPosition) {
      throw const ZstdException(
        ZstdErrorCode.invalidSequence,
        'sequence consumes more literals than available',
      );
    }
    if (literalLength + matchLength > context.blockMax - output.blockOut) {
      throw const ZstdException(
        ZstdErrorCode.invalidSequence,
        'block output exceeds the block maximum size',
      );
    }

    if (literalLength > 0) {
      output.writeLiterals(
        literalsBytes,
        literalsStart + literalPosition,
        literalLength,
      );
      literalPosition += literalLength;
    }
    output.copyMatch(offset, matchLength);

    if (i != numberOfSequences - 1) {
      llState = llBase[llState] + bits.readBits(llEntry >> 8);
      mlState = mlBase[mlState] + bits.readBits(mlEntry >> 8);
      ofState = ofBase[ofState] + bits.readBits(ofEntry >> 8);
    }
  }

  if (bits.bitPosition != 0) {
    throw const ZstdException(
      ZstdErrorCode.invalidSequence,
      'sequence bit stream was not consumed exactly',
    );
  }

  final remaining = literalsLength - literalPosition;
  if (remaining > 0) {
    if (remaining > context.blockMax - output.blockOut) {
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

int _resolveOffset(int offsetValue, int literalLength, List<int> repetitions) {
  int offset;
  if (offsetValue > 3) {
    offset = offsetValue - 3;
    repetitions[2] = repetitions[1];
    repetitions[1] = repetitions[0];
    repetitions[0] = offset;
  } else {
    var index = offsetValue - 1;
    if (literalLength == 0) index++;
    if (index == 0) {
      offset = repetitions[0];
    } else {
      offset = index == 3 ? repetitions[0] - 1 : repetitions[index];
      if (index > 1) repetitions[2] = repetitions[1];
      repetitions[1] = repetitions[0];
      repetitions[0] = offset;
    }
  }
  if (offset <= 0) {
    throw const ZstdException(
      ZstdErrorCode.invalidSequence,
      'repeat offset resolved to a non-positive distance',
    );
  }
  return offset;
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
