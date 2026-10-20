@TestOn('vm')
library;

// Cross-implementation differential and round-trip fuzzing for `zstd_neo`.
//
// These tests need an independent zstd implementation, so they only run when
// `ZSTD_REF` points at the dev-only Rust binary (see benchmark/rust_ref):
//
//   cargo build --release --manifest-path benchmark/rust_ref/Cargo.toml
//   ZSTD_REF=$PWD/benchmark/rust_ref/target/release/zstd_ref dart test test/differential_test.dart
//
// Without `ZSTD_REF` every test here is skipped, so the default `dart test`
// run never builds or runs Rust. The campaign is deterministic and seeded;
// use `ZSTD_FUZZ_SEED`, `ZSTD_FUZZ_CASES` and `ZSTD_FUZZ_STREAM_CASES` to
// widen it, or `dart run tool/fuzz/soak.dart` for a long local campaign.
//
// Coverage per case:
//   (a) Dart one-shot/streaming encode -> Rust decode -> byte equality;
//   (b) Rust encode -> Dart one-shot/streaming decode -> byte equality;
//   (c) Dart encode -> Dart decode -> byte equality;
//   (d) ratio sanity at level 3 (and 9 once encoder-core implements it);
// plus raw/structured dictionary frames in both directions.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zstd_neo/zstd_neo.dart';

import '../tool/fuzz/fuzz_harness.dart';

int _envInt(String name, int fallback) {
  final raw = Platform.environment[name];
  if (raw == null || raw.trim().isEmpty) return fallback;
  return int.tryParse(raw.trim()) ?? fallback;
}

int _envIntInRange(String name, int fallback, int min, int max) {
  final value = _envInt(name, fallback);
  if (value < min) return min;
  if (value > max) return max;
  return value;
}

void main() {
  final reference = Platform.environment['ZSTD_REF'];
  final skipReason = (reference == null || reference.trim().isEmpty)
      ? 'ZSTD_REF is not set; point it at the built benchmark/rust_ref binary '
            'to run differential fuzzing '
            '(cargo build --release --manifest-path benchmark/rust_ref/Cargo.toml)'
      : null;

  group('differential fuzz', () {
    final int seed = _envInt('ZSTD_FUZZ_SEED', 0x5eed);
    final int campaignCases = _envIntInRange('ZSTD_FUZZ_CASES', 300, 20, 5000);
    final int streamCases = _envIntInRange(
      'ZSTD_FUZZ_STREAM_CASES',
      48,
      8,
      500,
    );

    ZstdRef? ref;
    Directory? scratch;
    List<int> supportedLevels = const <int>[];
    late List<FuzzCase> encoderCampaign;
    late List<FuzzCase> streamingCampaign;
    late List<FuzzCase> decoderCampaign;
    late List<FuzzCase> decoderStreamingCampaign;

    setUpAll(() async {
      expect(
        Directory('test/fixtures').existsSync(),
        isTrue,
        reason: 'missing test/fixtures',
      );
      scratch = Directory(
        'benchmark/.out/fuzz/run-'
        '${DateTime.now().millisecondsSinceEpoch}-$pid',
      )..createSync(recursive: true);
      ref = await ZstdRef.start(executable: reference!, scratchRoot: scratch!);
      supportedLevels = probeEncoderLevels();
      final maxEncoderLevel = supportedLevels.isEmpty
          ? 0
          : supportedLevels.reduce(math.max);
      expect(
        maxEncoderLevel,
        greaterThanOrEqualTo(1),
        reason: 'no working encoder level was reported',
      );

      encoderCampaign = buildCampaign(
        cases: campaignCases,
        seed: seed,
        maxLevel: maxEncoderLevel,
      );
      streamingCampaign = buildCampaign(
        cases: streamCases,
        seed: seed + 7,
        maxLevel: maxEncoderLevel,
        maxSize: 262144,
        includeCoverage: false,
      );
      // The decoder must handle every level libzstd can produce, even while
      // the Dart encoder is still limited to a subset.
      decoderCampaign = buildCampaign(
        cases: campaignCases,
        seed: seed + 1,
        maxLevel: 19,
        levelCap: decoderLevelCap,
      );
      decoderStreamingCampaign = buildCampaign(
        cases: streamCases,
        seed: seed + 8,
        maxLevel: 19,
        maxSize: 262144,
        levelCap: decoderLevelCap,
        includeCoverage: false,
      );
    });

    tearDownAll(() {
      ref?.dispose();
      final directory = scratch;
      if (directory != null && directory.existsSync()) {
        directory.deleteSync(recursive: true);
      }
    });

    test('seeded generator is deterministic and size-exact', () {
      final first = generateData(4096, 'text', 1234);
      final second = generateData(4096, 'text', 1234);
      expect(
        first,
        equals(second),
        reason: 'the same seed and pattern must produce the same bytes',
      );
      expect(
        generateData(4096, 'json', 1234),
        isNot(equals(first)),
        reason: 'different patterns must produce different data',
      );
      for (final size in fuzzSizes) {
        expect(
          generateData(size, 'text', 99),
          hasLength(size),
          reason: 'text size=$size',
        );
      }
      for (final pattern in fuzzPatterns) {
        expect(
          generateData(4096, pattern, 99),
          hasLength(4096),
          reason: 'pattern=$pattern',
        );
      }
    });

    test('campaign plan is deterministic and covers the matrix', () {
      final planA = buildCampaign(cases: 120, seed: 42, maxLevel: 3);
      final planB = buildCampaign(cases: 120, seed: 42, maxLevel: 3);
      expect(planA.length, greaterThanOrEqualTo(100));
      expect(
        planA.map((fuzzCase) => fuzzCase.label),
        equals(planB.map((fuzzCase) => fuzzCase.label)),
        reason: 'the same seed must build the same campaign',
      );
      expect(
        planA.map((fuzzCase) => fuzzCase.size).toSet(),
        containsAll(<int>[0, 1, 4096, 65536, 262144, 4194304]),
        reason: 'every boundary size must be reached',
      );
      expect(
        planA.map((fuzzCase) => fuzzCase.pattern).toSet(),
        containsAll(fuzzPatterns),
      );
      expect(
        planA.map((fuzzCase) => fuzzCase.level).toSet(),
        containsAll(<int>[1, 3]),
        reason: 'every implemented level must be reached',
      );
      expect(planA.where((fuzzCase) => fuzzCase.checksum), isNotEmpty);
    });

    test('encoder level support is reported', () {
      expect(supportedLevels, isNotEmpty);
      expect(supportedLevels, contains(1));
      final pending = <int>[
        for (var level = 1; level <= 19; level++)
          if (!supportedLevels.contains(level)) level,
      ];
      printOnFailure('supported encoder levels: $supportedLevels');
      if (pending.isNotEmpty) {
        printOnFailure(
          'pending encoder levels (reported, not failed yet): $pending',
        );
      }
      final topLevel = supportedLevels.reduce(math.max);
      expect(
        encoderCampaign.map((fuzzCase) => fuzzCase.level).toSet(),
        containsAll(<int>[1, topLevel]),
      );
    });

    test('Dart one-shot encode -> Dart decode', () {
      final failures = FailureCollector(max: 30);
      runDartRoundTrip(cases: encoderCampaign, failures: failures);
      expect(
        failures.isEmpty,
        isTrue,
        reason:
            'Dart round-trip failures '
            '(${describeCampaign(encoderCampaign)}):\n${failures.summary()}',
      );
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('Dart streaming encode -> Dart decode', () {
      final failures = FailureCollector(max: 30);
      runDartRoundTrip(
        cases: streamingCampaign,
        failures: failures,
        streaming: true,
      );
      expect(
        failures.isEmpty,
        isTrue,
        reason:
            'Dart streaming round-trip failures '
            '(${describeCampaign(streamingCampaign)}):\n${failures.summary()}',
      );
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('Dart one-shot encode -> Rust decode', () async {
      final failures = FailureCollector(max: 30);
      await runDartToRust(
        ref: ref!,
        cases: encoderCampaign,
        failures: failures,
      );
      expect(
        failures.isEmpty,
        isTrue,
        reason:
            'Dart -> libzstd failures '
            '(${describeCampaign(encoderCampaign)}):\n${failures.summary()}',
      );
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('Dart streaming encode -> Rust decode', () async {
      final failures = FailureCollector(max: 30);
      await runDartToRust(
        ref: ref!,
        cases: streamingCampaign,
        failures: failures,
        streaming: true,
      );
      expect(
        failures.isEmpty,
        isTrue,
        reason:
            'Dart streaming -> libzstd failures '
            '(${describeCampaign(streamingCampaign)}):\n${failures.summary()}',
      );
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('known edge: dense fast-strategy matches stay valid', () async {
      // Regression for a fast-strategy (levels 1..2) encoder bug found by
      // soak seed 20261020: the 64-byte repetitive payload produces an invalid
      // frame for these exact prefixes (one-shot and streaming alike).
      final cases = <FuzzCase>[
        for (final size in <int>[
          65599,
          65600,
          65601,
          65602,
          65603,
          65604,
          65605,
        ])
          for (final level in <int>[1, 2])
            FuzzCase(
              index: 920000 + size * 2 + level,
              seed: seed,
              dataSeed: mixSeed(seed, size * 31 + level),
              size: size,
              pattern: 'repetitive',
              level: level,
              checksum: true,
            ),
      ];
      final failures = FailureCollector(max: 20);
      runDartRoundTrip(cases: cases, failures: failures);
      runDartRoundTrip(cases: cases, failures: failures, streaming: true);
      await runDartToRust(ref: ref!, cases: cases, failures: failures);
      await runDartToRust(
        ref: ref!,
        cases: cases,
        failures: failures,
        streaming: true,
      );
      expect(
        failures.isEmpty,
        isTrue,
        reason: 'repetitive-prefix failures:\n${failures.summary()}',
      );
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('streaming chunk boundaries across 128 KiB blocks', () async {
      // Chunk size 1 is only used on tiny inputs by the campaign, so exercise
      // every chunk split explicitly around the 128 KiB block boundary.
      final failures = FailureCollector(max: 20);
      var attempts = 0;
      for (final size in <int>[131071, 131072, 131073, 262144]) {
        for (final pattern in <String>['text', 'repetitive']) {
          final data = generateData(size, pattern, mixSeed(seed, size));
          for (final chunkSize in streamChunkSizes) {
            attempts++;
            final label =
                'size=$size pattern=$pattern chunk=$chunkSize level=3';
            final Uint8List frame;
            try {
              frame = compressStreaming(
                ZstdEncoder(level: 3, checksum: true),
                data,
                chunkSize,
              );
            } catch (error, stack) {
              failures.add(
                FuzzFailure(
                  'dart-stream-encode',
                  '$label: ${describeError(error)}\n${stackHead(stack)}',
                ),
              );
              continue;
            }
            try {
              final decoded = ZstdDecoder().decompress(frame);
              if (!bytesEqual(decoded, data)) {
                failures.add(
                  FuzzFailure(
                    'dart-decode',
                    '$label: ${describeBytesDifference(decoded, data)}',
                  ),
                );
              }
            } catch (error, stack) {
              failures.add(
                FuzzFailure(
                  'dart-decode',
                  '$label: ${describeError(error)}\n${stackHead(stack)}',
                ),
              );
            }
            try {
              final decoded = await ref!.decode(frame);
              if (!bytesEqual(decoded, data)) {
                failures.add(
                  FuzzFailure(
                    'libzstd-decode',
                    '$label: ${describeBytesDifference(decoded, data)}',
                  ),
                );
              }
            } on ZstdRefException catch (error) {
              failures.add(
                FuzzFailure(
                  'libzstd-decode',
                  '$label: libzstd rejected the frame: ${error.message}',
                ),
              );
            }
            if (failures.shouldStop) break;
          }
        }
      }
      expect(attempts, streamChunkSizes.length * 8);
      expect(
        failures.isEmpty,
        isTrue,
        reason: 'block-boundary streaming failures:\n${failures.summary()}',
      );
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('Rust one-shot encode -> Dart one-shot decode', () async {
      final failures = FailureCollector(max: 30);
      final cases = <FuzzCase>[...decoderCampaign, ..._largeDecoderCases(seed)];
      await runRustToDart(ref: ref!, cases: cases, failures: failures);
      expect(
        failures.isEmpty,
        isTrue,
        reason:
            'libzstd -> Dart failures (${describeCampaign(cases)}):\n'
            '${failures.summary()}',
      );
    }, timeout: const Timeout(Duration(minutes: 4)));

    test('Rust one-shot encode -> Dart streaming decode', () async {
      final failures = FailureCollector(max: 30);
      final cases = <FuzzCase>[
        ...decoderStreamingCampaign,
        ..._largeStreamingDecoderCases(seed),
      ];
      await runRustToDart(
        ref: ref!,
        cases: cases,
        failures: failures,
        streaming: true,
        contentSizeOffEvery: 5,
      );
      expect(
        failures.isEmpty,
        isTrue,
        reason:
            'libzstd -> Dart streaming failures '
            '(${describeCampaign(cases)}):\n${failures.summary()}',
      );
    }, timeout: const Timeout(Duration(minutes: 4)));

    test('dictionary differential (raw and structured)', () async {
      final failures = FailureCollector(max: 20);
      final report = await runDictionaryDifferential(
        ref: ref!,
        fixtures: Directory('test/fixtures'),
        failures: failures,
        seed: seed,
      );
      for (final note in report.notes) {
        printOnFailure(note);
      }
      expect(
        report.framesChecked,
        greaterThanOrEqualTo(2),
        reason:
            'expected dictionary fixtures to be exercised; '
            'notes: ${report.notes.join('; ')}',
      );
      expect(
        failures.isEmpty,
        isTrue,
        reason: 'dictionary failures:\n${failures.summary()}',
      );
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('concatenated and skippable frames decode in order', () async {
      final firstData = generateData(70000, 'text', mixSeed(seed, 1));
      final secondData = generateData(30000, 'json', mixSeed(seed, 2));
      final first = await ref!.encode(firstData, level: 9, checksum: true);
      final second = await ref!.encode(secondData, level: 19, checksum: false);
      final expected = Uint8List.fromList(<int>[...firstData, ...secondData]);

      final concatenated = Uint8List.fromList(<int>[...first, ...second]);
      expect(
        ZstdDecoder().decompress(concatenated),
        equals(expected),
        reason: 'concatenated frames (one-shot)',
      );
      expect(
        decompressStreaming(ZstdDecoder(), concatenated, 1000),
        equals(expected),
        reason: 'concatenated frames (streaming)',
      );

      final payload = Uint8List.fromList(<int>[
        0xde,
        0xad,
        0xbe,
        0xef,
        0x00,
        0x11,
        0x22,
        0x33,
      ]);
      final skippable = Uint8List.fromList(<int>[
        0x50,
        0x2a,
        0x4d,
        0x18,
        payload.length,
        0,
        0,
        0,
        ...payload,
      ]);
      final mixed = Uint8List.fromList(<int>[
        ...skippable,
        ...first,
        ...skippable,
        ...second,
      ]);
      expect(
        ZstdDecoder().decompress(mixed),
        equals(expected),
        reason: 'skippable frames around zstd frames (one-shot)',
      );
      expect(
        decompressStreaming(ZstdDecoder(), mixed, 7),
        equals(expected),
        reason: 'skippable frames around zstd frames (streaming)',
      );
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('Dart encoder accepts a dictionary', () {
      final dictionaryFile = File('test/fixtures/rawdict.dict');
      if (!dictionaryFile.existsSync()) {
        markTestSkipped('rawdict.dict fixture is missing');
        return;
      }
      final dictionary = dictionaryFile.readAsBytesSync();
      final encoder = tryCreateEncoderWithDictionary(
        level: 3,
        checksum: true,
        dictionary: dictionary,
      );
      if (encoder == null) {
        markTestSkipped(
          'ZstdEncoder does not expose a `dictionary` parameter yet '
          '(v0.1.1 encoder-core work in progress)',
        );
        return;
      }
      final data = generateData(4096, 'text', seed);
      final frame = encoder.compress(data);
      expect(hasZstdMagic(frame), isTrue);
      final decoded = ZstdDecoder(dictionary: dictionary).decompress(frame);
      expect(decoded, equals(data));
    });

    test('ratio sanity: compressible data shrinks at L3/L9', () {
      final levels = <int>[
        if (supportedLevels.contains(3)) 3,
        if (supportedLevels.contains(9)) 9,
      ];
      expect(levels, isNotEmpty, reason: 'neither level 3 nor level 9 works');
      final failures = FailureCollector(max: 30);
      runRatioSanity(levels: levels, failures: failures, seed: seed);
      expect(
        failures.isEmpty,
        isTrue,
        reason: 'ratio sanity failures:\n${failures.summary()}',
      );
    }, timeout: const Timeout(Duration(minutes: 2)));
  }, skip: skipReason);
}

/// A few deliberately heavy decoder cases that the random campaign is unlikely
/// to hit: maximal levels on multi-block inputs and 4 MiB frames.
List<FuzzCase> _largeDecoderCases(int seed) => <FuzzCase>[
  _manualCase(900001, seed, 1048576, 'json', 19, true),
  _manualCase(900002, seed, 1048576, 'random', 19, true),
  _manualCase(900003, seed, 4194304, 'text', 3, true),
  _manualCase(900004, seed, 4194304, 'random', 1, true),
  _manualCase(900005, seed, 262144, 'binary', 19, true),
  _manualCase(900006, seed, 131073, 'csv', 15, false),
];

List<FuzzCase> _largeStreamingDecoderCases(int seed) => <FuzzCase>[
  _manualCase(910001, seed, 1048576, 'json', 19, true),
  _manualCase(910002, seed, 262144, 'text', 9, true),
  _manualCase(910003, seed, 131073, 'binary', 19, false),
];

FuzzCase _manualCase(
  int index,
  int seed,
  int size,
  String pattern,
  int level,
  bool checksum,
) => FuzzCase(
  index: index,
  seed: seed,
  dataSeed: mixSeed(seed, index * 31 + 7),
  size: size,
  pattern: pattern,
  level: level,
  checksum: checksum,
);
