import 'dart:typed_data';

import '../../common/constants.dart';
import 'hash_native.dart'
    if (dart.library.js_interop) 'hash_web.dart'
    as hashes;
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
  if (level <= 8) return CompressionStrategy.lazy;
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
  // The depth is capped: beyond 256 attempts per position the ratio gain is
  // far below 0.1% while chain-heavy inputs pay for every attempt.
  var searchLog = row.$4;
  if (level >= 10 && strategy == CompressionStrategy.lazy2) {
    var boosted = 5 + (level - 9);
    if (boosted > 8) boosted = 8;
    if (boosted > searchLog) searchLog = boosted;
  }
  // Level 9 uses 16 chain attempts instead of 32. This costs ~0.5% ratio on
  // the benchmark corpora (inside the v0.1.2 regression budget) but removes
  // most of the level's chain-search overhead.
  if (level == 9 && strategy == CompressionStrategy.lazy2 && searchLog > 4) {
    searchLog = 4;
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

  /// Fills [store] with the matches found in `data[blockStart..blockEnd)`.
  ///
  /// `data[0..blockStart)` is history available for back-references.
  /// [startRepCodes] is the repeat-offset history at the start of the block.
  /// Positions are local to `data` (v2 buffers whole inputs, so no rebasing
  /// is needed).
  void findMatches(
    Uint8List data,
    int blockStart,
    int blockEnd,
    List<int> startRepCodes,
    SequenceStore store,
  ) {
    if (blockEnd - blockStart < 4) return;
    _history.restore(startRepCodes);
    _dataView = ByteData.sublistView(data);
    switch (parameters.strategy) {
      case CompressionStrategy.fast:
        _findFast(data, blockStart, blockEnd, store);
      case CompressionStrategy.doubleFast:
        _findDoubleFast(data, blockStart, blockEnd, store);
      case CompressionStrategy.greedy:
        _findChain(data, blockStart, blockEnd, store, lazy: false);
      case CompressionStrategy.lazy:
        _findChain(data, blockStart, blockEnd, store, lazy: true);
      case CompressionStrategy.lazy2:
        _findChain(data, blockStart, blockEnd, store, lazy: true);
    }
  }

  /// Indexes a prefix (dictionary content) so that later blocks can match it.
  void loadPrefix(Uint8List data, int start, int end) {
    if (end <= start) return;
    _dataView = ByteData.sublistView(data);
    final minLength = _minimumHashLength;
    final hashShift = 32 - parameters.hashLog;
    final hashMask = _hashTable.length - 1;
    final doubleFast = parameters.strategy == CompressionStrategy.doubleFast;
    final shortShift = 32 - parameters.chainLog;
    final shortTable = _shortHashTable;
    final shortMask = shortTable == null ? 0 : shortTable.length - 1;
    final chainTable = _chainTable;
    final chainMask = chainTable == null ? 0 : chainTable.length - 1;
    for (var p = start; p + 8 <= end; p++) {
      final value = p + 1;
      if (doubleFast) {
        if (p + 8 <= end) {
          final longHash = _hashAt(p, 8, hashShift) & hashMask;
          _hashTable[longHash] = value;
        }
        final shortHash = _hashAt(p, minLength, shortShift) & shortMask;
        shortTable![shortHash] = value;
      } else {
        final hash = _hashAt(p, minLength, hashShift) & hashMask;
        final previous = _hashTable[hash];
        _hashTable[hash] = value;
        if (chainTable != null) {
          chainTable[p & chainMask] = previous;
        }
      }
    }
  }

  int get _minimumHashLength =>
      parameters.minMatch < 4 ? 4 : parameters.minMatch;

  /// Hash of the [length] (4..8) bytes at [position].
  ///
  /// Reads whole 32-bit words through the cached [ByteData] view; for 5..7
  /// byte matches the few extra bytes are folded in directly.
  @pragma('vm:prefer-inline')
  int _hashAt(int position, int length, int shift) {
    final word = _read32(position);
    switch (length) {
      case 4:
        return hashes.hash4(word, shift);
      case 5:
        return hashes.hash5(word, _read32(position + 4), shift);
      case 6:
        return hashes.hash6(word, _read32(position + 4), shift);
      case 7:
        return hashes.hash7(word, _read32(position + 4), shift);
      default:
        return hashes.hash8(word, _read32(position + 4), shift);
    }
  }

  void _findFast(
    Uint8List data,
    int blockStart,
    int blockEnd,
    SequenceStore store,
  ) {
    final minMatch = parameters.minMatch;
    final hashShift = 32 - parameters.hashLog;
    final tableMask = _hashTable.length - 1;
    final windowSize = parameters.windowSize;
    final limit = blockEnd - 8;
    if (blockStart > limit) return;

    var ip = blockStart;
    var anchor = blockStart;
    while (ip <= limit) {
      final hash = _hashAt(ip, minMatch, hashShift) & tableMask;
      final stored = _hashTable[hash];
      _hashTable[hash] = ip + 1;

      final repLength = _repCodeMatch(data, ip, anchor, blockEnd, windowSize);
      if (repLength > 0) {
        final litLength = ip - anchor;
        final offset = _history.rep1;
        _history.encodeOffset(litLength, offset);
        store.add(litLength, repLength, offset);
        ip += repLength;
        ip = _storeImmediateReps(data, ip, blockEnd, windowSize, store);
        anchor = ip;
        _insertFastTrailing(data, ip, blockStart, limit, hashShift, tableMask);
        continue;
      }

      if (stored != 0) {
        final offset = ip - stored + 1;
        if (offset > 0 && offset <= windowSize) {
          final candidate = stored - 1;
          if (candidate >= 0 && _read32(candidate) == _read32(ip)) {
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
    SequenceStore store,
  ) {
    final longShift = 32 - parameters.hashLog;
    final shortShift = 32 - parameters.chainLog;
    final longTableMask = _hashTable.length - 1;
    final shortTable = _shortHashTable!;
    final shortTableMask = shortTable.length - 1;
    final windowSize = parameters.windowSize;
    final limit = blockEnd - 8;
    final longLimit = blockEnd - 8;
    if (blockStart > limit) return;
    final shortHashLength = parameters.minMatch;

    var ip = blockStart;
    var anchor = blockStart;
    while (ip <= limit) {
      final currentRel = ip;

      var bestLength = 0;
      var bestOffset = 0;
      var bestCandidate = 0;
      var bestStart = ip;
      final position32 = _read32(ip);

      if (ip <= longLimit) {
        final longHash =
            hashes.hash8(position32, _read32(ip + 4), longShift) &
            longTableMask;
        final storedLong = _hashTable[longHash];
        _hashTable[longHash] = currentRel + 1;
        if (storedLong != 0) {
          final offset = currentRel - storedLong + 1;
          if (offset > 0 && offset <= windowSize) {
            final candidate = storedLong - 1;
            if (candidate >= 0 &&
                _read32(candidate) == position32 &&
                _read32(candidate + 4) == _read32(ip + 4)) {
              bestLength =
                  _countMatch(data, ip + 8, candidate + 8, blockEnd) + 8;
              bestOffset = offset;
              bestCandidate = candidate;
            }
          }
        }
      }

      final int shortHash;
      if (shortHashLength == 4) {
        shortHash = hashes.hash4(position32, shortShift) & shortTableMask;
      } else {
        shortHash =
            (shortHashLength == 5
                ? hashes.hash5(position32, _read32(ip + 4), shortShift)
                : hashes.hash6(position32, _read32(ip + 4), shortShift)) &
            shortTableMask;
      }
      final storedShort = shortTable[shortHash];
      shortTable[shortHash] = currentRel + 1;
      if (storedShort != 0) {
        final offset = currentRel - storedShort + 1;
        if (offset > 0 && offset <= windowSize) {
          final candidate = storedShort - 1;
          if (candidate >= 0 && _read32(candidate) == position32) {
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
          longShift,
          shortShift,
        );
        continue;
      }
      // Only in literal runs, try the previous offset: this keeps the hot
      // match-rich path free of the extra repeat-offset comparison.
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
          longShift,
          shortShift,
        );
        continue;
      }
      // No match: like libzstd's fast parsers, skip further ahead as the
      // current literal run grows. This keeps incompressible regions cheap
      // while leaving compressible data's step at one or two bytes.
      ip += ((ip - anchor) >> 8) + 1;
    }
  }

  void _findChain(
    Uint8List data,
    int blockStart,
    int blockEnd,
    SequenceStore store, {
    required bool lazy,
  }) {
    final parameters = this.parameters;
    final hashShift = 32 - parameters.hashLog;
    final hashMask = _hashTable.length - 1;
    final chainTable = _chainTable!;
    final chainMask = chainTable.length - 1;
    final windowSize = parameters.windowSize;
    final limit = blockEnd - 8;
    if (blockStart > limit) return;
    final chainLazy = lazy;
    final lazy2 = parameters.strategy == CompressionStrategy.lazy2;
    final searchDepth = parameters.searchDepth;
    final hashLength = _minimumHashLength;
    final history = _history;
    final hashTable = _hashTable;
    final maxDepth = chainLazy ? (lazy2 ? 2 : 1) : 0;

    var ip = blockStart;
    var anchor = blockStart;
    var nextToInsert = blockStart;

    while (ip <= limit) {
      var bestLength = 0;
      var bestOffset = 0;
      var bestPosition = ip;
      var position = ip;
      var depth = 0;

      while (true) {
        // Insert every position skipped since the last search, like libzstd's
        // ZSTD_insertAndFindFirstIndex: this keeps chains dense after long
        // matches, which is essential for ratio.
        while (nextToInsert < position && nextToInsert <= limit) {
          final insertRel = nextToInsert;
          final insertHash =
              _hashAt(nextToInsert, hashLength, hashShift) & hashMask;
          final insertPrevious = hashTable[insertHash];
          hashTable[insertHash] = insertRel + 1;
          chainTable[insertRel & chainMask] = insertPrevious;
          nextToInsert++;
        }
        if (nextToInsert < position) nextToInsert = position;

        final currentRel = position;
        final hash = _hashAt(position, hashLength, hashShift) & hashMask;
        final previous = hashTable[hash];
        hashTable[hash] = currentRel + 1;
        chainTable[currentRel & chainMask] = previous;
        nextToInsert = position + 1;

        var candidateLength = 0;
        var candidateOffset = 0;
        var candidate = previous;
        var attempts = searchDepth;
        final maxLength = blockEnd - position;
        while (attempts-- > 0 && candidate != 0) {
          final offset = currentRel - candidate + 1;
          if (offset <= 0 || offset > windowSize) break;
          final candidateLocal = candidate - 1;
          if (candidateLocal < 0) break;
          // Cheap rejection: a candidate that cannot extend past the current
          // best by more than a few bytes is not worth a full comparison.
          // The four-byte probe may match on a hash collision, so the full
          // comparison must start at position 0, not at position + 4.
          if (candidateLength == 0) {
            if (_read32(candidateLocal) == _read32(position)) {
              final length = _countMatch(
                data,
                position,
                candidateLocal,
                blockEnd,
              );
              if (length > candidateLength) {
                candidateLength = length;
                candidateOffset = offset;
                if (length >= maxLength) break;
              }
            }
          } else {
            final probe = position + candidateLength - 3;
            if (probe + 4 <= blockEnd &&
                _read32(candidateLocal + candidateLength - 3) ==
                    _read32(probe)) {
              final length = _countMatch(
                data,
                position,
                candidateLocal,
                blockEnd,
              );
              if (length > candidateLength) {
                candidateLength = length;
                candidateOffset = offset;
                if (length >= maxLength) break;
              }
            }
          }
          final next = chainTable[(candidate - 1) & chainMask];
          if (next == 0) break;
          if (next >= candidate) break;
          candidate = next;
        }

        if (depth == 0) {
          bestLength = candidateLength;
          bestOffset = candidateOffset;
          final repLength = _repCodeMatch(
            data,
            position,
            anchor,
            blockEnd,
            windowSize,
          );
          if (repLength >= 4 &&
              repLength * 3 > _repGainAgainst(bestLength, bestOffset)) {
            bestLength = repLength;
            bestOffset = history.rep1;
          }
          if (bestLength < 4 || maxDepth == 0) break;
        } else {
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
            bestOffset = history.rep1;
            bestPosition = position;
            improved = true;
          }
          if (candidateLength >= 4 &&
              candidateLength * 4 - _highBit32(candidateOffset) >
                  _hashGainAgainst(bestLength, bestOffset)) {
            bestLength = candidateLength;
            bestOffset = candidateOffset;
            bestPosition = position;
            improved = true;
          }
          if (!improved) break;
        }

        depth++;
        if (depth > maxDepth) break;
        position = ip + depth;
        if (position > limit) break;
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
      history.encodeOffset(litLength, bestOffset);
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
      if (_read32(candidate) != _read32(ip)) break;
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
    if (_read32(candidate) != _read32(position)) return 0;
    return _countMatch(data, position + 4, candidate + 4, blockEnd) + 4;
  }

  void _insertFastTrailing(
    Uint8List data,
    int position,
    int blockStart,
    int limit,
    int hashShift,
    int tableMask,
  ) {
    final hashLength = _minimumHashLength;
    final hashTable = _hashTable;
    for (var back = 1; back <= 2; back++) {
      final p = position - back;
      if (p < blockStart || p > limit) continue;
      final hash = _hashAt(p, hashLength, hashShift) & tableMask;
      hashTable[hash] = p + 1;
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
    int longShift,
    int shortShift,
  ) {
    final shortTable = _shortHashTable!;
    final shortMask = shortTable.length - 1;
    final longTable = _hashTable;
    final longMask = longTable.length - 1;
    final shortLimit = blockEnd - 8;
    final longLimit = blockEnd - 8;
    final shortHashLength = parameters.minMatch;
    final candidate0 = position - 1;
    final candidate1 = position - 2;
    final candidate2 = matchStart;
    final candidate3 = matchStart + 2;
    for (var index = 0; index < 4; index++) {
      final p = index == 0
          ? candidate0
          : (index == 1 ? candidate1 : (index == 2 ? candidate2 : candidate3));
      if (p < blockStart || p >= position) continue;
      final value = p + 1;
      if (p <= shortLimit && (index == 0 || index == 3)) {
        final shortHash = _hashAt(p, shortHashLength, shortShift) & shortMask;
        shortTable[shortHash] = value;
      }
      if (p <= longLimit) {
        final longHash = _hashAt(p, 8, longShift) & longMask;
        longTable[longHash] = value;
      }
    }
  }

  ByteData? _dataView;

  @pragma('vm:prefer-inline')
  int _read32(int offset) => _dataView!.getUint32(offset, Endian.little);

  @pragma('vm:prefer-inline')
  int _countMatch(Uint8List data, int a, int b, int limit) {
    final available = limit - a;
    if (available <= 0) return 0;
    var matched = 0;
    while (matched + 4 <= available) {
      if (_read32(a + matched) != _read32(b + matched)) break;
      matched += 4;
    }
    while (a + matched < limit && data[a + matched] == data[b + matched]) {
      matched++;
    }
    return matched;
  }
}
