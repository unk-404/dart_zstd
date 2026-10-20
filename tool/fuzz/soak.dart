// Long-running local soak driver for the zstd_neo differential fuzz harness.
//
// Reuses `tool/fuzz/fuzz_harness.dart` (the same generators, campaign plan and
// checks as `test/differential_test.dart`), but is meant for multi-thousand
// case runs outside CI:
//
//   cargo build --release --manifest-path benchmark/rust_ref/Cargo.toml
//   dart run tool/fuzz/soak.dart --cases 5000 --seed 12345
//
// Exit code 0 means no findings; 1 means at least one differential failure was
// recorded (the details are printed and written next to the run directory).

import 'dart:io';
import 'dart:math' as math;

import 'fuzz_harness.dart';

const String _usage = '''
Usage: dart run tool/fuzz/soak.dart [options]

Runs a long differential campaign against the dev-only Rust reference binary.

Options:
  --ref PATH        zstd_ref executable (default: \$ZSTD_REF, else the
                    release build under benchmark/rust_ref/target)
  --cases N         cases per direction (default 2000)
  --stream-cases N  streaming cases per direction (default 300)
  --seed N          campaign seed (default 20261020)
  --max-size N      largest input in bytes (default 4194304)
  --levels A-B      Dart encoder level range to sample (default 1-19)
  --permissive      disable the size/level caps (slow: 4 MiB at level 19)
  --max-findings N  stop after N findings (default 100)
  --fail-fast       stop after the first finding
  --skip-dict       skip the dictionary phase
  --skip-ratio      skip the ratio sanity phase
  -h, --help        show this help
''';

int _lastProgressBucket = -1;

Future<void> main(List<String> arguments) async {
  final _Options options;
  try {
    options = _Options.parse(arguments);
  } on ArgumentError catch (error) {
    stderr
      ..writeln('soak: ${error.message}')
      ..writeln(_usage);
    exitCode = 2;
    return;
  }
  if (options.help) {
    stdout.writeln(_usage);
    return;
  }
  exitCode = await _run(options);
}

Future<int> _run(_Options options) async {
  final refFile = File(options.refPath);
  if (!refFile.existsSync()) {
    stderr
      ..writeln('soak: reference binary not found: ${refFile.absolute.path}')
      ..writeln(
        '      build it with: cargo build --release '
        '--manifest-path benchmark/rust_ref/Cargo.toml',
      );
    return 2;
  }

  final scratch = Directory(
    'benchmark/.out/fuzz/soak-${DateTime.now().millisecondsSinceEpoch}',
  )..createSync(recursive: true);
  final stopwatch = Stopwatch()..start();
  _lastProgressBucket = -1;
  final ref = await ZstdRef.start(
    executable: options.refPath,
    scratchRoot: scratch,
  );

  stdout.writeln('== zstd_neo differential soak');
  stdout.writeln('   reference : ${ref.version}');
  stdout.writeln('   scratch   : ${scratch.absolute.path}');

  final probe = probeEncoderLevels();
  final supported = probe
      .where((level) => level >= options.minLevel && level <= options.maxLevel)
      .toList(growable: false);
  if (supported.isEmpty) {
    stderr.writeln(
      'soak: no encoder level in the requested range '
      '${options.minLevel}-${options.maxLevel} works (probed: $probe)',
    );
    ref.dispose();
    return 2;
  }
  final maxEncoderLevel = supported.reduce(math.max);
  stdout.writeln('   encoder   : levels $supported');

  final levelCap = options.permissive
      ? (int level, int size) => level
      : defaultLevelCap;
  final decoderCap = options.permissive
      ? (int level, int size) => level
      : decoderLevelCap;

  final encoderCampaign = buildCampaign(
    cases: options.cases,
    seed: options.seed,
    maxLevel: maxEncoderLevel,
    maxSize: options.maxSize,
    levelCap: levelCap,
  );
  final streamingCampaign = buildCampaign(
    cases: options.streamCases,
    seed: options.seed + 7,
    maxLevel: maxEncoderLevel,
    maxSize: math.min(options.maxSize, 262144),
    levelCap: levelCap,
    includeCoverage: false,
  );
  final decoderCampaign = buildCampaign(
    cases: options.cases,
    seed: options.seed + 1,
    maxLevel: 19,
    maxSize: options.maxSize,
    levelCap: decoderCap,
  );
  final decoderStreamingCampaign = buildCampaign(
    cases: options.streamCases,
    seed: options.seed + 8,
    maxLevel: 19,
    maxSize: math.min(options.maxSize, 262144),
    levelCap: decoderCap,
    includeCoverage: false,
  );

  stdout
    ..writeln('   seed      : ${options.seed}')
    ..writeln('   encoder plan: ${describeCampaign(encoderCampaign)}')
    ..writeln('   decoder plan: ${describeCampaign(decoderCampaign)}')
    ..writeln(
      '   stream plan : encoder ${describeCampaign(streamingCampaign)}, '
      'decoder ${describeCampaign(decoderStreamingCampaign)}',
    )
    ..writeln();

  final failures = FailureCollector(
    max: options.failFast
        ? 1
        : (options.maxFindings < 1 ? 1 : options.maxFindings),
  );

  Future<void> phase(String name, Future<void> Function() body) async {
    if (failures.shouldStop) return;
    stdout.writeln('== $name');
    final watch = Stopwatch()..start();
    await body();
    watch.stop();
    stdout.writeln(
      '   ${failures.isEmpty ? 'ok' : 'FINDINGS: ${failures.failures.length}'}'
      ' in ${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)}s',
    );
  }

  void progress(int completed, int total) {
    if (total <= 0) return;
    const steps = 10;
    final bucket = completed * steps ~/ total;
    if (bucket == _lastProgressBucket) return;
    _lastProgressBucket = bucket;
    stdout.writeln('   ${(bucket * 100 / steps).round()}% ($completed/$total)');
  }

  await phase('Dart one-shot encode -> Dart decode', () async {
    runDartRoundTrip(
      cases: encoderCampaign,
      failures: failures,
      onProgress: progress,
    );
  });
  await phase('Dart streaming encode -> Dart decode', () async {
    runDartRoundTrip(
      cases: streamingCampaign,
      failures: failures,
      streaming: true,
      onProgress: progress,
    );
  });
  await phase('Dart one-shot encode -> libzstd decode', () async {
    await runDartToRust(
      ref: ref,
      cases: encoderCampaign,
      failures: failures,
      onProgress: progress,
    );
  });
  await phase('Dart streaming encode -> libzstd decode', () async {
    await runDartToRust(
      ref: ref,
      cases: streamingCampaign,
      failures: failures,
      streaming: true,
      onProgress: progress,
    );
  });
  await phase('libzstd encode -> Dart one-shot decode', () async {
    await runRustToDart(
      ref: ref,
      cases: decoderCampaign,
      failures: failures,
      onProgress: progress,
    );
  });
  await phase('libzstd encode -> Dart streaming decode', () async {
    await runRustToDart(
      ref: ref,
      cases: decoderStreamingCampaign,
      failures: failures,
      streaming: true,
      contentSizeOffEvery: 5,
      onProgress: progress,
    );
  });
  if (!options.skipDictionary) {
    await phase('dictionary differential', () async {
      final report = await runDictionaryDifferential(
        ref: ref,
        fixtures: Directory('test/fixtures'),
        failures: failures,
        seed: options.seed,
      );
      for (final note in report.notes) {
        stdout.writeln('   note: $note');
      }
      stdout.writeln('   dictionary frames checked: ${report.framesChecked}');
    });
  }
  if (!options.skipRatio) {
    await phase('ratio sanity', () async {
      final levels = <int>[
        if (supported.contains(3)) 3,
        if (supported.contains(9)) 9,
      ];
      if (levels.isEmpty) {
        stdout.writeln('   skipped: neither level 3 nor level 9 is available');
        return;
      }
      runRatioSanity(levels: levels, failures: failures, seed: options.seed);
    });
  }

  stopwatch.stop();
  ref.dispose();

  final logFile = File('${scratch.path}/failures.txt');
  if (failures.isNotEmpty) {
    logFile.writeAsStringSync('${failures.summary()}\n');
  }

  stdout
    ..writeln()
    ..writeln('== summary')
    ..writeln(
      '   elapsed: ${(stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1)}s',
    )
    ..writeln('   findings: ${failures.failures.length}');
  if (failures.isNotEmpty) {
    stdout
      ..writeln()
      ..writeln(failures.summary())
      ..writeln()
      ..writeln('   failure log: ${logFile.absolute.path}');
    return 1;
  }
  stdout.writeln('   no differential failures');
  return 0;
}

final class _Options {
  _Options({
    required this.cases,
    required this.streamCases,
    required this.seed,
    required this.maxSize,
    required this.minLevel,
    required this.maxLevel,
    required this.permissive,
    required this.maxFindings,
    required this.failFast,
    required this.skipDictionary,
    required this.skipRatio,
    required this.refPath,
    required this.help,
  });

  final int cases;
  final int streamCases;
  final int seed;
  final int maxSize;
  final int minLevel;
  final int maxLevel;
  final bool permissive;
  final int maxFindings;
  final bool failFast;
  final bool skipDictionary;
  final bool skipRatio;
  final String refPath;
  final bool help;

  static _Options parse(List<String> arguments) {
    var cases = 2000;
    var streamCases = 300;
    var seed = 20261020;
    var maxSize = fuzzMaxSize;
    var minLevel = 1;
    var maxLevel = 19;
    var permissive = false;
    var maxFindings = 100;
    var failFast = false;
    var skipDictionary = false;
    var skipRatio = false;
    var refPath = _defaultRefPath();
    var help = false;

    var index = 0;
    String nextValue(String option) {
      index++;
      if (index >= arguments.length) {
        throw ArgumentError('$option needs a value');
      }
      return arguments[index];
    }

    while (index < arguments.length) {
      final argument = arguments[index];
      switch (argument) {
        case '--ref':
          refPath = nextValue(argument);
        case '--cases':
          cases = _positiveInt(nextValue(argument), '--cases');
        case '--stream-cases':
          streamCases = _positiveInt(nextValue(argument), '--stream-cases');
        case '--seed':
          seed = int.tryParse(nextValue(argument)) ?? seed;
        case '--max-size':
          maxSize = _positiveInt(nextValue(argument), '--max-size');
        case '--levels':
          final value = nextValue(argument);
          final parts = value.split('-');
          if (parts.length != 2) {
            throw ArgumentError('--levels expects A-B, got `$value`');
          }
          minLevel = _positiveInt(parts[0], '--levels');
          maxLevel = _positiveInt(parts[1], '--levels');
          if (minLevel > maxLevel) {
            throw ArgumentError('--levels needs A <= B, got `$value`');
          }
        case '--permissive':
          permissive = true;
        case '--max-findings':
          maxFindings = _positiveInt(nextValue(argument), '--max-findings');
        case '--fail-fast':
          failFast = true;
        case '--skip-dict':
          skipDictionary = true;
        case '--skip-ratio':
          skipRatio = true;
        case '-h':
        case '--help':
          help = true;
        default:
          throw ArgumentError('unknown option `$argument`');
      }
      index++;
    }

    return _Options(
      cases: cases,
      streamCases: streamCases,
      seed: seed,
      maxSize: maxSize,
      minLevel: minLevel,
      maxLevel: maxLevel,
      permissive: permissive,
      maxFindings: maxFindings,
      failFast: failFast,
      skipDictionary: skipDictionary,
      skipRatio: skipRatio,
      refPath: refPath,
      help: help,
    );
  }
}

int _positiveInt(String value, String option) {
  final parsed = int.tryParse(value);
  if (parsed == null || parsed <= 0) {
    throw ArgumentError('$option expects a positive integer, got `$value`');
  }
  return parsed;
}

String _defaultRefPath() {
  final fromEnvironment = Platform.environment['ZSTD_REF'];
  if (fromEnvironment != null && fromEnvironment.trim().isNotEmpty) {
    return fromEnvironment.trim();
  }
  final executable = Platform.isWindows ? 'zstd_ref.exe' : 'zstd_ref';
  return 'benchmark/rust_ref/target/release/$executable';
}
