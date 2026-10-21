import 'dart:math' as math;
import 'dart:typed_data';

import 'bit_writer.dart';
import 'byte_writer.dart';
import 'fse_encoder.dart';

/// A match found by the block matcher, in stream/block coordinates.
///
/// [litLength] literals precede the match, then [matchLength] bytes are copied
/// from [offset] bytes back. Match length is never smaller than 3.
final class SequenceStore {
  SequenceStore(int capacity)
    : litLengths = Int32List(capacity),
      matchLengths = Int32List(capacity),
      offsets = Int32List(capacity);

  final Int32List litLengths;
  final Int32List matchLengths;
  final Int32List offsets;
  int count = 0;

  void clear() {
    count = 0;
  }

  void add(int litLength, int matchLength, int offset) {
    if (litLength < 0) {
      throw ArgumentError.value(litLength, 'litLength', 'must be >= 0');
    }
    if (matchLength < 3) {
      throw ArgumentError.value(matchLength, 'matchLength', 'must be >= 3');
    }
    if (offset < 1) {
      throw ArgumentError.value(offset, 'offset', 'must be >= 1');
    }
    if (count >= litLengths.length) {
      throw StateError('sequence store overflow');
    }
    litLengths[count] = litLength;
    matchLengths[count] = matchLength;
    offsets[count] = offset;
    count++;
  }
}

/// Literals length codes, from the format specification.
const List<int> _llBits = <int>[
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 0-15
  1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, // 16-31
  13, 14, 15, 16, // 32-35
];

const List<int> _llBaseline = <int>[
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, // 0-15
  16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, // 16-30
  4096, 8192, 16384, 32768, 65536, // 31-35
];

const List<int> _llCodeTable = <int>[
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, // 0-15
  16, 16, 17, 17, 18, 18, 19, 19, // 16-23
  20, 20, 20, 20, 21, 21, 21, 21, // 24-31
  22, 22, 22, 22, 22, 22, 22, 22, // 32-39
  23, 23, 23, 23, 23, 23, 23, 23, // 40-47
  24, 24, 24, 24, 24, 24, 24, 24, // 48-55
  24, 24, 24, 24, 24, 24, 24, 24, // 56-63
];

/// Match length codes, expressed in terms of `matchLength - 3`.
const List<int> _mlBits = <int>[
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 0-15
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 16-31
  1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, // 32-47
  12, 13, 14, 15, 16, // 48-52
];

const List<int> _mlBaseline = <int>[
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, // 0-15
  16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, // 16-31
  32, 34, 36, 38, 40, 44, 48, 56, 64, 80, 96, 128, 256, 512, 1024, // 32-46
  2048, 4096, 8192, 16384, 32768, 65536, // 47-52
];

const List<int> _mlCodeTable = <int>[
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, // 0-15
  16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, // 16-31
  32, 32, 33, 33, 34, 34, 35, 35, 36, 36, 36, 36, 37, 37, 37, 37, // 32-47
  38, 38, 38, 38, 38, 38, 38, 38, 39, 39, 39, 39, 39, 39, 39, 39, // 48-63
  40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, // 64-79
  41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, // 80-95
  42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, // 96-111
  42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, // 112-127
];

/// Predefined literals-length distribution (accuracy log 6, 36 symbols).
const List<int> _llDefaultDistribution = <int>[
  4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, //
  2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1, //
  -1, -1, -1, -1,
];

/// Predefined match-length distribution (accuracy log 6, 53 symbols).
const List<int> _mlDefaultDistribution = <int>[
  1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, //
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, //
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, //
  -1, -1, -1, -1, -1,
];

/// Predefined offset distribution (accuracy log 5, 29 symbols).
const List<int> _ofDefaultDistribution = <int>[
  1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, //
  1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1,
];

final FseCTable _llTable = FseCTable.fromNormalized(
  _llDefaultDistribution,
  35,
  6,
);
final FseCTable _mlTable = FseCTable.fromNormalized(
  _mlDefaultDistribution,
  52,
  6,
);
final FseCTable _ofTable = FseCTable.fromNormalized(
  _ofDefaultDistribution,
  28,
  5,
);

/// Compression mode values from the sequences section header.
const int sequenceModePredefined = 0;
const int sequenceModeRle = 1;
const int sequenceModeFse = 2;
const int sequenceModeRepeat = 3;

/// Highest code representable by each predefined table.
const int _defaultMaxLlSymbol = 35;
const int _defaultMaxMlSymbol = 52;
const int _defaultMaxOfSymbol = 28;

/// Literals length code for [length] (0..131071).
int literalsLengthCode(int length) {
  if (length < 64) return _llCodeTable[length];
  return _highBit32(length) + 19;
}

/// Match length code for [matchLength] (>= 3).
int matchLengthCode(int matchLength) {
  final base = matchLength - 3;
  if (base < 128) return _mlCodeTable[base];
  return _highBit32(base) + 36;
}

/// The three "recent offsets" of a frame, in recency order.
///
/// The evolution rules are those of the format specification's "Offset updates
/// rules" section, including the shifted interpretation when a sequence has no
/// literals. Both the match finder (to prefer cheap repeat-offset matches) and
/// the sequence writer (to produce the actual `Offset_Value`) use this class.
final class RepeatOffsetHistory {
  RepeatOffsetHistory({this.rep1 = 1, this.rep2 = 4, this.rep3 = 8});

  int rep1;
  int rep2;
  int rep3;

  /// `[rep1, rep2, rep3]`
  List<int> snapshot() => <int>[rep1, rep2, rep3];

  /// Restores values previously returned by [snapshot].
  void restore(List<int> snapshot) {
    rep1 = snapshot[0];
    rep2 = snapshot[1];
    rep3 = snapshot[2];
  }

  /// Converts a real match [offset] into the on-wire `Offset_Value`.
  ///
  /// [litLength] is the number of literals in front of the match in the same
  /// sequence; when it is zero the repeat codes mean "repeat offset 2",
  /// "repeat offset 3" and "repeat offset 1 minus one", respectively.
  int encodeOffset(int litLength, int offset) {
    if (litLength > 0) {
      if (offset == rep1) return 1;
      if (offset == rep2) {
        final tmp = rep1;
        rep1 = rep2;
        rep2 = tmp;
        return 2;
      }
      if (offset == rep3) {
        final tmp = rep2;
        rep2 = rep1;
        rep1 = rep3;
        rep3 = tmp;
        return 3;
      }
      rep3 = rep2;
      rep2 = rep1;
      rep1 = offset;
      return offset + 3;
    }
    if (offset == rep2) {
      final tmp = rep1;
      rep1 = rep2;
      rep2 = tmp;
      return 1;
    }
    if (offset == rep3) {
      final tmp = rep3;
      rep3 = rep2;
      rep2 = rep1;
      rep1 = tmp;
      return 2;
    }
    if (rep1 > 1 && offset == rep1 - 1) {
      rep3 = rep2;
      rep2 = rep1;
      rep1 = offset;
      return 3;
    }
    rep3 = rep2;
    rep2 = rep1;
    rep1 = offset;
    return offset + 3;
  }
}

/// Precomputed log2 values for normalized FSE probabilities (1..512).
final Float64List _log2Table = () {
  final table = Float64List(1025);
  for (var i = 1; i < table.length; i++) {
    table[i] = math.log(i) / math.ln2;
  }
  return table;
}();

/// One selected entropy-table choice for one symbol type.
final class SequenceTableChoice {
  SequenceTableChoice({
    required this.mode,
    required this.table,
    this.normalized,
    this.tableLog = 0,
    this.maxSymbol = 0,
    this.rleSymbol = 0,
  });

  final int mode;
  final FseCTable table;
  final List<int>? normalized;
  final int tableLog;
  final int maxSymbol;
  final int rleSymbol;

  SequenceTableChoice repeated() => SequenceTableChoice(
    mode: sequenceModeRepeat,
    table: table,
    normalized: normalized,
    tableLog: tableLog,
    maxSymbol: maxSymbol,
  );

  bool get repeatable => mode == sequenceModeFse || mode == sequenceModeRepeat;
}

/// Snapshot of the per-symbol-type table state, for block fallbacks.
final class SequenceTableSnapshot {
  SequenceTableSnapshot(this._ll, this._of, this._ml);

  final SequenceTableChoice? _ll;
  final SequenceTableChoice? _of;
  final SequenceTableChoice? _ml;
}

/// Encodes the sequences section for one compressed block.
///
/// The repeat-offset history and the previously used entropy tables are kept
/// across the compressed blocks of a frame, as required by the format.
final class SequenceWriter {
  /// Repeat-offset history shared across the blocks of a frame.
  final RepeatOffsetHistory history;

  /// Reused bit accumulator for the sequence bitstream.
  final BitWriter _bitWriter = BitWriter(4096);

  /// Reused scratch buffer for estimating FSE table-description sizes.
  final ByteWriter _ncountScratch = ByteWriter(64);

  final Int32List _llCounts = Int32List(36);
  final Int32List _ofCounts = Int32List(32);
  final Int32List _mlCounts = Int32List(53);

  SequenceTableChoice? _llPrevious;
  SequenceTableChoice? _ofPrevious;
  SequenceTableChoice? _mlPrevious;

  SequenceWriter({List<int>? initialRepCodes})
    : history = RepeatOffsetHistory() {
    if (initialRepCodes != null) history.restore(initialRepCodes);
  }

  /// Captures the repeat-offset history.
  List<int> snapshotRepCodes() => history.snapshot();

  /// Restores a history previously returned by [snapshotRepCodes].
  void restoreRepCodes(List<int> snapshot) => history.restore(snapshot);

  /// Captures the per-type entropy tables.
  SequenceTableSnapshot snapshotTables() =>
      SequenceTableSnapshot(_llPrevious, _ofPrevious, _mlPrevious);

  /// Restores per-type entropy tables.
  void restoreTables(SequenceTableSnapshot snapshot) {
    _llPrevious = snapshot._ll;
    _ofPrevious = snapshot._of;
    _mlPrevious = snapshot._ml;
  }

  /// Writes the complete sequences section (header + bitstream) for [store].
  void write(ByteWriter output, SequenceStore store) {
    _writeNumberOfSequences(output, store.count);
    if (store.count == 0) return;

    final count = store.count;
    final llCodes = Int32List(count);
    final mlCodes = Int32List(count);
    final ofCodes = Int32List(count);
    final offsetValues = Int32List(count);
    for (var i = 0; i < count; i++) {
      final litLength = store.litLengths[i];
      final matchLength = store.matchLengths[i];
      final offset = store.offsets[i];
      llCodes[i] = literalsLengthCode(litLength);
      mlCodes[i] = matchLengthCode(matchLength);
      final offsetValue = history.encodeOffset(litLength, offset);
      offsetValues[i] = offsetValue;
      ofCodes[i] = _highBit32(offsetValue);
    }

    final llChoice = _select(
      codes: llCodes,
      nbSeq: count,
      maxLog: 9,
      maxSymbolAllowed: _defaultMaxLlSymbol,
      defaultNormalized: _llDefaultDistribution,
      defaultTableLog: 6,
      defaultMaxSymbol: _defaultMaxLlSymbol,
      previous: _llPrevious,
      defaultTable: _llTable,
      counts: _llCounts,
    );
    final ofChoice = _select(
      codes: ofCodes,
      nbSeq: count,
      maxLog: 8,
      maxSymbolAllowed: 31,
      defaultNormalized: _ofDefaultDistribution,
      defaultTableLog: 5,
      defaultMaxSymbol: _defaultMaxOfSymbol,
      previous: _ofPrevious,
      defaultTable: _ofTable,
      counts: _ofCounts,
    );
    final mlChoice = _select(
      codes: mlCodes,
      nbSeq: count,
      maxLog: 9,
      maxSymbolAllowed: _defaultMaxMlSymbol,
      defaultNormalized: _mlDefaultDistribution,
      defaultTableLog: 6,
      defaultMaxSymbol: _defaultMaxMlSymbol,
      previous: _mlPrevious,
      defaultTable: _mlTable,
      counts: _mlCounts,
    );

    output.writeByte(
      (llChoice.mode << 6) | (ofChoice.mode << 4) | (mlChoice.mode << 2),
    );
    _writeChoiceTable(output, llChoice);
    _writeChoiceTable(output, ofChoice);
    _writeChoiceTable(output, mlChoice);

    _llPrevious = llChoice.repeatable ? llChoice : null;
    _ofPrevious = ofChoice.repeatable ? ofChoice : null;
    _mlPrevious = mlChoice.repeatable ? mlChoice : null;

    final bitWriter = _bitWriter..reset();
    final last = count - 1;
    final llTable = llChoice.table;
    final ofTable = ofChoice.table;
    final mlTable = mlChoice.table;
    final llStateTable = llTable.stateTable;
    final llDeltaNbBits = llTable.deltaNbBits;
    final llDeltaFindState = llTable.deltaFindState;
    final ofStateTable = ofTable.stateTable;
    final ofDeltaNbBits = ofTable.deltaNbBits;
    final ofDeltaFindState = ofTable.deltaFindState;
    final mlStateTable = mlTable.stateTable;
    final mlDeltaNbBits = mlTable.deltaNbBits;
    final mlDeltaFindState = mlTable.deltaFindState;
    var llState = llTable.initStateForSymbol(llCodes[last]);
    var ofState = ofTable.initStateForSymbol(ofCodes[last]);
    var mlState = mlTable.initStateForSymbol(mlCodes[last]);

    final lastLlCode = llCodes[last];
    final lastMlCode = mlCodes[last];
    final lastOfCode = ofCodes[last];
    bitWriter.addBits(
      store.litLengths[last] - _llBaseline[lastLlCode],
      _llBits[lastLlCode],
    );
    bitWriter.addBits(
      store.matchLengths[last] - 3 - _mlBaseline[lastMlCode],
      _mlBits[lastMlCode],
    );
    bitWriter.addBits(offsetValues[last] - (1 << lastOfCode), lastOfCode);

    // Encoded backwards (last sequence first), exactly like the reference.
    for (var i = last - 1; i >= 0; i--) {
      final ofCode = ofCodes[i];
      var nbBits = (ofState + ofDeltaNbBits[ofCode]) >> 16;
      bitWriter.addBits(ofState, nbBits);
      ofState = ofStateTable[(ofState >> nbBits) + ofDeltaFindState[ofCode]];

      final mlCode = mlCodes[i];
      nbBits = (mlState + mlDeltaNbBits[mlCode]) >> 16;
      bitWriter.addBits(mlState, nbBits);
      mlState = mlStateTable[(mlState >> nbBits) + mlDeltaFindState[mlCode]];

      final llCode = llCodes[i];
      nbBits = (llState + llDeltaNbBits[llCode]) >> 16;
      bitWriter.addBits(llState, nbBits);
      llState = llStateTable[(llState >> nbBits) + llDeltaFindState[llCode]];

      bitWriter.addBits(
        store.litLengths[i] - _llBaseline[llCode],
        _llBits[llCode],
      );
      bitWriter.addBits(
        store.matchLengths[i] - 3 - _mlBaseline[mlCode],
        _mlBits[mlCode],
      );
      bitWriter.addBits(offsetValues[i] - (1 << ofCode), ofCode);
    }

    // Flushed in decoder-read order: match lengths, offsets, literals lengths.
    bitWriter.addBits(mlState, mlTable.tableLog);
    bitWriter.addBits(ofState, ofTable.tableLog);
    bitWriter.addBits(llState, llTable.tableLog);
    bitWriter.finish();
    output.writeBytes(bitWriter.bytes);
    bitWriter.reset();
  }

  void _writeChoiceTable(ByteWriter output, SequenceTableChoice choice) {
    if (choice.mode == sequenceModeFse) {
      writeFseNCount(
        output,
        choice.normalized!,
        choice.maxSymbol,
        choice.tableLog,
      );
    } else if (choice.mode == sequenceModeRle) {
      output.writeByte(choice.rleSymbol);
    }
  }

  SequenceTableChoice _select({
    required Int32List codes,
    required int nbSeq,
    required int maxLog,
    required int maxSymbolAllowed,
    required List<int> defaultNormalized,
    required int defaultTableLog,
    required int defaultMaxSymbol,
    required SequenceTableChoice? previous,
    required FseCTable defaultTable,
    required Int32List counts,
  }) {
    counts.fillRange(0, counts.length, 0);
    var maxPresent = -1;
    var mostFrequent = 0;
    for (var i = 0; i < nbSeq; i++) {
      final code = codes[i];
      if (code < 0 || code > maxSymbolAllowed) {
        throw StateError('sequence code $code out of range');
      }
      final c = ++counts[code];
      if (c > mostFrequent) mostFrequent = c;
      if (code > maxPresent) maxPresent = code;
    }
    final basicAllowed = maxPresent <= defaultMaxSymbol;

    if (mostFrequent == nbSeq) {
      if (basicAllowed && nbSeq <= 2) {
        return SequenceTableChoice(
          mode: sequenceModePredefined,
          table: defaultTable,
          normalized: defaultNormalized,
          tableLog: defaultTableLog,
          maxSymbol: maxPresent,
        );
      }
      return SequenceTableChoice(
        mode: sequenceModeRle,
        table: FseCTable.rle(maxPresent),
        maxSymbol: maxPresent,
        rleSymbol: maxPresent,
      );
    }

    SequenceTableChoice? best;
    var bestCost = double.infinity;
    if (basicAllowed) {
      best = SequenceTableChoice(
        mode: sequenceModePredefined,
        table: defaultTable,
        normalized: defaultNormalized,
        tableLog: defaultTableLog,
        maxSymbol: maxPresent,
      );
      bestCost = _entropyBits(
        defaultNormalized,
        defaultMaxSymbol,
        defaultTableLog,
        counts,
      );
    }

    if (previous != null &&
        previous.normalized != null &&
        previous.repeatable &&
        _canRepresent(previous.normalized!, counts, maxSymbolAllowed)) {
      final repeatCost = _entropyBits(
        previous.normalized!,
        previous.maxSymbol,
        previous.tableLog,
        counts,
      );
      if (repeatCost < bestCost) {
        best = previous.repeated();
        bestCost = repeatCost;
      }
    }

    try {
      final tableLog = fseOptimalTableLog(maxLog, nbSeq, maxPresent, 2);
      final normalized = fseNormalizeCounts(
        count: counts,
        maxSymbolValue: maxPresent,
        total: nbSeq,
        tableLog: tableLog,
      );
      _ncountScratch.clear();
      writeFseNCount(_ncountScratch, normalized, maxPresent, tableLog);
      final customCost =
          _ncountScratch.length * 8 +
          _entropyBits(normalized, maxPresent, tableLog, counts);
      if (customCost < bestCost) {
        best = SequenceTableChoice(
          mode: sequenceModeFse,
          table: FseCTable.fromNormalized(normalized, maxPresent, tableLog),
          normalized: normalized,
          tableLog: tableLog,
          maxSymbol: maxPresent,
        );
        bestCost = customCost;
      }
    } on ArgumentError {
      // Normalization impossible; keep the predefined table.
    } on StateError {
      // Normalization impossible; keep the predefined table.
    }

    if (best == null) {
      // Should only happen when the alphabet is larger than the predefined
      // table; normalization is then guaranteed to have succeeded above.
      throw StateError('no sequence entropy table could be selected');
    }
    return best;
  }

  static bool _canRepresent(
    List<int> normalized,
    Int32List counts,
    int maxSymbolAllowed,
  ) {
    for (var s = 0; s <= maxSymbolAllowed; s++) {
      if (counts[s] != 0) {
        if (s >= normalized.length || normalized[s] == 0) return false;
      }
    }
    return true;
  }

  static double _entropyBits(
    List<int> normalized,
    int maxSymbol,
    int tableLog,
    Int32List counts,
  ) {
    var bits = 0.0;
    for (var s = 0; s <= maxSymbol && s < counts.length; s++) {
      final c = counts[s];
      if (c == 0) continue;
      if (s >= normalized.length) return double.infinity;
      var probability = normalized[s];
      if (probability == 0) return double.infinity;
      if (probability == -1) probability = 1;
      bits += c * (tableLog - _log2Table[probability]);
    }
    return bits;
  }

  void _writeNumberOfSequences(ByteWriter output, int count) {
    if (count < 128) {
      output.writeByte(count);
    } else if (count < 0x7F00) {
      output.writeByte((count >> 8) + 0x80);
      output.writeByte(count & 0xFF);
    } else {
      output.writeByte(0xFF);
      final value = count - 0x7F00;
      output.writeByte(value & 0xFF);
      output.writeByte(value >> 8);
    }
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
