import 'dart:typed_data';

import 'bit_writer.dart';

/// An FSE compression table, ported from the reference `FSE_buildCTable_wksp`.
///
/// v0.1.0 only ever uses the three predefined distributions from the format
/// specification, but the table construction is generic so that custom
/// distributions (v0.2) can reuse it unchanged.
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
    bitWriter.addBits(state, tableLog);
  }
}

int _highBit32(int value) {
  var bits = 0;
  while (value > 1) {
    value >>= 1;
    bits++;
  }
  return bits;
}
