import 'dart:typed_data';

import '../common/constants.dart';
import 'sequences.dart';

/// Match-finding strategy used by a compression level.
enum CompressionStrategy {
  /// Single hash table, one candidate per position (levels 1 and 2).
  fast,

  /// Two hash tables (a 4/5-byte "short" and an 8-byte "long" one) per
  /// position (level 3).
  doubleFast,
}

/// The subset of zstd's compression parameters implemented by v0.1.0.
final class CompressionParameters {
  const CompressionParameters({
    required this.windowLog,
    required this.hashLog,
    required this.chainLog,
    required this.minMatch,
    required this.strategy,
  });

  final int windowLog;
  final int hashLog;
  final int chainLog;
  final int minMatch;
  final CompressionStrategy strategy;

  /// Window size implied by [windowLog].
  int get windowSize => 1 << windowLog;

  /// Maximum block size for this window: `min(128 KiB, Window_Size)`.
  int get blockSize =>
      windowSize < zstdBlockSizeMax ? windowSize : zstdBlockSizeMax;
}

/// Chooses the parameters for [level] and an input of [sourceSize] bytes.
///
/// The rows mirror `ZSTD_defaultCParameters` in `clevels.h`: the default table
/// for inputs above 256 KiB, and the progressively smaller window/hash tables
/// for 256 KiB, 128 KiB and 16 KiB inputs. v0.1.0 keeps levels 1-3 to the
/// fast/fast/double-fast strategies.
CompressionParameters compressionParametersFor(int level, int sourceSize) {
  if (level < 1 || level > 3) {
    throw ArgumentError.value(level, 'level', 'must be in 1..3');
  }
  if (sourceSize <= 16 * 1024) {
    return switch (level) {
      1 => const CompressionParameters(
        windowLog: 14,
        hashLog: 15,
        chainLog: 15,
        minMatch: 5,
        strategy: CompressionStrategy.fast,
      ),
      2 => const CompressionParameters(
        windowLog: 14,
        hashLog: 15,
        chainLog: 15,
        minMatch: 4,
        strategy: CompressionStrategy.fast,
      ),
      _ => const CompressionParameters(
        windowLog: 14,
        hashLog: 15,
        chainLog: 14,
        minMatch: 4,
        strategy: CompressionStrategy.doubleFast,
      ),
    };
  }
  if (sourceSize <= 128 * 1024) {
    return switch (level) {
      1 => const CompressionParameters(
        windowLog: 17,
        hashLog: 13,
        chainLog: 13,
        minMatch: 6,
        strategy: CompressionStrategy.fast,
      ),
      2 => const CompressionParameters(
        windowLog: 17,
        hashLog: 15,
        chainLog: 15,
        minMatch: 5,
        strategy: CompressionStrategy.fast,
      ),
      _ => const CompressionParameters(
        windowLog: 17,
        hashLog: 16,
        chainLog: 15,
        minMatch: 4,
        strategy: CompressionStrategy.doubleFast,
      ),
    };
  }
  if (sourceSize <= 256 * 1024) {
    return switch (level) {
      1 => const CompressionParameters(
        windowLog: 18,
        hashLog: 14,
        chainLog: 14,
        minMatch: 6,
        strategy: CompressionStrategy.fast,
      ),
      2 => const CompressionParameters(
        windowLog: 18,
        hashLog: 14,
        chainLog: 14,
        minMatch: 5,
        strategy: CompressionStrategy.fast,
      ),
      _ => const CompressionParameters(
        windowLog: 18,
        hashLog: 16,
        chainLog: 16,
        minMatch: 4,
        strategy: CompressionStrategy.doubleFast,
      ),
    };
  }
  return switch (level) {
    1 => const CompressionParameters(
      windowLog: 19,
      hashLog: 14,
      chainLog: 14,
      minMatch: 7,
      strategy: CompressionStrategy.fast,
    ),
    2 => const CompressionParameters(
      windowLog: 20,
      hashLog: 16,
      chainLog: 16,
      minMatch: 6,
      strategy: CompressionStrategy.fast,
    ),
    _ => const CompressionParameters(
      windowLog: 21,
      hashLog: 17,
      chainLog: 16,
      minMatch: 5,
      strategy: CompressionStrategy.doubleFast,
    ),
  };
}

/// Parameters for a streaming session, where the total input size is unknown.
CompressionParameters compressionParametersForStreaming(int level) =>
    compressionParametersFor(level, 1 << 30);

/// Hash-table based match finder.
///
/// Hash entries store *stream* positions (offset by [_posBase] so they fit in a
/// 32-bit table), which keeps them valid when the streaming encoder slides its
/// buffer window. Entries outside the current window are simply rejected.
final class MatchFinder {
  MatchFinder(this.parameters)
    : _hashTable = Uint32List(1 << parameters.hashLog),
      _shortHashTable = parameters.strategy == CompressionStrategy.doubleFast
          ? Uint32List(1 << parameters.chainLog)
          : null,
      _history = RepeatOffsetHistory();

  final CompressionParameters parameters;
  final Uint32List _hashTable;
  final Uint32List? _shortHashTable;
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
    if (parameters.strategy == CompressionStrategy.doubleFast) {
      _findDoubleFast(data, blockStart, blockEnd, streamBase, store);
    } else {
      _findFast(data, blockStart, blockEnd, streamBase, store);
    }
  }

  /// Makes sure 32-bit hash entries can hold the positions of this block.
  void _ensurePositionCapacity(int blockStartPosition) {
    if (blockStartPosition - _posBase < 0x7F000000) return;
    _hashTable.fillRange(0, _hashTable.length, 0);
    _shortHashTable?.fillRange(0, _shortHashTable.length, 0);
    _posBase = blockStartPosition;
  }

  int _storedPosition(int streamPosition) => streamPosition - _posBase + 1;

  int _candidateLocal(int stored, int streamBase) {
    final candidateStream = stored - 1 + _posBase;
    return candidateStream - streamBase;
  }

  int _candidateOffset(int stored, int currentStream) =>
      currentStream - (stored - 1 + _posBase);

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
    final limit = blockEnd - minMatch;
    if (blockStart > limit) return;

    var ip = blockStart;
    var anchor = blockStart;
    while (ip <= limit) {
      final currentStream = streamBase + ip;
      final hash = _hash(data, ip, minMatch, hashShift) & tableMask;
      final stored = _hashTable[hash];
      _hashTable[hash] = _storedPosition(currentStream);

      // Repeat-offset check: only usable when at least one literal precedes
      // the match (with no literals, Offset_Value 1 means repeat offset 2).
      if (ip > anchor) {
        final repOffset = _history.rep1;
        final repLocal = ip - repOffset;
        if (repOffset > 0 &&
            repOffset <= windowSize &&
            repLocal >= 0 &&
            ip + 4 <= blockEnd &&
            _read32(data, repLocal) == _read32(data, ip)) {
          final length = _countMatch(data, ip + 4, repLocal + 4, blockEnd) + 4;
          final litLength = ip - anchor;
          _history.encodeOffset(litLength, repOffset);
          store.add(litLength, length, repOffset);
          ip += length;
          anchor = ip;
          _insertTrailing(
            data,
            ip,
            blockStart,
            limit,
            streamBase,
            insertLong: false,
          );
          continue;
        }
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
            anchor = ip;
            _insertTrailing(
              data,
              ip,
              blockStart,
              limit,
              streamBase,
              insertLong: false,
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
    final limit = blockEnd - minMatch;
    final longLimit = blockEnd - 8;
    if (blockStart > limit) return;

    var ip = blockStart;
    var anchor = blockStart;
    while (ip <= limit) {
      final currentStream = streamBase + ip;

      // Repeat-offset check.
      if (ip > anchor) {
        final repOffset = _history.rep1;
        final repLocal = ip - repOffset;
        if (repOffset > 0 &&
            repOffset <= windowSize &&
            repLocal >= 0 &&
            ip + 4 <= blockEnd &&
            _read32(data, repLocal) == _read32(data, ip)) {
          final length = _countMatch(data, ip + 4, repLocal + 4, blockEnd) + 4;
          final litLength = ip - anchor;
          _history.encodeOffset(litLength, repOffset);
          store.add(litLength, length, repOffset);
          ip += length;
          anchor = ip;
          _insertTrailing(
            data,
            ip,
            blockStart,
            limit,
            streamBase,
            insertLong: true,
          );
          continue;
        }
      }

      var bestLength = 0;
      var bestOffset = 0;
      var bestCandidate = 0;

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

      if (bestLength >= 4) {
        var matchStart = ip;
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
        anchor = ip;
        _insertTrailing(
          data,
          ip,
          blockStart,
          limit,
          streamBase,
          insertLong: true,
        );
        continue;
      }
      ip++;
    }
  }

  /// Hashes the last two positions of a match so later matches can find them.
  void _insertTrailing(
    Uint8List data,
    int position,
    int blockStart,
    int limit,
    int streamBase, {
    required bool insertLong,
  }) {
    final minMatch = parameters.minMatch;
    final shortShift = 32 - parameters.chainLog;
    final shortTable = _shortHashTable ?? _hashTable;
    final shortMask = shortTable.length - 1;
    final longShift = 32 - parameters.hashLog;
    final longMask = _hashTable.length - 1;
    for (var back = 1; back <= 2; back++) {
      final p = position - back;
      if (p < blockStart) continue;
      if (p <= limit) {
        final shortHash = _hash(data, p, minMatch, shortShift) & shortMask;
        shortTable[shortHash] = _storedPosition(streamBase + p);
      }
      if (insertLong && p <= limit - (8 - minMatch)) {
        final longHash = _hash(data, p, 8, longShift) & longMask;
        _hashTable[longHash] = _storedPosition(streamBase + p);
      }
    }
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
