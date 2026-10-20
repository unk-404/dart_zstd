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

/// Encodes the sequences section for one compressed block.
///
/// The repeat-offset history is kept across the compressed blocks of a frame,
/// as required by the format. Raw and RLE blocks do not update it, so callers
/// must snapshot it before a block and restore it if the block falls back to a
/// raw representation.
final class SequenceWriter {
  /// Repeat-offset history shared across the blocks of a frame.
  final RepeatOffsetHistory history = RepeatOffsetHistory();

  /// Captures the repeat-offset history.
  List<int> snapshotRepCodes() => history.snapshot();

  /// Restores a history previously returned by [snapshotRepCodes].
  void restoreRepCodes(List<int> snapshot) => history.restore(snapshot);

  /// Writes the complete sequences section (header + bitstream) for [store].
  void write(ByteWriter output, SequenceStore store) {
    _writeNumberOfSequences(output, store.count);
    if (store.count == 0) return;
    // All three symbol types use their predefined distributions.
    output.writeByte(0);

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

    final bitWriter = BitWriter(output);

    // The last sequence is encoded first. Its symbol states are pre-loaded so
    // that no state-transition bits are needed for it.
    final last = count - 1;
    var llState = _llTable.initStateForSymbol(llCodes[last]);
    var ofState = _ofTable.initStateForSymbol(ofCodes[last]);
    var mlState = _mlTable.initStateForSymbol(mlCodes[last]);
    _addExtraBits(
      bitWriter,
      store.litLengths[last],
      llCodes[last],
      store.matchLengths[last],
      mlCodes[last],
      offsetValues[last],
      ofCodes[last],
    );

    for (var i = last - 1; i >= 0; i--) {
      ofState = _ofTable.encodeSymbol(bitWriter, ofState, ofCodes[i]);
      mlState = _mlTable.encodeSymbol(bitWriter, mlState, mlCodes[i]);
      llState = _llTable.encodeSymbol(bitWriter, llState, llCodes[i]);
      _addExtraBits(
        bitWriter,
        store.litLengths[i],
        llCodes[i],
        store.matchLengths[i],
        mlCodes[i],
        offsetValues[i],
        ofCodes[i],
      );
    }

    // Flushed in decoder-read order: match lengths, offsets, literals lengths.
    _mlTable.flushState(bitWriter, mlState);
    _ofTable.flushState(bitWriter, ofState);
    _llTable.flushState(bitWriter, llState);
    bitWriter.finish();
  }

  void _addExtraBits(
    BitWriter bitWriter,
    int litLength,
    int litLengthCode,
    int matchLength,
    int matchLengthCode,
    int offsetValue,
    int offsetCode,
  ) {
    bitWriter.addBits(
      litLength - _llBaseline[litLengthCode],
      _llBits[litLengthCode],
    );
    bitWriter.addBits(
      matchLength - 3 - _mlBaseline[matchLengthCode],
      _mlBits[matchLengthCode],
    );
    bitWriter.addBits(offsetValue - (1 << offsetCode), offsetCode);
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
