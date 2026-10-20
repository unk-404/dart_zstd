import 'dart:typed_data';

import '../common/constants.dart';
import 'sequences.dart';

/// Match-finding strategy used by a compression level.
enum CompressionStrategy {
  /// Single hash table, one candidate per position (levels 1 and 2).
  fast,

  /// Two hash tables (a short and an 8-byte one) per position.
  doubleFast,

  /// Hash chains, take the longest match at every position (level 5).
  greedy,

  /// Hash chains with one-step lazy evaluation (levels 6-7).
  lazy,

  /// Hash chains with two-step lazy evaluation (levels 8-19).
  lazy2,
}

/// The subset of zstd's compression parameters implemented by the encoder.
final class CompressionParameters {
  const CompressionParameters({
    required this.windowLog,
    required this.hashLog,
    required this.chainLog,
    required this.searchLog,
    required this.minMatch,
    required this.strategy,
  });

  final int windowLog;
  final int hashLog;
  final int chainLog;
  final int searchLog;
  final int minMatch;
  final CompressionStrategy strategy;

  /// Window size implied by [windowLog].
  int get windowSize => 1 << windowLog;

  /// Maximum block size for this window: `min(128 KiB, Window_Size)`.
  int get blockSize =>
      windowSize < zstdBlockSizeMax ? windowSize : zstdBlockSizeMax;

  /// Number of chain candidates inspected per position.
  int get searchDepth {
    final depth = 1 << searchLog;
    return depth > 4096 ? 4096 : depth;
  }
}

/// Parameter table row: window log, chain log, hash log, search log, minMatch.
typedef _Row = (
  int windowLog,
  int chainLog,
  int hashLog,
  int searchLog,
  int minMatch,
);

// Rows mirror ZSTD_defaultCParameters in clevels.h, with the bt* strategies
// represented by the deepest chain search we implement (lazy2).
const List<_Row> _defaultRows = <_Row>[
  (19, 13, 14, 1, 7), // 1
  (20, 15, 16, 1, 6), // 2
  (21, 16, 17, 1, 5), // 3
  (21, 18, 18, 1, 5), // 4
  (21, 18, 19, 3, 5), // 5
  (21, 18, 19, 3, 5), // 6
  (21, 19, 20, 4, 5), // 7
  (21, 19, 20, 4, 5), // 8
  (22, 20, 21, 4, 5), // 9
  (22, 21, 22, 5, 5), // 10
  (22, 21, 22, 6, 5), // 11
  (22, 22, 23, 6, 5), // 12
  (22, 22, 22, 4, 5), // 13
  (22, 22, 23, 5, 5), // 14
  (22, 23, 23, 6, 5), // 15
  (22, 22, 22, 5, 5), // 16
  (23, 23, 22, 5, 4), // 17
  (23, 23, 22, 6, 3), // 18
  (23, 24, 22, 7, 3), // 19
];

const List<_Row> _small256kRows = <_Row>[
  (18, 13, 14, 1, 6), // 1
  (18, 14, 14, 1, 5), // 2
  (18, 16, 16, 1, 4), // 3
  (18, 16, 17, 3, 5), // 4
  (18, 17, 18, 5, 5), // 5
  (18, 18, 19, 3, 5), // 6
  (18, 18, 19, 4, 4), // 7
  (18, 18, 19, 4, 4), // 8
  (18, 18, 19, 5, 4), // 9
  (18, 18, 19, 6, 4), // 10
  (18, 18, 19, 5, 4), // 11
  (18, 19, 19, 7, 4), // 12
  (18, 18, 19, 4, 4), // 13
  (18, 18, 19, 4, 3), // 14
  (18, 18, 19, 6, 3), // 15
  (18, 19, 19, 6, 3), // 16
  (18, 19, 19, 8, 3), // 17
  (18, 19, 19, 6, 3), // 18
  (18, 19, 19, 8, 3), // 19
];

const List<_Row> _small128kRows = <_Row>[
  (17, 12, 13, 1, 6), // 1
  (17, 13, 15, 1, 5), // 2
  (17, 15, 16, 2, 5), // 3
  (17, 17, 17, 2, 4), // 4
  (17, 16, 17, 3, 4), // 5
  (17, 16, 17, 3, 4), // 6
  (17, 16, 17, 3, 4), // 7
  (17, 16, 17, 4, 4), // 8
  (17, 16, 17, 5, 4), // 9
  (17, 16, 17, 6, 4), // 10
  (17, 17, 17, 5, 4), // 11
  (17, 18, 17, 7, 4), // 12
  (17, 18, 17, 3, 4), // 13
  (17, 18, 17, 4, 3), // 14
  (17, 18, 17, 6, 3), // 15
  (17, 18, 17, 6, 3), // 16
  (17, 18, 17, 8, 3), // 17
  (17, 18, 17, 10, 3), // 18
  (17, 18, 17, 5, 3), // 19
];

const List<_Row> _tiny16kRows = <_Row>[
  (14, 14, 15, 1, 5), // 1
  (14, 14, 15, 1, 4), // 2
  (14, 14, 15, 2, 4), // 3
  (14, 14, 14, 4, 4), // 4
  (14, 14, 14, 3, 4), // 5
  (14, 14, 14, 4, 4), // 6
  (14, 14, 14, 6, 4), // 7
  (14, 14, 14, 8, 4), // 8
  (14, 15, 14, 5, 4), // 9
  (14, 15, 14, 9, 4), // 10
  (14, 15, 14, 3, 4), // 11
  (14, 15, 14, 4, 3), // 12
  (14, 15, 14, 5, 3), // 13
  (14, 15, 15, 6, 3), // 14
  (14, 15, 15, 7, 3), // 15
  (14, 15, 15, 5, 3), // 16
  (14, 15, 15, 6, 3), // 17
  (14, 15, 15, 7, 3), // 18
  (14, 15, 15, 8, 3), // 19
];

/// Strategy used by each level (see clevels.h; bt* mapped to deep lazy2).
CompressionStrategy _strategyForLevel(int level) {
  if (level <= 2) return CompressionStrategy.fast;
  if (level <= 4) return CompressionStrategy.doubleFast;
  if (level == 5) return CompressionStrategy.greedy;
  if (level <= 7) return CompressionStrategy.lazy;
  return CompressionStrategy.lazy2;
}

/// Chooses the parameters for [level] and an input of [sourceSize] bytes.
CompressionParameters compressionParametersFor(int level, int sourceSize) {
  if (level < 1 || level > 19) {
    throw ArgumentError.value(level, 'level', 'must be in 1..19');
  }
  final List<_Row> rows;
  if (sourceSize <= 16 * 1024) {
    rows = _tiny16kRows;
  } else if (sourceSize <= 128 * 1024) {
    rows = _small128kRows;
  } else if (sourceSize <= 256 * 1024) {
    rows = _small256kRows;
  } else {
    rows = _defaultRows;
  }
  final row = rows[level - 1];
  return _parametersFromRow(row, _strategyForLevel(level), level);
}

/// Parameters for a streaming session, where the total input size is unknown.
CompressionParameters compressionParametersForStreaming(int level) =>
    compressionParametersFor(level, 1 << 30);

CompressionParameters _parametersFromRow(
  _Row row,
  CompressionStrategy strategy,
  int level,
) {
  // Cap the tables so that high levels do not allocate tens of megabytes.
  final hashLog = row.$3 > 20 ? 20 : row.$3;
  final chainLog = row.$2 > 21 ? 21 : row.$2;
  // Levels 10..19 approximate libzstd's bt* optimal parsers with a
  // progressively deeper lazy2 chain search (and therefore beat level 9).
  var searchLog = row.$4;
  if (level >= 10 && strategy == CompressionStrategy.lazy2) {
    var boosted = 5 + (level - 9);
    if (boosted > 10) boosted = 10;
    if (boosted > searchLog) searchLog = boosted;
  }
  return CompressionParameters(
    windowLog: row.$1,
    hashLog: hashLog,
    chainLog: chainLog,
    searchLog: searchLog,
    minMatch: row.$5,
    strategy: strategy,
  );
}

/// Hash-table based match finder.
///
/// Hash entries store *stream* positions (offset by [_posBase] so they fit in a
/// 32-bit table), which keeps them valid when the streaming encoder slides its
/// buffer window. Entries outside the current window are simply rejected.
final class MatchFinder {
  MatchFinder(this.parameters)
    : _hashTable = Uint32List(1 << parameters.hashLog),
      _shortHashTable =
          parameters.strategy == CompressionStrategy.doubleFast ||
              parameters.strategy == CompressionStrategy.greedy ||
              parameters.strategy == CompressionStrategy.lazy ||
              parameters.strategy == CompressionStrategy.lazy2
          ? Uint32List(1 << parameters.chainLog)
          : null,
      _chainTable =
          parameters.strategy == CompressionStrategy.greedy ||
              parameters.strategy == CompressionStrategy.lazy ||
              parameters.strategy == CompressionStrategy.lazy2
          ? Uint32List(1 << parameters.chainLog)
          : null,
      _history = RepeatOffsetHistory();

  final CompressionParameters parameters;
  final Uint32List _hashTable;
  final Uint32List? _shortHashTable;
  final Uint32List? _chainTable;
  final RepeatOffsetHistory _history;

  int _posBase = 0;

  /// Fills [store] with the matches found in `data[blockStart..blockEnd)`.
  ///
  /// `data[0..blockStart)` is history available for back-references;
  /// [streamBase] is the stream offset of `data[0]`. [startRepCodes] is the
  /// repeat-offset history at the start of the block.
  void findMatches(
    Uint8List data,
    int blockStart,
    int blockEnd,
    int streamBase,
    List<int> startRepCodes,
    SequenceStore store,
  ) {
    if (blockEnd - blockStart < 4) return;
    _history.restore(startRepCodes);
    _ensurePositionCapacity(streamBase + blockStart);
    switch (parameters.strategy) {
      case CompressionStrategy.fast:
        _findFast(data, blockStart, blockEnd, streamBase, store);
      case CompressionStrategy.doubleFast:
        _findDoubleFast(data, blockStart, blockEnd, streamBase, store);
      case CompressionStrategy.greedy:
        _findChain(data, blockStart, blockEnd, streamBase, store, lazy: false);
      case CompressionStrategy.lazy:
        _findChain(data, blockStart, blockEnd, streamBase, store, lazy: true);
      case CompressionStrategy.lazy2:
        _findChain(data, blockStart, blockEnd, streamBase, store, lazy: true);
    }
  }

  /// Indexes a prefix (dictionary content) so that later blocks can match it.
  void loadPrefix(Uint8List data, int start, int end, int streamBase) {
    if (end <= start) return;
    _ensurePositionCapacity(streamBase + start);
    final minLength = _minimumHashLength;
    final hashShift = 32 - parameters.hashLog;
    final hashMask = _hashTable.length - 1;
    final doubleFast = parameters.strategy == CompressionStrategy.doubleFast;
    final shortShift = 32 - parameters.chainLog;
    final shortTable = _shortHashTable;
    final shortMask = shortTable == null ? 0 : shortTable.length - 1;
    final chainTable = _chainTable;
    final chainMask = chainTable == null ? 0 : chainTable.length - 1;
    for (var p = start; p + minLength <= end; p++) {
      final currentStream = streamBase + p;
      final value = _storedPosition(currentStream);
      if (doubleFast) {
        if (p + 8 <= end) {
          final longHash = _hash(data, p, 8, hashShift) & hashMask;
          _hashTable[longHash] = value;
        }
        final shortHash =
            _hash(data, p, parameters.minMatch, shortShift) & shortMask;
        shortTable![shortHash] = value;
      } else {
        final hash = _hash(data, p, parameters.minMatch, hashShift) & hashMask;
        final previous = _hashTable[hash];
        _hashTable[hash] = value;
        if (chainTable != null) {
          chainTable[(currentStream - _posBase) & chainMask] = previous;
        }
      }
    }
  }

  /// Makes sure 32-bit hash entries can hold the positions of this block.
  void _ensurePositionCapacity(int blockStartPosition) {
    if (blockStartPosition - _posBase < 0x7F000000) return;
    _hashTable.fillRange(0, _hashTable.length, 0);
    _shortHashTable?.fillRange(0, _shortHashTable.length, 0);
    _chainTable?.fillRange(0, _chainTable.length, 0);
    _posBase = blockStartPosition;
  }

  int _storedPosition(int streamPosition) => streamPosition - _posBase + 1;

  int _candidateLocal(int stored, int streamBase) {
    final candidateStream = stored - 1 + _posBase;
    return candidateStream - streamBase;
  }

  int _candidateOffset(int stored, int currentStream) =>
      currentStream - (stored - 1 + _posBase);

  int get _minimumHashLength =>
      parameters.minMatch < 4 ? 4 : parameters.minMatch;

  void _findFast(
    Uint8List data,
    int blockStart,
    int blockEnd,
    int streamBase,
    SequenceStore store,
  ) {
    final minMatch = parameters.minMatch;
    final hashShift = 32 - parameters.hashLog;
    final tableMask = _hashTable.length - 1;
    final windowSize = parameters.windowSize;
    final limit = blockEnd - _minimumHashLength;
    if (blockStart > limit) return;

    var ip = blockStart;
    var anchor = blockStart;
    while (ip <= limit) {
      final currentStream = streamBase + ip;
      final hash = _hash(data, ip, minMatch, hashShift) & tableMask;
      final stored = _hashTable[hash];
      _hashTable[hash] = _storedPosition(currentStream);

      final repLength = _repCodeMatch(data, ip, anchor, blockEnd, windowSize);
      if (repLength > 0) {
        final litLength = ip - anchor;
        final offset = _history.rep1;
        _history.encodeOffset(litLength, offset);
        store.add(litLength, repLength, offset);
        ip += repLength;
        ip = _storeImmediateReps(data, ip, blockEnd, windowSize, store);
        anchor = ip;
        _insertFastTrailing(
          data,
          ip,
          blockStart,
          limit,
          streamBase,
          hashShift,
          tableMask,
        );
        continue;
      }

      if (stored != 0) {
        final offset = _candidateOffset(stored, currentStream);
        if (offset > 0 && offset <= windowSize) {
          final candidate = _candidateLocal(stored, streamBase);
          if (candidate >= 0 && _read32(data, candidate) == _read32(data, ip)) {
            var length = _countMatch(data, ip + 4, candidate + 4, blockEnd) + 4;
            var matchStart = ip;
            var matchCandidate = candidate;
            while (matchStart > anchor &&
                matchCandidate > 0 &&
                data[matchStart - 1] == data[matchCandidate - 1]) {
              matchStart--;
              matchCandidate--;
              length++;
            }
            final litLength = matchStart - anchor;
            _history.encodeOffset(litLength, offset);
            store.add(litLength, length, offset);
            ip = matchStart + length;
            ip = _storeImmediateReps(data, ip, blockEnd, windowSize, store);
            anchor = ip;
            _insertFastTrailing(
              data,
              ip,
              blockStart,
              limit,
              streamBase,
              hashShift,
              tableMask,
            );
            continue;
          }
        }
      }
      ip++;
    }
  }

  void _findDoubleFast(
    Uint8List data,
    int blockStart,
    int blockEnd,
    int streamBase,
    SequenceStore store,
  ) {
    final minMatch = parameters.minMatch;
    final longShift = 32 - parameters.hashLog;
    final shortShift = 32 - parameters.chainLog;
    final longTableMask = _hashTable.length - 1;
    final shortTable = _shortHashTable!;
    final shortTableMask = shortTable.length - 1;
    final windowSize = parameters.windowSize;
    final limit = blockEnd - _minimumHashLength;
    final longLimit = blockEnd - 8;
    if (blockStart > limit) return;

    var ip = blockStart;
    var anchor = blockStart;
    while (ip <= limit) {
      final currentStream = streamBase + ip;

      final repLength = _repCodeMatch(data, ip, anchor, blockEnd, windowSize);
      if (repLength > 0) {
        final litLength = ip - anchor;
        final offset = _history.rep1;
        _history.encodeOffset(litLength, offset);
        store.add(litLength, repLength, offset);
        ip += repLength;
        ip = _storeImmediateReps(data, ip, blockEnd, windowSize, store);
        anchor = ip;
        _insertDoubleFastTrailing(
          data,
          ip,
          ip,
          blockStart,
          blockEnd,
          streamBase,
          longShift,
          shortShift,
        );
        continue;
      }

      var bestLength = 0;
      var bestOffset = 0;
      var bestCandidate = 0;
      var bestStart = ip;

      if (ip <= longLimit) {
        final longHash = _hash(data, ip, 8, longShift) & longTableMask;
        final storedLong = _hashTable[longHash];
        _hashTable[longHash] = _storedPosition(currentStream);
        if (storedLong != 0) {
          final offset = _candidateOffset(storedLong, currentStream);
          if (offset > 0 && offset <= windowSize) {
            final candidate = _candidateLocal(storedLong, streamBase);
            if (candidate >= 0 &&
                _read32(data, candidate) == _read32(data, ip) &&
                _read32(data, candidate + 4) == _read32(data, ip + 4)) {
              bestLength =
                  _countMatch(data, ip + 8, candidate + 8, blockEnd) + 8;
              bestOffset = offset;
              bestCandidate = candidate;
            }
          }
        }
      }

      final shortHash = _hash(data, ip, minMatch, shortShift) & shortTableMask;
      final storedShort = shortTable[shortHash];
      shortTable[shortHash] = _storedPosition(currentStream);
      if (storedShort != 0) {
        final offset = _candidateOffset(storedShort, currentStream);
        if (offset > 0 && offset <= windowSize) {
          final candidate = _candidateLocal(storedShort, streamBase);
          if (candidate >= 0 && _read32(data, candidate) == _read32(data, ip)) {
            final length =
                _countMatch(data, ip + 4, candidate + 4, blockEnd) + 4;
            if (length > bestLength) {
              bestLength = length;
              bestOffset = offset;
              bestCandidate = candidate;
            }
          }
        }
      }

      // libzstd also tries a long match one byte ahead after finding a short
      // one, which recovers many long matches in structured text.
      if (bestLength >= 4 && ip + 1 <= longLimit) {
        final longHash1 = _hash(data, ip + 1, 8, longShift) & longTableMask;
        final storedLong1 = _hashTable[longHash1];
        if (storedLong1 != 0) {
          final offset = _candidateOffset(storedLong1, currentStream + 1);
          if (offset > 0 && offset <= windowSize) {
            final candidate = _candidateLocal(storedLong1, streamBase);
            if (candidate >= 0 &&
                ip + 9 <= blockEnd &&
                _read32(data, candidate) == _read32(data, ip + 1) &&
                _read32(data, candidate + 4) == _read32(data, ip + 5)) {
              final length =
                  _countMatch(data, ip + 9, candidate + 8, blockEnd) + 8;
              if (length > bestLength) {
                bestLength = length;
                bestOffset = offset;
                bestCandidate = candidate;
                bestStart = ip + 1;
              }
            }
          }
        }
      }

      if (bestLength >= 4) {
        var matchStart = bestStart;
        var matchCandidate = bestCandidate;
        var length = bestLength;
        while (matchStart > anchor &&
            matchCandidate > 0 &&
            data[matchStart - 1] == data[matchCandidate - 1]) {
          matchStart--;
          matchCandidate--;
          length++;
        }
        final litLength = matchStart - anchor;
        _history.encodeOffset(litLength, bestOffset);
        store.add(litLength, length, bestOffset);
        ip = matchStart + length;
        ip = _storeImmediateReps(data, ip, blockEnd, windowSize, store);
        anchor = ip;
        _insertDoubleFastTrailing(
          data,
          ip,
          matchStart,
          blockStart,
          blockEnd,
          streamBase,
          longShift,
          shortShift,
        );
        continue;
      }
      ip++;
    }
  }

  void _findChain(
    Uint8List data,
    int blockStart,
    int blockEnd,
    int streamBase,
    SequenceStore store, {
    required bool lazy,
  }) {
    final parameters = this.parameters;
    final hashShift = 32 - parameters.hashLog;
    final hashMask = _hashTable.length - 1;
    final chainTable = _chainTable!;
    final chainMask = chainTable.length - 1;
    final windowSize = parameters.windowSize;
    final limit = blockEnd - _minimumHashLength;
    if (blockStart > limit) return;
    final chainLazy = lazy;
    final lazy2 = parameters.strategy == CompressionStrategy.lazy2;

    var ip = blockStart;
    var anchor = blockStart;

    var nextToInsert = blockStart;

    void insertPosition(int p) {
      final currentStream = streamBase + p;
      final hash = _hash(data, p, parameters.minMatch, hashShift) & hashMask;
      final previous = _hashTable[hash];
      _hashTable[hash] = _storedPosition(currentStream);
      chainTable[(currentStream - _posBase) & chainMask] = previous;
    }

    MatchSearchResult search(int position) {
      // Insert every position skipped since the last search, like libzstd's
      // ZSTD_insertAndFindFirstIndex: this keeps the chains dense after long
      // matches, which is essential for ratio.
      if (position > nextToInsert) {
        var stop = position - 1;
        if (stop > limit) stop = limit;
        for (var p = nextToInsert; p <= stop; p++) {
          insertPosition(p);
        }
        nextToInsert = stop + 1;
      }
      final currentStream = streamBase + position;
      final hash =
          _hash(data, position, parameters.minMatch, hashShift) & hashMask;
      final previous = _hashTable[hash];
      _hashTable[hash] = _storedPosition(currentStream);
      chainTable[(currentStream - _posBase) & chainMask] = previous;
      nextToInsert = position + 1;

      var bestLength = 0;
      var bestOffset = 0;
      var candidate = previous;
      var attempts = parameters.searchDepth;
      final maxLength = blockEnd - position;
      while (attempts-- > 0 && candidate != 0) {
        final candidateStream = candidate - 1 + _posBase;
        final offset = currentStream - candidateStream;
        if (offset <= 0 || offset > windowSize) break;
        final candidateLocal = candidateStream - streamBase;
        if (candidateLocal < 0) break;
        if (_read32(data, candidateLocal) == _read32(data, position)) {
          final length =
              _countMatch(data, position + 4, candidateLocal + 4, blockEnd) + 4;
          if (length > bestLength) {
            bestLength = length;
            bestOffset = offset;
            if (length >= maxLength) break;
          }
        }
        final next = chainTable[(candidateStream - _posBase) & chainMask];
        if (next == 0) break;
        if (next - 1 + _posBase >= candidateStream) break;
        candidate = next;
      }
      return MatchSearchResult(bestLength, bestOffset);
    }

    while (ip <= limit) {
      final match = search(ip);
      var bestLength = match.length;
      var bestOffset = match.offset;
      var bestPosition = ip;

      // Baseline repeat-offset candidate (cheap when it is nearly as long).
      final repLength = _repCodeMatch(data, ip, anchor, blockEnd, windowSize);
      if (repLength >= 4 &&
          repLength * 3 > _repGainAgainst(bestLength, bestOffset)) {
        bestLength = repLength;
        bestOffset = _history.rep1;
        bestPosition = ip;
      }

      if (bestLength >= 4 && chainLazy) {
        final maxDepth = lazy2 ? 2 : 1;
        for (var depth = 1; depth <= maxDepth; depth++) {
          final position = ip + depth;
          if (position > limit) break;
          var improved = false;

          final candidateRep = _repCodeMatch(
            data,
            position,
            anchor,
            blockEnd,
            windowSize,
          );
          if (candidateRep >= 4 &&
              candidateRep * 3 > _repGainAgainst(bestLength, bestOffset)) {
            bestLength = candidateRep;
            bestOffset = _history.rep1;
            bestPosition = position;
            improved = true;
          }

          final candidate = search(position);
          if (candidate.length >= 4 &&
              candidate.length * 4 - _highBit32(candidate.offset) >
                  _hashGainAgainst(bestLength, bestOffset)) {
            bestLength = candidate.length;
            bestOffset = candidate.offset;
            bestPosition = position;
            improved = true;
          }
          if (!improved) break;
        }
      }

      if (bestLength < 4) {
        ip++;
        continue;
      }

      var matchStart = bestPosition;
      var matchCandidate = matchStart - bestOffset;
      var length = bestLength;
      while (matchStart > anchor &&
          matchCandidate > 0 &&
          data[matchStart - 1] == data[matchCandidate - 1]) {
        matchStart--;
        matchCandidate--;
        length++;
      }
      final litLength = matchStart - anchor;
      _history.encodeOffset(litLength, bestOffset);
      store.add(litLength, length, bestOffset);
      ip = matchStart + length;
      ip = _storeImmediateReps(data, ip, blockEnd, windowSize, store);
      anchor = ip;
    }
  }

  /// Gain estimate used when comparing a repeat-offset candidate against the
  /// current best solution (same scale as libzstd's `gain1`).
  static int _repGainAgainst(int length, int offset) =>
      length * 3 - _highBit32(offset) + 1;

  /// Gain estimate used when comparing a regular match against the current
  /// best solution.
  static int _hashGainAgainst(int length, int offset) =>
      length * 4 - _highBit32(offset) + 4;

  static int _highBit32(int value) {
    var bits = 0;
    while (value > 1) {
      value >>= 1;
      bits++;
    }
    return bits;
  }

  /// Emits zero-literal repeat matches while the previous offset keeps
  /// matching. This mirrors libzstd's "immediate repcode" loop and is a major
  /// win on repetitive inputs: offset value 1 with zero literals means
  /// "repeat offset 2", which costs no offset bits.
  int _storeImmediateReps(
    Uint8List data,
    int ip,
    int blockEnd,
    int windowSize,
    SequenceStore store,
  ) {
    while (ip + 4 <= blockEnd) {
      final offset = _history.rep2;
      if (offset <= 0 || offset > windowSize) break;
      final candidate = ip - offset;
      if (candidate < 0) break;
      if (_read32(data, candidate) != _read32(data, ip)) break;
      final length = _countMatch(data, ip + 4, candidate + 4, blockEnd) + 4;
      _history.encodeOffset(0, offset);
      store.add(0, length, offset);
      ip += length;
    }
    return ip;
  }

  /// Checks the most recent repeat offset at [position].
  ///
  /// Returns the match length, or 0 when the repeat offset cannot be used
  /// (no literal in front of the match, out of window, or mismatch).
  int _repCodeMatch(
    Uint8List data,
    int position,
    int anchor,
    int blockEnd,
    int windowSize,
  ) {
    if (position <= anchor) return 0;
    final offset = _history.rep1;
    if (offset <= 0 || offset > windowSize) return 0;
    final candidate = position - offset;
    if (candidate < 0 || position + 4 > blockEnd) return 0;
    if (_read32(data, candidate) != _read32(data, position)) return 0;
    return _countMatch(data, position + 4, candidate + 4, blockEnd) + 4;
  }

  void _insertFastTrailing(
    Uint8List data,
    int position,
    int blockStart,
    int limit,
    int streamBase,
    int hashShift,
    int tableMask,
  ) {
    for (var back = 1; back <= 2; back++) {
      final p = position - back;
      if (p < blockStart || p > limit) continue;
      final hash = _hash(data, p, parameters.minMatch, hashShift) & tableMask;
      _hashTable[hash] = _storedPosition(streamBase + p);
    }
  }

  /// Complementary insertion for the double-fast parser: hash a couple of
  /// positions behind the match end (and two bytes into the match) into both
  /// tables, which libzstd does to keep the tables dense.
  void _insertDoubleFastTrailing(
    Uint8List data,
    int position,
    int matchStart,
    int blockStart,
    int blockEnd,
    int streamBase,
    int longShift,
    int shortShift,
  ) {
    final shortTable = _shortHashTable!;
    final shortMask = shortTable.length - 1;
    final longMask = _hashTable.length - 1;
    final shortLimit = blockEnd - _minimumHashLength;
    final longLimit = blockEnd - 8;
    void insertAt(int p) {
      if (p < blockStart || p >= position) return;
      final value = _storedPosition(streamBase + p);
      if (p <= shortLimit) {
        final shortHash =
            _hash(data, p, parameters.minMatch, shortShift) & shortMask;
        shortTable[shortHash] = value;
      }
      if (p <= longLimit) {
        final longHash = _hash(data, p, 8, longShift) & longMask;
        _hashTable[longHash] = value;
      }
    }

    insertAt(position - 1);
    insertAt(position - 2);
    insertAt(matchStart);
    insertAt(matchStart + 2);
  }

  static int _read32(Uint8List data, int offset) =>
      data[offset] |
      (data[offset + 1] << 8) |
      (data[offset + 2] << 16) |
      (data[offset + 3] << 24);

  static int _countMatch(Uint8List data, int a, int b, int limit) {
    final available = limit - a;
    if (available <= 0) return 0;
    var matched = 0;
    while (matched + 4 <= available) {
      if (_read32(data, a + matched) != _read32(data, b + matched)) break;
      matched += 4;
    }
    while (a + matched < limit && data[a + matched] == data[b + matched]) {
      matched++;
    }
    return matched;
  }

  static int _mul32(int a, int b) {
    final low = (a & 0xFFFF) * b;
    final high = ((a >>> 16) & 0xFFFF) * b;
    return (low + ((high & 0xFFFF) << 16)) & 0xFFFFFFFF;
  }

  /// zstd's 4-byte multiplicative hash, extended to `length` bytes.
  static int _hash(Uint8List data, int p, int length, int shift) {
    final word =
        data[p] |
        (data[p + 1] << 8) |
        (data[p + 2] << 16) |
        (data[p + 3] * 0x1000000);
    var hash = _mul32(word, 0x9E3779B1);
    if (length > 4) {
      var extra = 0;
      for (var i = 4; i < length; i++) {
        extra = (extra << 8) | data[p + i];
      }
      hash = _mul32(hash ^ extra, 0x9E3779B1);
    }
    return hash >>> shift;
  }
}

final class MatchSearchResult {
  const MatchSearchResult(this.length, this.offset);
  final int length;
  final int offset;
}
