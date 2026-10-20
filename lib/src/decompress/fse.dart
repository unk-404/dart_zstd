/// Finite State Entropy (FSE) decoding tables.
///
/// Implements the table description parser and the normalized-distribution to
/// decoding-table conversion described in the Zstandard format specification.
library;

import 'dart:typed_data';

import '../common/errors.dart';
import 'bit_stream.dart';

/// Maximum offset code supported (matches libzstd's `MaxOff`).
const int kMaxOffsetCode = 31;

/// Maximum literal length code.
const int kMaxLlCode = 35;

/// Maximum match length code.
const int kMaxMlCode = 52;

/// Maximum accuracy log for the literal length and match length tables.
const int kMaxLlMlAccuracyLog = 9;

/// Maximum accuracy log for the offset table.
const int kMaxOffsetAccuracyLog = 8;

/// A single FSE decoding table.
///
/// Row `state` packs everything the sequence loop needs into one 32-bit entry:
/// symbol in bits 0-7, state-update bit count in bits 8-11 and the next-state
/// base in bits 12-20. The base is always `< table size`, because the table is
/// at most `2^9` rows for LL/ML and `2^8` for offsets.
final class FseTable {
  FseTable(this.entries, this.accuracyLog);

  final Uint32List entries;
  final int accuracyLog;

  /// The degenerate table used by `RLE_Mode`: one symbol, no bits consumed.
  static FseTable rle(int symbol) =>
      FseTable(Uint32List.fromList(<int>[symbol]), 0);

  /// Builds a table from a normalized distribution.
  ///
  /// [counts] entries are in `{-1, 0, 1, ...}`; the sum of absolute values must
  /// be exactly `1 << accuracyLog`.
  static FseTable fromCounts(List<int> counts, int accuracyLog) {
    if (accuracyLog < 0 || accuracyLog > 15) {
      throw const ZstdException(
        ZstdErrorCode.invalidFseTable,
        'FSE accuracy log out of range',
      );
    }
    final size = kPow2[accuracyLog];
    final numSymbols = counts.length;
    if (numSymbols == 0 || numSymbols > 256) {
      throw const ZstdException(
        ZstdErrorCode.invalidFseTable,
        'invalid number of FSE symbols',
      );
    }
    var total = 0;
    for (var s = 0; s < numSymbols; s++) {
      final c = counts[s];
      if (c < -1 || c > size) {
        throw const ZstdException(
          ZstdErrorCode.invalidFseTable,
          'normalized FSE count out of range',
        );
      }
      total += c < 0 ? -c : c;
    }
    if (total != size) {
      throw const ZstdException(
        ZstdErrorCode.invalidFseTable,
        'FSE distribution does not sum to its table size',
      );
    }

    final symbols = Uint8List(size);
    final stateDesc = Int32List(numSymbols);

    // "less than 1" probabilities get the last rows, in natural order.
    var highThreshold = size;
    for (var s = 0; s < numSymbols; s++) {
      if (counts[s] == -1) {
        if (--highThreshold < 0) {
          throw const ZstdException(
            ZstdErrorCode.invalidFseTable,
            'too many low probability FSE symbols',
          );
        }
        symbols[highThreshold] = s;
        stateDesc[s] = 1;
      }
    }

    final step = (size >> 1) + (size >> 3) + 3;
    final mask = size - 1;
    var pos = 0;
    for (var s = 0; s < numSymbols; s++) {
      final count = counts[s];
      if (count <= 0) continue;
      stateDesc[s] = count;
      for (var i = 0; i < count; i++) {
        symbols[pos] = s;
        do {
          pos = (pos + step) & mask;
        } while (pos >= highThreshold);
      }
    }
    if (pos != 0) {
      throw const ZstdException(
        ZstdErrorCode.invalidFseTable,
        'FSE table rows were not filled exactly',
      );
    }

    final entries = Uint32List(size);
    for (var i = 0; i < size; i++) {
      final symbol = symbols[i];
      final nextStateDesc = stateDesc[symbol]++;
      final bits = accuracyLog - highestSetBit(nextStateDesc);
      final base = (nextStateDesc << bits) - size;
      entries[i] = symbol | (bits << 8) | (base << 12);
    }

    return FseTable(entries, accuracyLog);
  }

  /// Parses an FSE distribution table from [reader] and leaves it byte aligned
  /// after the last consumed byte.
  static FseTable readFrom(
    ForwardBitReader reader,
    int maxSymbolValue,
    int maxAccuracyLog,
  ) {
    final accuracyLog = 5 + reader.readBits(4);
    if (accuracyLog > maxAccuracyLog || accuracyLog > 15) {
      throw const ZstdException(
        ZstdErrorCode.invalidFseTable,
        'FSE accuracy log exceeds the format maximum',
      );
    }
    final maxSymbols = maxSymbolValue + 1;
    final counts = Int32List(maxSymbols);

    var remaining = kPow2[accuracyLog] + 1;
    var threshold = kPow2[accuracyLog];
    var nbBits = accuracyLog + 1;
    var charnum = 0;
    var previousZero = false;

    while (true) {
      if (previousZero) {
        // A zero probability is followed by 2-bit repeat flags; a value of 3
        // means "three more zeroes, read another flag".
        var repeat = reader.readBits(2);
        while (repeat == 3) {
          charnum += 3;
          if (charnum >= maxSymbols) {
            throw const ZstdException(
              ZstdErrorCode.invalidFseTable,
              'zero run exceeds the FSE symbol range',
            );
          }
          repeat = reader.readBits(2);
        }
        charnum += repeat;
        if (charnum >= maxSymbols) {
          // May be exactly the end of the alphabet; validated below.
          break;
        }
      }

      final max = (2 * threshold - 1) - remaining;
      final value = reader.readBits(nbBits);
      int count;
      if ((value & (threshold - 1)) < max) {
        count = value & (threshold - 1);
        reader.rewindBits(1);
      } else {
        count = value & (2 * threshold - 1);
        if (count >= threshold) count -= max;
      }
      count--;

      if (count >= 0) {
        remaining -= count;
      } else {
        remaining += count; // -1
      }
      if (charnum >= maxSymbols) {
        throw const ZstdException(
          ZstdErrorCode.invalidFseTable,
          'too many FSE symbols in the distribution',
        );
      }
      counts[charnum++] = count;
      previousZero = count == 0;

      if (remaining < threshold) {
        if (remaining <= 1) break;
        nbBits = highestSetBit(remaining) + 1;
        threshold = kPow2[nbBits - 1];
      }
      if (charnum >= maxSymbols) break;
    }

    if (remaining != 1) {
      throw const ZstdException(
        ZstdErrorCode.invalidFseTable,
        'FSE distribution is incomplete',
      );
    }
    reader.alignToByte();

    return fromCounts(Int32List.sublistView(counts, 0, charnum), accuracyLog);
  }

  /// The predefined literal length distribution (accuracy log 6).
  static final FseTable llPredefined = fromCounts(const <int>[
    4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, //
    2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1, //
    -1, -1, -1, -1,
  ], 6);

  /// The predefined offset distribution (accuracy log 5).
  static final FseTable offsetPredefined = fromCounts(const <int>[
    1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, //
    1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1,
  ], 5);

  /// The predefined match length distribution (accuracy log 6).
  static final FseTable mlPredefined = fromCounts(const <int>[
    1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, //
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, //
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1,
  ], 6);
}
