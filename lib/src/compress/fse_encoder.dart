import 'dart:typed_data';

import 'bit_writer.dart';
import 'byte_writer.dart';

/// An FSE compression table, ported from the reference `FSE_buildCTable_wksp`.
///
/// Encoding and decoding run in opposite directions: the encoder consumes the
/// symbols in reverse order and the decoder reads them forwards. A "state"
/// here is the reference implementation's `CState.value`, always in
/// `[tableSize, 2 * tableSize)`. Its low `tableLog` bits are what actually gets
/// written to the bitstream.
final class FseCTable {
  FseCTable._(
    this.tableLog,
    this.maxSymbolValue,
    this._stateTable,
    this._deltaNbBits,
    this._deltaFindState,
  );

  /// Creates the trivial "table" used by `RLE_Mode` (no bits are emitted).
  factory FseCTable.rle(int symbol) =>
      FseCTable._(0, symbol, Uint16List(0), Uint32List(0), Int32List(0));

  /// Accuracy log of the table (`Table_Size == 1 << tableLog`).
  final int tableLog;

  /// Highest symbol representable by this table.
  final int maxSymbolValue;

  final Uint16List _stateTable;
  final Uint32List _deltaNbBits;
  final Int32List _deltaFindState;

  int get tableSize => 1 << tableLog;

  /// Builds a compression table from a normalized distribution.
  ///
  /// [normalized] holds one count per symbol, in natural symbol order. A count
  /// of `-1` is the special "less than one" probability, which occupies a
  /// single state at the end of the table and is spread last.
  factory FseCTable.fromNormalized(
    List<int> normalized,
    int maxSymbolValue,
    int tableLog,
  ) {
    if (tableLog < 5 || tableLog > 15) {
      throw ArgumentError.value(tableLog, 'tableLog', 'must be in 5..15');
    }
    if (normalized.length < maxSymbolValue + 1) {
      throw ArgumentError.value(
        normalized.length,
        'normalized',
        'must hold maxSymbolValue + 1 entries',
      );
    }
    final tableSize = 1 << tableLog;
    final tableMask = tableSize - 1;
    final maxSV1 = maxSymbolValue + 1;
    // Same "jump" as the reference FSE_TABLESTEP macro and the spec:
    // position += tableSize/2 + tableSize/8 + 3 (mod tableSize).
    final step = (tableSize >> 1) + (tableSize >> 3) + 3;

    final cumul = Uint16List(maxSV1 + 1);
    final tableSymbol = Uint8List(tableSize);
    var highThreshold = tableSize - 1;

    // Symbol start positions; "less than one" symbols are placed at the end.
    for (var u = 1; u <= maxSV1; u++) {
      final count = normalized[u - 1];
      if (count == -1) {
        cumul[u] = cumul[u - 1] + 1;
        tableSymbol[highThreshold--] = u - 1;
      } else {
        if (count < 0) {
          throw ArgumentError.value(count, 'normalized', 'invalid count');
        }
        cumul[u] = cumul[u - 1] + count;
      }
    }
    if (cumul[maxSV1] != tableSize) {
      throw ArgumentError.value(
        cumul[maxSV1],
        'normalized',
        'probabilities must sum to 1 << tableLog',
      );
    }

    // Spread symbols across the table.
    var position = 0;
    for (var symbol = 0; symbol <= maxSymbolValue; symbol++) {
      final count = normalized[symbol];
      for (var occurrence = 0; occurrence < count; occurrence++) {
        tableSymbol[position] = symbol;
        position = (position + step) & tableMask;
        while (position > highThreshold) {
          // Skip the low-probability area.
          position = (position + step) & tableMask;
        }
      }
    }
    if (position != 0) {
      throw StateError('FSE table spread did not fill the table');
    }

    // For every state, remember the "next state" for its symbol.
    final stateTable = Uint16List(tableSize);
    for (var state = 0; state < tableSize; state++) {
      final symbol = tableSymbol[state];
      stateTable[cumul[symbol]++] = tableSize + state;
    }

    // Symbol transformation table.
    final deltaNbBits = Uint32List(maxSV1);
    final deltaFindState = Int32List(maxSV1);
    var total = 0;
    for (var symbol = 0; symbol <= maxSymbolValue; symbol++) {
      final count = normalized[symbol];
      if (count == 0) {
        // Only used by cost estimation; never encoded.
        deltaNbBits[symbol] = ((tableLog + 1) << 16) - tableSize;
      } else if (count == -1 || count == 1) {
        deltaNbBits[symbol] = (tableLog << 16) - tableSize;
        deltaFindState[symbol] = total - 1;
        total += 1;
      } else {
        final maxBitsOut = tableLog - _highBit32(count - 1);
        final minStatePlus = count << maxBitsOut;
        deltaNbBits[symbol] = (maxBitsOut << 16) - minStatePlus;
        deltaFindState[symbol] = total - count;
        total += count;
      }
    }

    return FseCTable._(
      tableLog,
      maxSymbolValue,
      stateTable,
      deltaNbBits,
      deltaFindState,
    );
  }

  /// Initial state for [symbol] using the smallest possible state value.
  ///
  /// Used for the symbol that will be decoded last: no state-transition bits
  /// have to be emitted for it, only the final state at flush time.
  int initStateForSymbol(int symbol) {
    if (tableLog == 0) return 0;
    if (symbol > maxSymbolValue) {
      throw ArgumentError.value(symbol, 'symbol', 'outside table');
    }
    final deltaNbBits = _deltaNbBits[symbol];
    final bitsOut = (deltaNbBits + (1 << 15)) >> 16;
    var value = (bitsOut << 16) - deltaNbBits;
    value = _stateTable[(value >> bitsOut) + _deltaFindState[symbol]];
    return value;
  }

  /// Encodes [symbol] and returns the next state.
  int encodeSymbol(BitWriter bitWriter, int state, int symbol) {
    if (tableLog == 0) return 0;
    if (symbol > maxSymbolValue) {
      throw ArgumentError.value(symbol, 'symbol', 'outside table');
    }
    final deltaNbBits = _deltaNbBits[symbol];
    final bitsOut = (state + deltaNbBits) >> 16;
    bitWriter.addBits(state, bitsOut);
    return _stateTable[(state >> bitsOut) + _deltaFindState[symbol]];
  }

  /// Writes the final state (`Accuracy_Log` bits).
  void flushState(BitWriter bitWriter, int state) {
    if (tableLog == 0) return;
    bitWriter.addBits(state, tableLog);
  }
}

/// Computes the FSE table log for a source of [srcSize] symbols with values up
/// to [maxSymbolValue]; a port of `FSE_optimalTableLog_internal`.
int fseOptimalTableLog(
  int maxTableLog,
  int srcSize,
  int maxSymbolValue,
  int minus,
) {
  if (srcSize <= 1) return 5;
  var maxBitsSrc = _highBit32(srcSize - 1) - minus;
  if (maxBitsSrc < 0) maxBitsSrc = 0;
  var tableLog = maxTableLog;
  final minBitsSrc = _highBit32(srcSize) + 1;
  final minBitsSymbols = _highBit32(maxSymbolValue) + 2;
  final minBits = minBitsSrc < minBitsSymbols ? minBitsSrc : minBitsSymbols;
  if (maxBitsSrc < tableLog) tableLog = maxBitsSrc;
  if (minBits > tableLog) tableLog = minBits;
  if (tableLog < 5) tableLog = 5;
  if (tableLog > maxTableLog) tableLog = maxTableLog;
  return tableLog;
}

/// Normalizes symbol [count]s to `1 << tableLog`, keeping at least one state
/// for every present symbol. Returns one normalized count per symbol.
///
/// Sums are distributed proportionally, and leftover states go to the symbols
/// with the largest fractional remainder. The result always sums to exactly
/// `1 << tableLog`, which is what the format requires.
List<int> fseNormalizeCounts({
  required Int32List count,
  required int maxSymbolValue,
  required int total,
  required int tableLog,
}) {
  if (total <= 0) {
    throw ArgumentError.value(total, 'total', 'must be positive');
  }
  final tableSize = 1 << tableLog;
  final normalized = List<int>.filled(maxSymbolValue + 1, 0);
  var present = 0;
  for (var s = 0; s <= maxSymbolValue; s++) {
    if (count[s] > 0) present++;
  }
  if (present < 2) {
    throw ArgumentError.value(present, 'present', 'need at least two symbols');
  }
  if (present > tableSize) {
    throw ArgumentError.value(
      tableLog,
      'tableLog',
      'table too small for $present symbols',
    );
  }
  var allocated = 0;
  for (var s = 0; s <= maxSymbolValue; s++) {
    final c = count[s];
    if (c == 0) continue;
    var p = (c * tableSize) ~/ total;
    if (p < 1) p = 1;
    normalized[s] = p;
    allocated += p;
  }
  while (allocated > tableSize) {
    // Take back states from the largest probability that can still shrink.
    var best = -1;
    var bestCount = -1;
    for (var s = 0; s <= maxSymbolValue; s++) {
      if (normalized[s] > 1 && count[s] > bestCount) {
        bestCount = count[s];
        best = s;
      }
    }
    if (best < 0) {
      // Only low-probability symbols left; shrink any above one.
      for (var s = 0; s <= maxSymbolValue; s++) {
        if (normalized[s] > 1) {
          best = s;
          break;
        }
      }
    }
    if (best < 0) {
      throw StateError('cannot normalize FSE distribution');
    }
    normalized[best]--;
    allocated--;
  }
  if (allocated < tableSize) {
    final candidates = <int>[];
    for (var s = 0; s <= maxSymbolValue; s++) {
      if (normalized[s] > 0) candidates.add(s);
    }
    final remainders = <int, int>{};
    for (final s in candidates) {
      remainders[s] = (count[s] * tableSize) % total;
    }
    candidates.sort((a, b) {
      final byRemainder = remainders[b]!.compareTo(remainders[a]!);
      if (byRemainder != 0) return byRemainder;
      return count[b].compareTo(count[a]);
    });
    var index = 0;
    while (allocated < tableSize) {
      normalized[candidates[index % candidates.length]]++;
      allocated++;
      index++;
    }
  }
  return normalized;
}

/// Writes an FSE table description (normalized-count header).
///
/// Ported from `FSE_writeNCount_generic`; the bitstream is forward and
/// little-endian, with two-byte flushes.
void writeFseNCount(
  ByteWriter output,
  List<int> normalized,
  int maxSymbolValue,
  int tableLog,
) {
  final alphabetSize = maxSymbolValue + 1;
  final tableSize = 1 << tableLog;
  var bitStream = 0;
  var bitCount = 0;
  var symbol = 0;
  var previousIs0 = false;

  void flush16() {
    output.writeByte(bitStream & 0xFF);
    output.writeByte((bitStream >> 8) & 0xFF);
    bitStream >>= 16;
    bitCount -= 16;
  }

  // Table size field: 4 bits, value tableLog - 5.
  bitStream += (tableLog - 5) << bitCount;
  bitCount += 4;

  var remaining = tableSize + 1; // +1 for extra accuracy
  var threshold = tableSize;
  var nbBits = tableLog + 1;

  while (symbol < alphabetSize && remaining > 1) {
    if (previousIs0) {
      var start = symbol;
      while (symbol < alphabetSize && normalized[symbol] == 0) {
        symbol++;
      }
      if (symbol == alphabetSize) break;
      while (symbol >= start + 24) {
        start += 24;
        bitStream += 0xFFFF << bitCount;
        // Write the pending bits plus the start of the zero-run chunk; the
        // remaining chunk bits stay pending, so bitCount is unchanged.
        output.writeByte(bitStream & 0xFF);
        output.writeByte((bitStream >> 8) & 0xFF);
        bitStream >>= 16;
      }
      while (symbol >= start + 3) {
        start += 3;
        bitStream += 3 << bitCount;
        bitCount += 2;
      }
      bitStream += (symbol - start) << bitCount;
      bitCount += 2;
      if (bitCount > 16) flush16();
    }
    var value = normalized[symbol];
    symbol++;
    final maximum = (2 * threshold - 1) - remaining;
    remaining -= value < 0 ? -value : value;
    value++; // +1 for extra accuracy
    if (value >= threshold) value += maximum;
    bitStream += value << bitCount;
    bitCount += nbBits;
    if (value < maximum) bitCount -= 1;
    previousIs0 = value == 1;
    if (remaining < 1) {
      throw StateError('invalid normalized distribution');
    }
    while (remaining < threshold) {
      nbBits--;
      threshold >>= 1;
    }
    if (bitCount > 16) flush16();
  }
  if (remaining != 1) {
    throw StateError('invalid normalized distribution');
  }
  // Flush the remaining bits (one or two bytes).
  final finalBytes = (bitCount + 7) >> 3;
  output.writeByte(bitStream & 0xFF);
  if (finalBytes > 1) {
    output.writeByte((bitStream >> 8) & 0xFF);
  }
}

/// Encodes [symbols] with two interleaved FSE states sharing [table].
///
/// Used for Huffman weight series; the reference implementation's odd/even
/// state init order is preserved exactly.
void encodeFseStreamTwoStates(
  BitWriter bitWriter,
  FseCTable table,
  Uint8List symbols,
) {
  final length = symbols.length;
  if (length <= 2) {
    throw ArgumentError.value(length, 'symbols', 'need more than two symbols');
  }
  var ip = length;
  late int state1;
  late int state2;
  late bool useState1;
  if ((length & 1) != 0) {
    state1 = table.initStateForSymbol(symbols[--ip]);
    state2 = table.initStateForSymbol(symbols[--ip]);
    useState1 = true;
  } else {
    state2 = table.initStateForSymbol(symbols[--ip]);
    state1 = table.initStateForSymbol(symbols[--ip]);
    useState1 = false;
  }
  while (ip > 0) {
    if (useState1) {
      state1 = table.encodeSymbol(bitWriter, state1, symbols[--ip]);
    } else {
      state2 = table.encodeSymbol(bitWriter, state2, symbols[--ip]);
    }
    useState1 = !useState1;
  }
  table.flushState(bitWriter, state2);
  table.flushState(bitWriter, state1);
  bitWriter.finish();
}

int _highBit32(int value) {
  var bits = 0;
  while (value > 1) {
    value >>= 1;
    bits++;
  }
  return bits;
}
