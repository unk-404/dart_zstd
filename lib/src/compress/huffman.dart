import 'dart:typed_data';

import 'bit_writer.dart';
import 'byte_writer.dart';
import 'fse_encoder.dart';

/// Maximum Huffman code length allowed by the format specification.
const int huffmanMaxBits = 11;

/// A canonical Huffman compression table for literal bytes.
///
/// Codes are stored as the integer value of their `nbBits`-bit big-endian
/// representation; when writing the (backwards) bitstream the low
/// `nbBits` bits are appended least-significant first, which reproduces the
/// on-wire order.
final class HuffmanTable {
  HuffmanTable._({
    required this.maxSymbolValue,
    required this.tableLog,
    required this.bits,
    required this.codes,
    required this.weights,
  });

  /// Highest literal symbol with a non-zero weight.
  final int maxSymbolValue;

  /// Tree depth (`Max_Number_of_Bits`).
  final int tableLog;

  /// Number of bits per literal symbol (0 = absent), 256 entries.
  final Uint8List bits;

  /// Code value per literal symbol (only meaningful when `bits[s] > 0`).
  final Uint16List codes;

  /// Weight per literal symbol (0 = absent), 256 entries.
  final Uint8List weights;

  /// Whether this table can encode every non-zero entry of [counts].
  bool canEncode(Uint32List counts) {
    for (var s = 0; s < 256; s++) {
      if (counts[s] != 0 && bits[s] == 0) return false;
    }
    return true;
  }

  /// Estimated encoded size in bits for [counts].
  int estimateBits(Uint32List counts) {
    var total = 0;
    for (var s = 0; s < 256; s++) {
      if (counts[s] != 0) total += counts[s] * bits[s];
    }
    return total;
  }
}

/// Builds a length-limited Huffman table from a literal [counts] histogram.
///
/// Returns `null` when fewer than two symbols are present (the caller should
/// emit RLE literals instead) or when no valid table could be produced.
HuffmanTable? buildHuffmanTable(Uint32List counts) {
  final symbols = <int>[];
  for (var s = 0; s < 256; s++) {
    if (counts[s] != 0) symbols.add(s);
  }
  if (symbols.length < 2) return null;
  if (symbols.length > (1 << huffmanMaxBits)) return null;

  final freqs = [for (final s in symbols) counts[s]];
  final lengths = _packageMergeLengths(symbols, freqs, huffmanMaxBits);
  if (lengths == null) return null;

  var maxLen = 0;
  for (final s in symbols) {
    final len = lengths[s];
    if (len < 1 || len > huffmanMaxBits) return null;
    if (len > maxLen) maxLen = len;
  }
  if (maxLen == 0) return null;

  // Kraft equality check: the weights must describe a complete tree.
  var kraft = 0;
  for (final s in symbols) {
    kraft += 1 << (maxLen - lengths[s]);
  }
  if (kraft != (1 << maxLen)) return null;

  final bits = Uint8List(256);
  final codes = Uint16List(256);
  final weights = Uint8List(256);
  var maxSymbol = 0;
  final nbPerRank = List<int>.filled(maxLen + 2, 0);
  for (final s in symbols) {
    bits[s] = lengths[s];
    nbPerRank[lengths[s]]++;
    if (s > maxSymbol) maxSymbol = s;
  }
  final valPerRank = List<int>.filled(maxLen + 2, 0);
  var min = 0;
  for (var n = maxLen; n > 0; n--) {
    valPerRank[n] = min;
    min += nbPerRank[n];
    min >>= 1;
  }
  for (var s = 0; s <= maxSymbol; s++) {
    final len = bits[s];
    if (len == 0) continue;
    codes[s] = valPerRank[len]++;
    weights[s] = maxLen + 1 - len;
  }
  return HuffmanTable._(
    maxSymbolValue: maxSymbol,
    tableLog: maxLen,
    bits: bits,
    codes: codes,
    weights: weights,
  );
}

/// Encodes the Huffman tree description for [table].
///
/// Returns `null` when the table cannot be described (full alphabet with a
/// weight series that does not compress); the caller then falls back to raw
/// literals.
Uint8List? writeHuffmanTreeDescription(HuffmanTable table) {
  final maxSymbol = table.maxSymbolValue;
  if (maxSymbol == 0) return null;
  final weightCount = maxSymbol;
  final weightSeries = Uint8List(weightCount);
  for (var s = 0; s < weightCount; s++) {
    weightSeries[s] = table.weights[s];
  }

  final fseCompressed = _compressWeights(weightSeries, weightCount);
  if (fseCompressed != null &&
      fseCompressed.length > 1 &&
      fseCompressed.length < (maxSymbol >> 1)) {
    final out = Uint8List(1 + fseCompressed.length);
    out[0] = fseCompressed.length;
    out.setRange(1, out.length, fseCompressed);
    return out;
  }

  // Direct 4-bit representation works for alphabets up to 129 symbols.
  if (maxSymbol > 128) return null;
  final out = Uint8List(1 + ((weightCount + 1) >> 1));
  out[0] = 127 + maxSymbol;
  for (var i = 0; i < weightCount; i += 2) {
    final w0 = weightSeries[i];
    final w1 = i + 1 < weightCount ? weightSeries[i + 1] : 0;
    out[1 + (i >> 1)] = (w0 << 4) | w1;
  }
  return out;
}

/// Encodes [count] literals from `src[start..end)` with [table].
///
/// [fourStreams] selects the 4-stream layout (mandatory above 1 KiB of
/// literals); the 6-byte jump table is filled in afterwards.
Uint8List encodeHuffmanLiterals(
  Uint8List src,
  int start,
  int end,
  HuffmanTable table, {
  required bool fourStreams,
}) {
  final output = ByteWriter((end - start) + 32);
  if (!fourStreams) {
    _encodeSingleStream(output, src, start, end, table);
    return output.takeBytes();
  }
  output.writeUint16(0);
  output.writeUint16(0);
  output.writeUint16(0);
  final sizes = List<int>.filled(3, 0);
  final segmentSize = (end - start + 3) >> 2;
  var offset = start;
  for (var i = 0; i < 4; i++) {
    final segmentEnd = i == 3 ? end : offset + segmentSize;
    final before = output.length;
    _encodeSingleStream(output, src, offset, segmentEnd, table);
    final written = output.length - before;
    if (i < 3) sizes[i] = written;
    offset = segmentEnd;
  }
  for (var i = 0; i < 3; i++) {
    if (sizes[i] > 0xFFFF) {
      throw StateError('Huffman stream too large');
    }
    output.patchUint16(i * 2, sizes[i]);
  }
  return output.takeBytes();
}

void _encodeSingleStream(
  ByteWriter output,
  Uint8List src,
  int start,
  int end,
  HuffmanTable table,
) {
  final bitWriter = BitWriter(output);
  for (var i = end - 1; i >= start; i--) {
    final symbol = src[i];
    final nbBits = table.bits[symbol];
    if (nbBits == 0) {
      throw StateError('Huffman table cannot encode symbol $symbol');
    }
    bitWriter.addBits(table.codes[symbol], nbBits);
  }
  bitWriter.finish();
}

Uint8List? _compressWeights(Uint8List weights, int count) {
  if (count <= 1) return null;
  var maxWeight = 0;
  for (var i = 0; i < count; i++) {
    if (weights[i] > maxWeight) maxWeight = weights[i];
  }
  final counts = Int32List(maxWeight + 1);
  var maxCount = 0;
  for (var i = 0; i < count; i++) {
    final c = ++counts[weights[i]];
    if (c > maxCount) maxCount = c;
  }
  if (maxCount == count || maxCount == 1) return null;
  try {
    final tableLog = fseOptimalTableLog(6, count, maxWeight, 1);
    final normalized = fseNormalizeCounts(
      count: counts,
      maxSymbolValue: maxWeight,
      total: count,
      tableLog: tableLog,
    );
    final output = ByteWriter(64);
    writeFseNCount(output, normalized, maxWeight, tableLog);
    final table = FseCTable.fromNormalized(normalized, maxWeight, tableLog);
    final bitWriter = BitWriter(output);
    encodeFseStreamTwoStates(bitWriter, table, weights);
    return output.takeBytes();
  } on ArgumentError {
    return null;
  } on StateError {
    return null;
  }
}

// --- Package-merge length-limited Huffman code construction -----------------

final class _PmItem {
  _PmItem(this.weight, this.members);

  final int weight;
  final List<int> members;
}

List<int>? _packageMergeLengths(
  List<int> symbols,
  List<int> frequencies,
  int maxBits,
) {
  final n = symbols.length;
  final coins = <_PmItem>[];
  for (var i = 0; i < n; i++) {
    coins.add(_PmItem(frequencies[i], <int>[symbols[i]]));
  }
  coins.sort((a, b) {
    final byWeight = a.weight.compareTo(b.weight);
    if (byWeight != 0) return byWeight;
    return a.members.first.compareTo(b.members.first);
  });
  if (n == 1) return null;

  var pool = List<_PmItem>.of(coins);
  final needed = 2 * n - 2;
  for (var level = 1; level < maxBits; level++) {
    final packages = <_PmItem>[];
    for (var i = 0; i + 1 < pool.length; i += 2) {
      final a = pool[i];
      final b = pool[i + 1];
      packages.add(
        _PmItem(a.weight + b.weight, <int>[...a.members, ...b.members]),
      );
    }
    final merged = <_PmItem>[];
    var coinIndex = 0;
    var packageIndex = 0;
    while (coinIndex < coins.length || packageIndex < packages.length) {
      final takeCoin =
          packageIndex >= packages.length ||
          (coinIndex < coins.length &&
              coins[coinIndex].weight <= packages[packageIndex].weight);
      if (takeCoin) {
        merged.add(coins[coinIndex++]);
      } else {
        merged.add(packages[packageIndex++]);
      }
    }
    pool = merged;
  }
  if (pool.length < needed) return null;

  final lengths = List<int>.filled(256, 0);
  for (var i = 0; i < needed; i++) {
    for (final symbol in pool[i].members) {
      lengths[symbol]++;
    }
  }
  return lengths;
}
