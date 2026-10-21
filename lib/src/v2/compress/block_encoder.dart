import 'dart:typed_data';

import 'bit_writer.dart';
import 'byte_writer.dart';
import 'frame.dart';
import 'huffman.dart';
import 'match_finder.dart';
import 'sequences.dart';

/// Compresses complete blocks of one frame.
///
/// The instance keeps the match-finder tables, the repeat-offset history, the
/// previously used FSE tables and the previous Huffman table alive across
/// blocks, which is required for good ratios and for format correctness.
final class BlockEncoder {
  BlockEncoder(this.parameters, {List<int>? initialRepCodes})
    : _matcher = MatchFinder(parameters),
      _sequences = SequenceStore(parameters.blockSize ~/ 4 + 4),
      _writer = SequenceWriter(initialRepCodes: initialRepCodes),
      _literals = Uint8List(parameters.blockSize),
      _literalCounts = Uint32List(256),
      _literalsBody = ByteWriter(parameters.blockSize + 512),
      _huffmanBits = BitWriter(parameters.blockSize + 16);

  final CompressionParameters parameters;
  final MatchFinder _matcher;
  final SequenceStore _sequences;
  final SequenceWriter _writer;

  final Uint8List _literals;
  final Uint32List _literalCounts;
  final ByteWriter _literalsBody;
  final BitWriter _huffmanBits;
  final HuffmanScratch _huffmanScratch = HuffmanScratch();

  HuffmanTable? _previousHuffman;

  /// Indexes dictionary content as history before the first block is emitted.
  void loadPrefix(Uint8List data, int start, int end) {
    _matcher.loadPrefix(data, start, end);
  }

  /// Writes `data[start..end)` as one block (header included) to [output].
  void writeBlock(
    ByteWriter output,
    Uint8List data,
    int start,
    int end, {
    required bool last,
  }) {
    final headerOffset = output.length;
    output.writeUint24(0); // reserved header, patched below
    final blockLength = end - start;

    if (blockLength == 0) {
      patchBlockHeader(
        output,
        headerOffset,
        type: zstdBlockTypeRaw,
        size: 0,
        last: last,
      );
      return;
    }

    if (blockLength > 1 && _isUniform(data, start, end)) {
      patchBlockHeader(
        output,
        headerOffset,
        type: zstdBlockTypeRle,
        size: blockLength,
        last: last,
      );
      output.writeByte(data[start]);
      return;
    }

    final repSnapshot = _writer.snapshotRepCodes();
    final tableSnapshot = _writer.snapshotTables();
    final huffmanSnapshot = _previousHuffman;
    _sequences.clear();
    _matcher.findMatches(data, start, end, repSnapshot, _sequences);

    if (_sequences.count == 0) {
      patchBlockHeader(
        output,
        headerOffset,
        type: zstdBlockTypeRaw,
        size: blockLength,
        last: last,
      );
      output.writeBytes(data, start, end);
      return;
    }

    final contentStart = output.length;
    final literalCount = _gatherLiterals(data, start, end);
    _writeLiteralsSection(output, literalCount);
    _writer.write(output, _sequences);
    final compressedSize = output.length - contentStart;
    if (compressedSize >= blockLength) {
      // Not worth it: emit the plain block instead.
      output.truncate(contentStart);
      _writer.restoreRepCodes(repSnapshot);
      _writer.restoreTables(tableSnapshot);
      _previousHuffman = huffmanSnapshot;
      patchBlockHeader(
        output,
        headerOffset,
        type: zstdBlockTypeRaw,
        size: blockLength,
        last: last,
      );
      output.writeBytes(data, start, end);
      return;
    }

    patchBlockHeader(
      output,
      headerOffset,
      type: zstdBlockTypeCompressed,
      size: compressedSize,
      last: last,
    );
  }

  static bool _isUniform(Uint8List data, int start, int end) {
    final first = data[start];
    for (var i = start + 1; i < end; i++) {
      if (data[i] != first) return false;
    }
    return true;
  }

  /// Copies the block's literals into [_literals] and fills [_literalCounts].
  int _gatherLiterals(Uint8List data, int start, int end) {
    _literalCounts.fillRange(0, 256, 0);
    final litLengths = _sequences.litLengths;
    final matchLengths = _sequences.matchLengths;
    final count = _sequences.count;
    var source = start;
    var output = 0;
    for (var i = 0; i < count; i++) {
      final litLength = litLengths[i];
      for (var j = 0; j < litLength; j++) {
        final byte = data[source + j];
        _literals[output++] = byte;
        _literalCounts[byte]++;
      }
      source += litLength + matchLengths[i];
    }
    while (source < end) {
      final byte = data[source++];
      _literals[output++] = byte;
      _literalCounts[byte]++;
    }
    return output;
  }

  void _writeLiteralsSection(ByteWriter output, int literalCount) {
    if (literalCount == 0) {
      _writeRawLiteralsHeader(output, 0);
      return;
    }

    // RLE literals: all literal bytes are identical.
    var uniform = literalCount > 1;
    var firstLiteral = _literals[0];
    if (uniform) {
      for (var i = 1; i < literalCount; i++) {
        if (_literals[i] != firstLiteral) {
          uniform = false;
          break;
        }
      }
    }
    final rawSectionSize = _rawLiteralsSectionSize(literalCount);
    if (uniform) {
      _writeRleLiteralsHeader(output, literalCount);
      output.writeByte(firstLiteral);
      return;
    }

    final table = buildHuffmanTable(_literalCounts, scratch: _huffmanScratch);
    final treeDescription = table == null
        ? null
        : writeHuffmanTreeDescription(table);
    if (table == null || treeDescription == null) {
      _writeRawLiterals(output, literalCount);
      return;
    }

    final bits = table.estimateBits(_literalCounts);
    var fourStreams = literalCount > 1023 || bits + 8 > 1023 * 8;
    var chosenTable = table;
    var chosenTree = treeDescription;
    var treeless = false;

    final previous = _previousHuffman;
    if (previous != null && previous.canEncode(_literalCounts)) {
      final streams = fourStreams ? 4 : 1;
      final jump = fourStreams ? 6 : 0;
      final repeatBits = previous.estimateBits(_literalCounts);
      final repeatCost = ((repeatBits + 7) >> 3) + streams + jump;
      final newCost =
          ((bits + 7) >> 3) + streams + jump + treeDescription.length;
      if (repeatCost < newCost) {
        chosenTable = previous;
        treeless = true;
        chosenTree = Uint8List(0);
      }
    }

    // Recompute the stream count for the selected table if necessary.
    final chosenBits = chosenTable.estimateBits(_literalCounts);
    fourStreams = literalCount > 1023 || chosenBits + 8 > 1023 * 8;

    final body = _literalsBody;
    body.clear();
    if (!treeless) body.writeBytes(chosenTree);
    final streams = encodeHuffmanLiterals(
      _literals,
      0,
      literalCount,
      chosenTable,
      fourStreams: fourStreams,
      scratch: _huffmanBits,
    );
    body.writeBytes(streams);

    final compressedSize = body.length;
    final headerSize = fourStreams
        ? _fourStreamHeaderSize(literalCount, compressedSize)
        : 3;
    if (headerSize + compressedSize >= rawSectionSize) {
      _writeRawLiterals(output, literalCount);
      return;
    }
    _writeCompressedLiteralsHeader(
      output,
      type: treeless ? 3 : 2,
      regeneratedSize: literalCount,
      compressedSize: compressedSize,
      fourStreams: fourStreams,
    );
    output.writeBytes(body.takeBytes());
    _previousHuffman = chosenTable;
  }

  static int _rawLiteralsSectionSize(int size) =>
      _rawLiteralsHeaderSize(size) + size;

  static int _rawLiteralsHeaderSize(int size) {
    if (size < 32) return 1;
    if (size < 4096) return 2;
    return 3;
  }

  void _writeRawLiterals(ByteWriter output, int literalCount) {
    _writeRawLiteralsHeader(output, literalCount);
    output.writeBytes(_literals, 0, literalCount);
  }

  static void _writeRawLiteralsHeader(ByteWriter output, int size) {
    _writeLiteralsHeader(output, type: 0, size: size);
  }

  static void _writeRleLiteralsHeader(ByteWriter output, int size) {
    _writeLiteralsHeader(output, type: 1, size: size);
  }

  static void _writeLiteralsHeader(
    ByteWriter output, {
    required int type,
    required int size,
  }) {
    if (size < 32) {
      output.writeByte((size << 3) | type);
    } else if (size < 4096) {
      output.writeByte(((size & 0xF) << 4) | 0x04 | type);
      output.writeByte(size >> 4);
    } else {
      output.writeByte(((size & 0xF) << 4) | 0x0C | type);
      output.writeByte((size >> 4) & 0xFF);
      output.writeByte(size >> 12);
    }
  }

  static void _writeCompressedLiteralsHeader(
    ByteWriter output, {
    required int type,
    required int regeneratedSize,
    required int compressedSize,
    required bool fourStreams,
  }) {
    if (!fourStreams) {
      // Single stream, size format 00: 10 bits for each size.
      final value = type + (regeneratedSize << 4) + (compressedSize << 14);
      output.writeByte(value & 0xFF);
      output.writeByte((value >> 8) & 0xFF);
      output.writeByte((value >> 16) & 0xFF);
      return;
    }
    final format = _fourStreamHeaderSize(regeneratedSize, compressedSize);
    final sizeBits = format == 3 ? 18 : (format == 2 ? 14 : 10);
    // Use multiplication and repeated division so the bit field stays exact on
    // 32-bit JavaScript integers (a 36-bit field must not use `<<` / `>>`).
    final value =
        type +
        format * 4 +
        regeneratedSize * 16 +
        compressedSize * (1 << (4 + sizeBits));
    var remaining = value;
    final bytes = format + 2; // 3, 4 or 5 bytes
    for (var i = 0; i < bytes; i++) {
      output.writeByte(remaining & 0xFF);
      remaining = remaining ~/ 256;
    }
  }

  /// Returns the size format (1, 2 or 3) for a 4-stream literals section.
  static int _fourStreamHeaderSize(int regeneratedSize, int compressedSize) {
    if (regeneratedSize <= 1023 && compressedSize <= 1023) return 1;
    if (regeneratedSize <= 16383 && compressedSize <= 16383) return 2;
    return 3;
  }
}
