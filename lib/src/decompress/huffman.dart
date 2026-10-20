/// Huffman decoding for Zstandard literals.
library;

import 'dart:typed_data';

import '../common/errors.dart';
import 'bit_stream.dart';
import 'fse.dart';

/// Maximum Huffman tree depth allowed by the format specification.
const int kHuffmanMaxBits = 11;

/// Maximum number of Huffman symbols (literal values 0..255).
const int kHuffmanMaxSymbols = 256;

/// A canonical Huffman decoding table.
///
/// The depth is [maxBits]; a [maxBits]-bit prefix indexes [entries], which
/// packs the decoded symbol in the low byte and its code length in the high
/// byte.
final class HuffmanTable {
  HuffmanTable(this.entries, this.maxBits);

  final Uint16List entries;
  final int maxBits;

  /// Decoded symbol for [state].
  int symbolAt(int state) => entries[state] & 0xFF;

  /// Number of bits consumed by the symbol at [state].
  int bitsAt(int state) => entries[state] >> 8;

  /// Parses a Huffman tree description from [reader].
  static HuffmanTable readFrom(ForwardBitReader reader) {
    final header = reader.readBits(8);
    final weights = Uint8List(kHuffmanMaxSymbols);
    var numWeights = 0;

    if (header >= 128) {
      // Direct representation: two 4-bit weights per byte, first in the high
      // nibble. The last present weight is not transmitted.
      numWeights = header - 127;
      final bytes = (numWeights + 1) >> 1;
      if (bytes > reader.remainingBytes) {
        throw const ZstdException(
          ZstdErrorCode.truncatedInput,
          'truncated direct Huffman weights',
        );
      }
      for (var i = 0; i < bytes; i++) {
        final pair = reader.readBits(8);
        final at = i * 2;
        weights[at] = pair >> 4;
        if (at + 1 < numWeights) weights[at + 1] = pair & 0xF;
      }
    } else {
      numWeights = _readFseWeights(reader, header, weights);
    }

    return fromWeights(weights, numWeights);
  }

  /// Decodes the FSE-compressed weight list (a 2-state interleaved stream).
  static int _readFseWeights(
    ForwardBitReader reader,
    int fseSize,
    Uint8List weights,
  ) {
    if (fseSize == 0) {
      throw const ZstdException(
        ZstdErrorCode.invalidHuffmanTree,
        'empty FSE-compressed Huffman weights',
      );
    }
    if (fseSize > reader.remainingBytes) {
      throw const ZstdException(
        ZstdErrorCode.truncatedInput,
        'truncated FSE-compressed Huffman weights',
      );
    }
    final start = reader.position;
    final end = start + fseSize;
    reader.skipBytes(fseSize);

    final sub = ForwardBitReader(reader.data, start, end);
    final table = FseTable.readFrom(sub, 255, 6);
    final tableEnd = start + sub.byteOffset;
    if (sub.byteOffset >= fseSize || tableEnd >= end) {
      throw const ZstdException(
        ZstdErrorCode.truncatedInput,
        'missing FSE-compressed Huffman weight payload',
      );
    }

    final bits = BackwardBitReader(reader.data, tableEnd, end);
    final accuracyLog = table.accuracyLog;
    if (accuracyLog > 0 && bits.bitPosition < 2 * accuracyLog) {
      throw const ZstdException(
        ZstdErrorCode.invalidHuffmanTree,
        'truncated initial Huffman weight states',
      );
    }

    var state1 = bits.readBits(accuracyLog);
    var state2 = bits.readBits(accuracyLog);
    final entries = table.entries;
    final stateBase = table.stateBase;
    var count = 0;
    while (true) {
      if (count >= kHuffmanMaxSymbols - 1) {
        throw const ZstdException(
          ZstdErrorCode.invalidHuffmanTree,
          'too many Huffman weights',
        );
      }
      final entry1 = entries[state1];
      weights[count++] = entry1 & 0xFF;
      state1 = stateBase[state1] + bits.readBits(entry1 >> 8);
      if (bits.bitPosition < 0) {
        if (count >= kHuffmanMaxSymbols - 1) {
          throw const ZstdException(
            ZstdErrorCode.invalidHuffmanTree,
            'too many Huffman weights',
          );
        }
        weights[count++] = entries[state2] & 0xFF;
        break;
      }

      if (count >= kHuffmanMaxSymbols - 1) {
        throw const ZstdException(
          ZstdErrorCode.invalidHuffmanTree,
          'too many Huffman weights',
        );
      }
      final entry2 = entries[state2];
      weights[count++] = entry2 & 0xFF;
      state2 = stateBase[state2] + bits.readBits(entry2 >> 8);
      if (bits.bitPosition < 0) {
        if (count >= kHuffmanMaxSymbols - 1) {
          throw const ZstdException(
            ZstdErrorCode.invalidHuffmanTree,
            'too many Huffman weights',
          );
        }
        weights[count++] = entries[state1] & 0xFF;
        break;
      }
    }

    // The FSE table symbols are 0..255, but weights above 11 are not valid.
    if (count > kHuffmanMaxSymbols - 1) {
      throw const ZstdException(
        ZstdErrorCode.invalidHuffmanTree,
        'too many Huffman weights',
      );
    }
    return count;
  }

  /// Builds the decoding table from [numWeights] transmitted weights.
  ///
  /// The final weight is deduced (the weights must complete a power of two).
  static HuffmanTable fromWeights(Uint8List weights, int numWeights) {
    if (numWeights <= 0 || numWeights >= kHuffmanMaxSymbols) {
      throw const ZstdException(
        ZstdErrorCode.invalidHuffmanTree,
        'invalid Huffman weight count',
      );
    }
    var weightTotal = 0;
    for (var i = 0; i < numWeights; i++) {
      final w = weights[i];
      if (w > kHuffmanMaxBits) {
        throw const ZstdException(
          ZstdErrorCode.invalidHuffmanTree,
          'Huffman weight out of range',
        );
      }
      if (w > 0) weightTotal += kPow2[w - 1];
    }
    if (weightTotal == 0) {
      throw const ZstdException(
        ZstdErrorCode.invalidHuffmanTree,
        'Huffman tree has no symbols',
      );
    }

    final tableLog = highestSetBit(weightTotal) + 1;
    if (tableLog > kHuffmanMaxBits) {
      throw const ZstdException(
        ZstdErrorCode.invalidHuffmanTree,
        'Huffman tree is deeper than the format maximum',
      );
    }
    final tableSize = kPow2[tableLog];
    final rest = tableSize - weightTotal;
    if (rest <= 0 || (rest & (rest - 1)) != 0) {
      throw const ZstdException(
        ZstdErrorCode.invalidHuffmanTree,
        'Huffman weights do not complete a power of two',
      );
    }
    final lastWeight = highestSetBit(rest) + 1;
    final lastBits = tableLog + 1 - lastWeight;
    if (lastBits <= 0) {
      throw const ZstdException(
        ZstdErrorCode.invalidHuffmanTree,
        'invalid implied Huffman weight',
      );
    }

    final numSymbols = numWeights + 1;
    final bits = Uint8List(numSymbols);
    for (var i = 0; i < numWeights; i++) {
      final w = weights[i];
      bits[i] = w > 0 ? tableLog + 1 - w : 0;
    }
    bits[numWeights] = lastBits;

    // Canonical code construction, exactly as described by the specification:
    // symbols sorted by weight (i.e. code length), then natural order.
    final rankCount = Uint16List(tableLog + 1);
    for (var i = 0; i < numSymbols; i++) {
      final b = bits[i];
      if (b > tableLog) {
        throw const ZstdException(
          ZstdErrorCode.invalidHuffmanTree,
          'Huffman code length out of range',
        );
      }
      rankCount[b]++;
    }
    // By construction the longest codes must appear at least twice and in
    // pairs, otherwise the tree cannot fill the state table exactly.
    if (rankCount[tableLog] < 2 || (rankCount[tableLog] & 1) != 0) {
      throw const ZstdException(
        ZstdErrorCode.invalidHuffmanTree,
        'invalid Huffman rank statistics',
      );
    }

    final rankStart = Uint16List(tableLog + 1);
    rankStart[tableLog] = 0;
    for (var i = tableLog; i >= 1; i--) {
      rankStart[i - 1] = rankStart[i] + rankCount[i] * kPow2[tableLog - i];
    }
    if (rankStart[0] != tableSize) {
      throw const ZstdException(
        ZstdErrorCode.invalidHuffmanTree,
        'Huffman code lengths do not fill the table',
      );
    }

    final symbols = Uint8List(tableSize);
    final tableBits = Uint8List(tableSize);
    for (var i = tableLog; i >= 1; i--) {
      final from = rankStart[i];
      final to = rankStart[i - 1];
      if (from > to || to > tableSize) {
        throw const ZstdException(
          ZstdErrorCode.invalidHuffmanTree,
          'corrupt Huffman rank table',
        );
      }
      for (var row = from; row < to; row++) {
        tableBits[row] = i;
      }
    }

    for (var symbol = 0; symbol < numSymbols; symbol++) {
      final b = bits[symbol];
      if (b == 0) continue;
      if (b > tableLog) {
        throw const ZstdException(
          ZstdErrorCode.invalidHuffmanTree,
          'Huffman code length out of range',
        );
      }
      final code = rankStart[b];
      final len = kPow2[tableLog - b];
      if (code + len > tableSize) {
        throw const ZstdException(
          ZstdErrorCode.invalidHuffmanTree,
          'corrupt Huffman code assignment',
        );
      }
      for (var row = code; row < code + len; row++) {
        symbols[row] = symbol;
      }
      rankStart[b] = code + len;
    }

    final entries = Uint16List(tableSize);
    for (var row = 0; row < tableSize; row++) {
      entries[row] = symbols[row] | (tableBits[row] << 8);
    }

    return HuffmanTable(entries, tableLog);
  }

  /// Decodes exactly [length] symbols into `dst[dstStart..]`.
  static void decodeStream(
    BackwardBitReader bits,
    HuffmanTable table,
    Uint8List dst,
    int dstStart,
    int length,
  ) {
    if (length == 0) {
      // An empty stream is only the end marker: one byte holding just the
      // final `1` bit.
      if (bits.end - bits.start != 1 || bits.bitPosition != 0) {
        throw const ZstdException(
          ZstdErrorCode.invalidHuffmanTree,
          'non-empty Huffman stream for an empty literal run',
        );
      }
      return;
    }
    if (bits.bitPosition < table.maxBits) {
      throw const ZstdException(
        ZstdErrorCode.truncatedInput,
        'truncated initial Huffman state',
      );
    }
    final mask = kPow2[table.maxBits] - 1;
    final entries = table.entries;
    var state = bits.readBits(table.maxBits);
    for (var i = 0; i < length; i++) {
      final entry = entries[state];
      final nb = entry >> 8;
      final rest = bits.readBits(nb);
      dst[dstStart + i] = entry & 0xFF;
      state = ((state << nb) + rest) & mask;
    }
    if (bits.bitPosition != -table.maxBits) {
      throw const ZstdException(
        ZstdErrorCode.invalidHuffmanTree,
        'Huffman stream was not consumed exactly',
      );
    }
  }
}
