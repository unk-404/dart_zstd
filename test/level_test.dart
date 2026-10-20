import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zstd_neo/zstd_neo.dart';

import 'fixtures/fixtures.g.dart';

/// Level coverage for the v0.1.1 encoder: levels 1..19, ratio behaviour and
/// dictionary encoding. Web-safe (no `dart:io`).
void main() {
  group('levels 1..19', () {
    test('one-shot round-trip at every level', () {
      final input = _wordyText(16 * 1024);
      for (var level = 1; level <= 19; level++) {
        final frame = ZstdEncoder(level: level).compress(input);
        expect(_startsWithMagic(frame), isTrue, reason: 'level $level');
        expect(
          ZstdDecoder().decompress(frame),
          input,
          reason: 'level $level round-trip',
        );
      }
    });

    test('streaming round-trip at every level', () {
      final input = _wordyText(8 * 1024);
      for (var level = 1; level <= 19; level++) {
        for (final split in <int>[7, 999]) {
          final collector = _CollectSink();
          final sink = ZstdEncoder(level: level)
              .startChunkedConversion(collector);
          for (var i = 0; i < input.length; i += split) {
            final end = i + split < input.length ? i + split : input.length;
            sink.add(Uint8List.sublistView(input, i, end));
          }
          sink.close();
          expect(
            ZstdDecoder().decompress(collector.toBytes()),
            input,
            reason: 'level $level split $split',
          );
        }
      }
    });

    test('invalid levels are rejected, 1..19 accepted', () {
      expect(() => ZstdEncoder(level: 0), throwsArgumentError);
      expect(() => ZstdEncoder(level: -1), throwsArgumentError);
      expect(() => ZstdEncoder(level: 20), throwsArgumentError);
      for (final level in <int>[1, 9, 10, 19]) {
        expect(ZstdEncoder(level: level), isA<ZstdEncoder>());
      }
    });

    test('higher levels improve on level 9', () {
      final input = _wordyText(64 * 1024);
      final level9 = ZstdEncoder(level: 9).compress(input).length;
      for (var level = 10; level <= 19; level++) {
        final size = ZstdEncoder(level: level).compress(input).length;
        expect(
          size,
          lessThanOrEqualTo(level9),
          reason: 'level $level should not be worse than level 9',
        );
      }
      final level19 = ZstdEncoder(level: 19).compress(input).length;
      expect(level19, lessThan(level9), reason: 'level 19 must beat level 9');
    });

    test('ratio improves as the level grows', () {
      final input = _wordyText(64 * 1024);
      final sizes = <int>[
        for (final level in <int>[1, 3, 9, 19])
          ZstdEncoder(level: level).compress(input).length,
      ];
      expect(sizes[1], lessThanOrEqualTo(sizes[0]));
      expect(sizes[2], lessThanOrEqualTo(sizes[1]));
      expect(sizes[3], lessThan(sizes[2]));
    });

    test('L3 and L9 are within ~5% of libzstd on a text corpus', () {
      // Reference sizes were produced by libzstd 1.5.7 through
      // benchmark/rust_ref (`encode --level N`) on exactly this deterministic
      // input. If the generator changes, refresh these constants.
      final input = _wordyText(64 * 1024);
      _expectNearReference(input, level: 3, referenceSize: 24673);
      _expectNearReference(input, level: 9, referenceSize: 23701);

      final small = _wordyText(16 * 1024);
      _expectNearReference(small, level: 3, referenceSize: 6441);
      _expectNearReference(small, level: 9, referenceSize: 6159);
    });
  });

  group('dictionary encoding', () {
    for (final name in <String>['rawdict', 'structdict']) {
      test('$name dictionary one-shot and streaming round-trip', () {
        final fixture = webFixtures.firstWhere((f) => f.name == name);
        final dictionary = base64Decode(fixture.dictBase64!);
        final plain = base64Decode(fixture.binBase64);
        expect(plain.length, fixture.binLength);

        for (final level in <int>[3, 9]) {
          final frame = ZstdEncoder(
            level: level,
            checksum: true,
            dictionary: dictionary,
          ).compress(plain);
          expect(_startsWithMagic(frame), isTrue);
          expect(
            ZstdDecoder(dictionary: dictionary).decompress(frame),
            plain,
            reason: '$name level $level',
          );
        }

        // Streaming with a dictionary as well.
        final collector = _CollectSink();
        final sink = ZstdEncoder(
          level: 3,
          dictionary: dictionary,
        ).startChunkedConversion(collector);
        for (var i = 0; i < plain.length; i += 1000) {
          final end = i + 1000 < plain.length ? i + 1000 : plain.length;
          sink.add(Uint8List.sublistView(plain, i, end));
        }
        sink.close();
        expect(
          ZstdDecoder(dictionary: dictionary).decompress(collector.toBytes()),
          plain,
        );
      });

      test('$name dictionary improves the ratio', () {
        final fixture = webFixtures.firstWhere((f) => f.name == name);
        final dictionary = base64Decode(fixture.dictBase64!);
        final plain = base64Decode(fixture.binBase64);
        final withDictionary = ZstdEncoder(
          level: 3,
          dictionary: dictionary,
        ).compress(plain).length;
        final withoutDictionary = ZstdEncoder(level: 3).compress(plain).length;
        expect(withDictionary, lessThan(withoutDictionary));
      });
    }

    test('dictionary ids are written and required on decode', () {
      final raw = webFixtures.firstWhere((f) => f.name == 'rawdict');
      final rawDictionary = base64Decode(raw.dictBase64!);
      final rawPlain = base64Decode(raw.binBase64);
      final rawFrame = ZstdEncoder(
        level: 3,
        checksum: true,
        dictionary: rawDictionary,
      ).compress(rawPlain);
      expect(_frameDictionaryIdFlag(rawFrame), 0, reason: 'raw dict has no id');
      expect(
        () => ZstdDecoder().decompress(rawFrame),
        throwsA(isA<ZstdException>()),
        reason: 'checksum must fail without the raw dictionary',
      );

      final structured = webFixtures.firstWhere((f) => f.name == 'structdict');
      final structuredDictionary = base64Decode(structured.dictBase64!);
      final structuredPlain = base64Decode(structured.binBase64);
      final structuredFrame = ZstdEncoder(
        level: 3,
        checksum: true,
        dictionary: structuredDictionary,
      ).compress(structuredPlain);
      final flag = _frameDictionaryIdFlag(structuredFrame);
      expect(flag, isNot(0), reason: 'formatted dict id must be written');
      final declaredId = _frameDictionaryId(structuredFrame);
      final expectedId = _readLe32(structuredDictionary, 4);
      expect(declaredId, expectedId);
      expect(
        () => ZstdDecoder().decompress(structuredFrame),
        throwsA(isA<ZstdException>()),
        reason: 'structured dictionary must be required',
      );
    });
  });
}

void _expectNearReference(
  Uint8List input, {
  required int level,
  required int referenceSize,
}) {
  final size = ZstdEncoder(level: level).compress(input).length;
  final limit = (referenceSize * 1.05).ceil();
  expect(
    size,
    lessThanOrEqualTo(limit),
    reason:
        'level $level: $size bytes vs libzstd reference $referenceSize '
        '(limit $limit)',
  );
}

bool _startsWithMagic(Uint8List frame) =>
    frame.length >= 4 &&
    frame[0] == 0x28 &&
    frame[1] == 0xB5 &&
    frame[2] == 0x2F &&
    frame[3] == 0xFD;

/// Byte offset of the dictionary id field, or -1 when absent.
int _dictionaryIdOffset(Uint8List frame) {
  final descriptor = frame[4];
  final singleSegment = (descriptor & 0x20) != 0;
  final flag = descriptor & 3;
  if (flag == 0) return -1;
  var position = 5;
  if (!singleSegment) position++;
  return position;
}

int _frameDictionaryIdFlag(Uint8List frame) => frame[4] & 3;

int _frameDictionaryId(Uint8List frame) {
  final offset = _dictionaryIdOffset(frame);
  expect(offset, isNot(-1));
  switch (_frameDictionaryIdFlag(frame)) {
    case 1:
      return frame[offset];
    case 2:
      return frame[offset] | (frame[offset + 1] << 8);
    default:
      return _readLe32(frame, offset);
  }
}

int _readLe32(Uint8List data, int offset) =>
    data[offset] |
    (data[offset + 1] << 8) |
    (data[offset + 2] << 16) |
    (data[offset + 3] << 24);

final class _CollectSink implements Sink<List<int>> {
  final List<List<int>> chunks = <List<int>>[];

  @override
  void add(List<int> data) {
    chunks.add(data);
  }

  @override
  void close() {}

  Uint8List toBytes() {
    var length = 0;
    for (final chunk in chunks) {
      length += chunk.length;
    }
    final out = Uint8List(length);
    var offset = 0;
    for (final chunk in chunks) {
      out.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return out;
  }
}

// --- Deterministic corpus ---------------------------------------------------
//
// This generator must stay byte-identical to the one used to produce the
// reference sizes above (libzstd 1.5.7 through benchmark/rust_ref).

const List<String> _words = <String>[
  'the',
  'of',
  'and',
  'to',
  'in',
  'a',
  'is',
  'that',
  'for',
  'it',
  'as',
  'with',
  'was',
  'on',
  'be',
  'at',
  'by',
  'this',
  'had',
  'not',
  'are',
  'but',
  'from',
  'or',
  'have',
  'an',
  'they',
  'which',
  'one',
  'you',
  'were',
  'her',
  'all',
  'she',
  'there',
  'would',
  'their',
  'we',
  'him',
  'been',
  'has',
  'when',
  'who',
  'will',
  'more',
  'no',
  'if',
  'out',
  'so',
  'said',
  'what',
  'up',
  'its',
  'about',
  'into',
  'than',
  'them',
  'can',
  'only',
  'other',
  'new',
  'some',
  'could',
  'time',
  'these',
  'two',
  'may',
  'then',
  'do',
  'first',
  'any',
  'my',
  'now',
  'such',
  'like',
  'our',
  'over',
  'man',
  'me',
  'even',
  'most',
  'made',
  'after',
  'also',
  'did',
  'many',
  'before',
  'must',
  'through',
  'back',
  'years',
  'where',
  'much',
  'your',
  'way',
  'well',
  'down',
  'should',
  'because',
  'each',
  'just',
  'those',
  'people',
  'mr',
  'how',
  'too',
  'little',
  'state',
  'good',
  'very',
  'make',
  'world',
  'still',
  'own',
  'see',
  'men',
  'work',
  'long',
  'get',
  'here',
  'between',
  'both',
  'life',
  'being',
  'under',
  'never',
  'day',
  'same',
  'another',
  'know',
  'while',
  'last',
  'might',
  'us',
  'great',
  'old',
  'year',
  'off',
  'come',
  'since',
  'against',
  'go',
  'came',
  'right',
  'used',
  'take',
  'three',
];

int _nextState(int state) => (state * 48271) % 2147483647;

Uint8List _wordyText(int size, {int seed = 12345}) {
  final out = Uint8List(size);
  var position = 0;
  var state = seed;
  while (position < size) {
    state = _nextState(state);
    final word = _words[state % _words.length];
    for (var i = 0; i < word.length && position < size; i++) {
      out[position++] = word.codeUnitAt(i);
    }
    if (position < size) {
      state = _nextState(state);
      out[position++] = (state & 0x100) == 0 ? 0x20 : 0x0A;
    }
  }
  return out;
}
