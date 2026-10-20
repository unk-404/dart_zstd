import 'dart:typed_data';

import 'byte_writer.dart';
import 'frame.dart';
import 'match_finder.dart';
import 'sequences.dart';

/// Compresses complete blocks of one frame.
///
/// The instance keeps the match-finder hash tables and the repeat-offset
/// history alive across blocks, which is required for good ratios and for
/// format correctness respectively.
final class BlockEncoder {
  BlockEncoder(this.parameters)
    : _matcher = MatchFinder(parameters),
      _sequences = SequenceStore(parameters.blockSize ~/ 4 + 4),
      _writer = SequenceWriter();

  final CompressionParameters parameters;
  final MatchFinder _matcher;
  final SequenceStore _sequences;
  final SequenceWriter _writer;

  /// Writes `data[start..end)` as one block (header included) to [output].
  ///
  /// [streamBase] is the stream offset of `data[0]`; it is used only to keep
  /// match-table entries stable when the caller slides its buffer.
  void writeBlock(
    ByteWriter output,
    Uint8List data,
    int start,
    int end,
    int streamBase, {
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
    _sequences.clear();
    _matcher.findMatches(data, start, end, streamBase, repSnapshot, _sequences);

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
    _writeLiteralsSection(output, data, start, end);
    _writer.write(output, _sequences);
    final compressedSize = output.length - contentStart;
    if (compressedSize >= blockLength) {
      // Not worth it: emit the plain block instead.
      output.truncate(contentStart);
      _writer.restoreRepCodes(repSnapshot);
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

  void _writeLiteralsSection(
    ByteWriter output,
    Uint8List data,
    int start,
    int end,
  ) {
    final litLengths = _sequences.litLengths;
    final matchLengths = _sequences.matchLengths;
    final count = _sequences.count;

    var litTotal = end - start;
    for (var i = 0; i < count; i++) {
      litTotal -= matchLengths[i];
    }

    // RLE literals only help when at least two literals share a value.
    int? firstLiteral;
    var uniform = litTotal > 1;
    var pos = start;
    if (uniform) {
      for (var i = 0; i < count; i++) {
        final litLength = litLengths[i];
        for (var j = 0; j < litLength; j++) {
          final byte = data[pos + j];
          if (firstLiteral == null) {
            firstLiteral = byte;
          } else if (byte != firstLiteral) {
            uniform = false;
            break;
          }
        }
        if (!uniform) break;
        pos += litLength + matchLengths[i];
      }
      if (uniform) {
        for (var i = pos; i < end; i++) {
          final byte = data[i];
          if (byte != firstLiteral) {
            uniform = false;
            break;
          }
        }
      }
    }

    if (uniform) {
      _writeLiteralsHeader(output, type: 1, size: litTotal);
      output.writeByte(firstLiteral!);
      return;
    }

    _writeLiteralsHeader(output, type: 0, size: litTotal);
    pos = start;
    for (var i = 0; i < count; i++) {
      final litLength = litLengths[i];
      output.writeBytes(data, pos, pos + litLength);
      pos += litLength + matchLengths[i];
    }
    output.writeBytes(data, pos, end);
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
}
