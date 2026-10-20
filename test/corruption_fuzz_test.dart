// Corruption fuzzing for the pure-Dart Zstandard decoder.
//
// This file runs on every platform (VM, dart2js, dart2wasm): it only imports
// `dart:convert` / `dart:typed_data`, and all reference frames come from the
// base64 constants in `test/fixtures/fixtures.g.dart`.
//
// Invariant under test: arbitrary corrupt input either decodes successfully or
// throws `ZstdException` (any error code). No other exception type may escape,
// and decoding must terminate (package:test enforces the per-test timeout).

import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zstd_neo/zstd_neo.dart';

import 'fixtures/fixtures.g.dart';

const List<int> _chunkSizes = <int>[1, 7, 31, 1000, 65536];
const int _maxFindings = 15;

final class _FrameInput {
  const _FrameInput(this.name, this.bytes, this.plaintext, this.dictionary);

  final String name;
  final Uint8List bytes;
  final Uint8List? plaintext;
  final Uint8List? dictionary;
}

/// Deterministic xorshift32 PRNG, so a failing mutation can be reproduced.
final class _SeededRandom {
  _SeededRandom(int seed)
    : _state = (seed == 0 ? 0x9e3779b9 : seed & 0xFFFFFFFF);

  int _state;

  int nextUint32() {
    var x = _state;
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    _state = x & 0xFFFFFFFF;
    return _state;
  }

  int nextInt(int max) => max <= 0 ? 0 : nextUint32() % max;
}

void main() {
  final valid = <_FrameInput>[
    for (final fixture in webFixtures)
      _FrameInput(
        fixture.name,
        base64Decode(fixture.zstBase64),
        base64Decode(fixture.binBase64),
        fixture.dictBase64 == null ? null : base64Decode(fixture.dictBase64!),
      ),
  ];
  final malformed = <_FrameInput>[
    for (final fixture in malformedFixtures)
      _FrameInput(fixture.name, base64Decode(fixture.zstBase64), null, null),
  ];

  test('valid fixtures decode as expected (precondition)', () {
    expect(valid, isNotEmpty);
    for (final input in valid) {
      final decoded = ZstdDecoder(dictionary: input.dictionary)
          .decompress(input.bytes);
      expect(decoded, equals(input.plaintext), reason: input.name);
    }
  });

  test('bit-flipped frames only throw ZstdException', () {
    final findings = <String>[];
    final random = _SeededRandom(0x5b17);
    for (final input in valid) {
      for (var mutation = 0; mutation < 8; mutation++) {
        final mutated = _flipBits(input.bytes, random);
        _decodeOneShot(
          input: mutated,
          dictionary: input.dictionary,
          description: '${input.name} bit-flip #$mutation',
          findings: findings,
        );
        if (findings.length >= _maxFindings) break;
      }
      if (findings.length >= _maxFindings) break;
    }
    expect(findings, isEmpty, reason: findings.join('\n'));
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('truncated frames only throw ZstdException', () {
    final findings = <String>[];
    final random = _SeededRandom(0x7e11);
    for (final input in valid) {
      // Cutting a concatenated or skippable stream right after a complete
      // inner frame yields a valid, shorter stream; those fixtures are checked
      // with the permissive rule only.
      final strict = !_isConcatenated(input.name);
      final last = input.bytes.length - 1;
      if (last >= 0) {
        // Dropping the final byte always leaves a frame mid-stream.
        _decodeOneShot(
          input: Uint8List.sublistView(input.bytes, 0, last),
          dictionary: input.dictionary,
          description: '${input.name} truncated at $last',
          findings: findings,
          mustThrow: strict,
        );
      }
      final cuts = input.bytes.length <= 256
          ? List<int>.generate(input.bytes.length, (index) => index)
          : <int>[
              for (var sample = 0; sample < 16; sample++)
                random.nextInt(input.bytes.length),
            ];
      for (final cut in cuts) {
        _decodeOneShot(
          input: Uint8List.sublistView(input.bytes, 0, cut),
          dictionary: input.dictionary,
          description: '${input.name} truncated at $cut',
          findings: findings,
          mustThrow: strict,
        );
        if (findings.length >= _maxFindings) break;
      }
      if (findings.length >= _maxFindings) break;
    }
    expect(findings, isEmpty, reason: findings.join('\n'));
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('frames with appended random bytes only throw ZstdException', () {
    final findings = <String>[];
    final random = _SeededRandom(0xa99e);
    for (final input in valid) {
      for (var mutation = 0; mutation < 8; mutation++) {
        final mutated = _appendRandom(input.bytes, random);
        _decodeOneShot(
          input: mutated,
          dictionary: input.dictionary,
          description: '${input.name} appended #$mutation',
          findings: findings,
          mustThrow: true,
        );
        if (findings.length >= _maxFindings) break;
      }
      if (findings.length >= _maxFindings) break;
    }
    expect(findings, isEmpty, reason: findings.join('\n'));
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('random byte buffers only throw ZstdException', () {
    final findings = <String>[];
    final random = _SeededRandom(0x60de);
    for (var index = 0; index < 120; index++) {
      final length = random.nextInt(384);
      final bytes = Uint8List(length);
      for (var i = 0; i < length; i++) {
        bytes[i] = random.nextInt(256);
      }
      _decodeOneShot(
        input: bytes,
        dictionary: null,
        description: 'random buffer #$index (length=$length)',
        findings: findings,
        mustThrow: true,
      );
      if (findings.length >= _maxFindings) break;
    }
    expect(findings, isEmpty, reason: findings.join('\n'));
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('streaming decode of corrupt frames only throws ZstdException', () {
    final findings = <String>[];
    final random = _SeededRandom(0x510a);
    var chunkVariant = 0;
    for (final input in valid) {
      final mutations = <String, Uint8List>{
        'bit-flip': _flipBits(input.bytes, random),
        'truncated': _truncate(input.bytes, random),
        'appended': _appendRandom(input.bytes, random),
      };
      for (final entry in mutations.entries) {
        final chunkSize = _chunkSizes[chunkVariant % _chunkSizes.length];
        chunkVariant++;
        _decodeStreaming(
          input: entry.value,
          dictionary: input.dictionary,
          chunkSize: chunkSize,
          description: '${input.name} ${entry.key} (chunk=$chunkSize)',
          findings: findings,
        );
        if (findings.length >= _maxFindings) break;
      }
      if (findings.length >= _maxFindings) break;
    }
    // Streaming random buffers must fail cleanly too.
    for (var index = 0; index < 30; index++) {
      final length = random.nextInt(128);
      final bytes = Uint8List(length);
      for (var i = 0; i < length; i++) {
        bytes[i] = random.nextInt(256);
      }
      final chunkSize = _chunkSizes[chunkVariant % _chunkSizes.length];
      chunkVariant++;
      _decodeStreaming(
        input: bytes,
        dictionary: null,
        chunkSize: chunkSize,
        description: 'random streaming buffer #$index (length=$length)',
        findings: findings,
        mustThrow: true,
      );
      if (findings.length >= _maxFindings) break;
    }
    expect(findings, isEmpty, reason: findings.join('\n'));
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('corrupted checksum is reported as checksumMismatch', () {
    final fixture = webFixtures.firstWhere(
      (candidate) => candidate.name == 'text_4k_checksum',
    );
    final bytes = Uint8List.fromList(base64Decode(fixture.zstBase64));
    bytes[bytes.length - 1] ^= 0xFF;
    expect(
      () => ZstdDecoder().decompress(bytes),
      throwsA(
        isA<ZstdException>().having(
          (error) => error.code,
          'code',
          ZstdErrorCode.checksumMismatch,
        ),
      ),
    );
  });

  test('malformed fixtures throw ZstdException', () {
    expect(malformed, isNotEmpty);
    final findings = <String>[];
    for (final input in malformed) {
      _decodeOneShot(
        input: input.bytes,
        dictionary: null,
        description: 'malformed ${input.name}',
        findings: findings,
        mustThrow: true,
      );
    }
    expect(findings, isEmpty, reason: findings.join('\n'));
  });
}

bool _isConcatenated(String name) =>
    name.contains('multiframe') || name.contains('skippable');

Uint8List _flipBits(Uint8List source, _SeededRandom random) {
  if (source.isEmpty) return Uint8List(0);
  final out = Uint8List.fromList(source);
  final flips = 1 + random.nextInt(4);
  for (var i = 0; i < flips; i++) {
    final at = random.nextInt(out.length);
    out[at] ^= 1 << random.nextInt(8);
  }
  return out;
}

Uint8List _truncate(Uint8List source, _SeededRandom random) {
  if (source.isEmpty) return Uint8List(0);
  return Uint8List.sublistView(source, 0, random.nextInt(source.length));
}

Uint8List _appendRandom(Uint8List source, _SeededRandom random) {
  final extra = 1 + random.nextInt(16);
  final out = Uint8List(source.length + extra);
  out.setRange(0, source.length, source);
  for (var i = 0; i < extra; i++) {
    out[source.length + i] = random.nextInt(256);
  }
  return out;
}

void _decodeOneShot({
  required Uint8List input,
  required Uint8List? dictionary,
  required String description,
  required List<String> findings,
  bool mustThrow = false,
}) {
  try {
    ZstdDecoder(dictionary: dictionary).decompress(input);
    if (mustThrow) {
      findings.add(
        '$description: decoded successfully, expected ZstdException',
      );
    }
  } on ZstdException {
    // The only acceptable failure mode for corrupt input.
  } catch (error, stack) {
    findings.add(
      '$description: threw ${error.runtimeType}: $error\n'
      '${_stackHead(stack)}',
    );
  }
}

void _decodeStreaming({
  required Uint8List input,
  required Uint8List? dictionary,
  required int chunkSize,
  required String description,
  required List<String> findings,
  bool mustThrow = false,
}) {
  try {
    final builder = BytesBuilder(copy: false);
    final sink = ZstdDecoder(dictionary: dictionary)
        .startChunkedConversion(ByteConversionSink.withCallback(builder.add));
    for (var offset = 0; offset < input.length; offset += chunkSize) {
      final end = offset + chunkSize < input.length
          ? offset + chunkSize
          : input.length;
      sink.add(Uint8List.sublistView(input, offset, end));
    }
    sink.close();
    if (mustThrow) {
      findings.add(
        '$description: decoded successfully, expected ZstdException',
      );
    }
  } on ZstdException {
    // The only acceptable failure mode for corrupt input.
  } catch (error, stack) {
    findings.add(
      '$description: threw ${error.runtimeType}: $error\n'
      '${_stackHead(stack)}',
    );
  }
}

String _stackHead(StackTrace stack, {int lines = 6}) {
  final all = stack.toString().split('\n');
  return (all.length <= lines ? all : all.take(lines)).join('\n');
}
