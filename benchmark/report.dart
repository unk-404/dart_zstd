/// Converts `benchmark_test` and libzstd JSONL into canonical benchmark series.
///
/// Inputs (override with flags):
///
/// * `build/bench/raw-dart-aot.jsonl`    — required;
/// * `build/bench/raw-dart-js.jsonl`     — optional, skipped with a warning;
/// * `build/bench/raw-dart-wasm.jsonl`   — optional, skipped with a warning;
/// * `build/bench/series-rust.jsonl`     — required, already canonical.
///
/// Outputs, written to `--out-dir` (default `build/bench`):
/// `series-dart-aot.jsonl`, `series-dart-js.jsonl`, `series-dart-wasm.jsonl`
/// and `series-rust.jsonl`. Every row is one canonical record:
///
/// ```json
/// {"id":"compress.dickens.l3","group":"Compress · L3","label":"dickens",
///  "unit":"MiB/s","value":12.5,"stats":{"rme_pct":1.2,"samples":42}}
/// ```
///
/// `benchmark_test` reports operations per second; canonical throughput is
/// MiB/s of plaintext (operations/s × 262144 / 1048576). Ratios at L3, L9 and
/// L19 are computed once for the AOT series only (js/wasm would repeat the
/// identical values), using the same embedded corpus as the benchmark.
///
/// This is a native command-line tool; it may use `dart:io`. The benchmark
/// itself (`benchmark_test.dart`) remains browser-safe.
library;

import 'dart:convert';
import 'dart:io';

import 'package:zstd_neo/zstd_neo.dart';

import 'bench_data.g.dart';

const int sliceBytes = 256 * 1024;
const int _bytesPerMiB = 1024 * 1024;

const String _defaultAot = 'build/bench/raw-dart-aot.jsonl';
const String _defaultJs = 'build/bench/raw-dart-js.jsonl';
const String _defaultWasm = 'build/bench/raw-dart-wasm.jsonl';
const String _defaultRust = 'build/bench/series-rust.jsonl';
const String _defaultOutDir = 'build/bench';

const Map<String, int> _groupOrder = <String, int>{
  'Compress · L3': 0,
  'Compress · L9': 1,
  'Compress · L19': 2,
  'Decompress · L3': 3,
  'Decompress · L19': 4,
  'Ratio · L3': 5,
  'Ratio · L9': 6,
  'Ratio · L19': 7,
};

const Set<String> _compressLevels = <String>{'l3', 'l9', 'l19'};
const Set<String> _decompressLevels = <String>{'l3', 'l19'};
const Set<String> _ratioLevels = <String>{'l3', 'l9', 'l19'};

final RegExp _idPattern = RegExp(
  r'^(compress|decompress|ratio)\.(.+)\.(l[0-9]+)$',
);

const String _usage =
    '''
Usage: dart run benchmark/report.dart [options]

  --aot FILE       benchmark_test JSONL for AOT (default $_defaultAot)
  --js FILE        benchmark_test JSONL for dart2js (default $_defaultJs)
  --wasm FILE      benchmark_test JSONL for dart2wasm (default $_defaultWasm)
  --rust FILE      canonical libzstd JSONL (default $_defaultRust)
  --out-dir DIR    output directory (default $_defaultOutDir)
  -h, --help       show this help

The js and wasm inputs are optional: when missing they are skipped with a
warning, and the corresponding output file is not written. The AOT and Rust
inputs are required. Every non-ratio value must be finite and greater than 0.
''';

void main(List<String> arguments) {
  try {
    _run(arguments);
  } on Object catch (error) {
    stderr.writeln('report: $error');
    exitCode = 1;
  }
}

void _run(List<String> arguments) {
  final options = _parseArguments(arguments);
  if (options == null) {
    return;
  }

  final corpora = _corpusIds();
  if (corpora.isEmpty) {
    throw StateError('bench_data.g.dart does not contain any corpora');
  }
  final expectedThroughput = <String>{
    for (final corpus in corpora) ...<String>[
      'compress.$corpus.l3',
      'compress.$corpus.l9',
      'compress.$corpus.l19',
      'decompress.$corpus.l3',
      'decompress.$corpus.l19',
    ],
  };
  final expectedWithRatio = <String>{
    ...expectedThroughput,
    for (final corpus in corpora) ...<String>[
      'ratio.$corpus.l3',
      'ratio.$corpus.l9',
      'ratio.$corpus.l19',
    ],
  };

  final aotRaw = _readRawJsonl(options.aot, required: true);
  final aotRows = <Map<String, Object?>>[
    for (final record in aotRaw) _convertBenchmarkRecord(record, options.aot),
  ];
  final ratioRows = _computeRatios(options.aot);
  final aot = _sorted([...aotRows, ...ratioRows], corpora);
  _requireCoverage(aot, expectedWithRatio, options.aot);
  _validateRows(aot, options.aot);

  final jsRaw = _readRawJsonl(options.js, required: false);
  final js = _sorted([
    for (final record in jsRaw) _convertBenchmarkRecord(record, options.js),
  ], corpora);
  if (jsRaw.isNotEmpty) {
    _requireCoverage(js, expectedThroughput, options.js);
    _validateRows(js, options.js);
  }

  final wasmRaw = _readRawJsonl(options.wasm, required: false);
  final wasm = _sorted([
    for (final record in wasmRaw) _convertBenchmarkRecord(record, options.wasm),
  ], corpora);
  if (wasmRaw.isNotEmpty) {
    _requireCoverage(wasm, expectedThroughput, options.wasm);
    _validateRows(wasm, options.wasm);
  }

  final rustRaw = _readRawJsonl(options.rust, required: true);
  final rust = _sorted([
    for (final record in rustRaw) _normalizeRustRecord(record, options.rust),
  ], corpora);
  _requireCoverage(rust, expectedWithRatio, options.rust);
  _validateRows(rust, options.rust);

  final outDir = Directory(options.outDir);
  outDir.createSync(recursive: true);
  _writeSeries(outDir, 'series-dart-aot.jsonl', aot);
  _writeSeries(outDir, 'series-rust.jsonl', rust);
  if (jsRaw.isNotEmpty) {
    _writeSeries(outDir, 'series-dart-js.jsonl', js);
  } else {
    stderr.writeln(
      'report: warning: ${options.js} not found; skipping the JS series',
    );
  }
  if (wasmRaw.isNotEmpty) {
    _writeSeries(outDir, 'series-dart-wasm.jsonl', wasm);
  } else {
    stderr.writeln(
      'report: warning: ${options.wasm} not found; skipping the Wasm series',
    );
  }

  stderr.writeln(
    'report: wrote AOT ${aot.length} rows, Rust ${rust.length} rows'
    '${jsRaw.isNotEmpty ? ', JS ${js.length} rows' : ''}'
    '${wasmRaw.isNotEmpty ? ', Wasm ${wasm.length} rows' : ''}'
    ' to ${outDir.path}',
  );
}

/// The parsed command line, or `null` after `--help`.
final class _Options {
  _Options({
    required this.aot,
    required this.js,
    required this.wasm,
    required this.rust,
    required this.outDir,
  });

  final String aot;
  final String js;
  final String wasm;
  final String rust;
  final String outDir;
}

_Options? _parseArguments(List<String> arguments) {
  var aot = _defaultAot;
  var js = _defaultJs;
  var wasm = _defaultWasm;
  var rust = _defaultRust;
  var outDir = _defaultOutDir;
  var index = 0;
  while (index < arguments.length) {
    final argument = arguments[index];
    switch (argument) {
      case '--aot':
        index++;
        aot = _value(arguments, index, '--aot');
      case '--js':
        index++;
        js = _value(arguments, index, '--js');
      case '--wasm':
        index++;
        wasm = _value(arguments, index, '--wasm');
      case '--rust':
        index++;
        rust = _value(arguments, index, '--rust');
      case '--out-dir':
        index++;
        outDir = _value(arguments, index, '--out-dir');
      case '--help' || '-h':
        stdout.write(_usage);
        return null;
      default:
        throw ArgumentError('unknown argument "$argument"\n\n$_usage');
    }
    index++;
  }
  return _Options(aot: aot, js: js, wasm: wasm, rust: rust, outDir: outDir);
}

String _value(List<String> arguments, int index, String flag) {
  if (index >= arguments.length) {
    throw ArgumentError('$flag needs a value');
  }
  return arguments[index];
}

/// Corpus ids in the order embedded by `bench-data`.
List<String> _corpusIds() {
  final ids = <String>[];
  for (final file in benchData) {
    if (file.kind == 'plain' && !ids.contains(file.corpus)) {
      ids.add(file.corpus);
    }
  }
  return ids;
}

List<Map<String, Object?>> _readRawJsonl(
  String path, {
  required bool required,
}) {
  final file = File(path);
  if (!file.existsSync()) {
    if (required) {
      throw StateError('required input not found: $path');
    }
    return const <Map<String, Object?>>[];
  }
  final records = <Map<String, Object?>>[];
  var lineNumber = 0;
  for (final line in file.readAsLinesSync()) {
    lineNumber++;
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      continue;
    }
    // `benchmark_test --output jsonl` interleaves its test-reporter progress
    // with the machine-readable records. Only object lines are data.
    if (!trimmed.startsWith('{')) {
      continue;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException catch (error) {
      throw FormatException(
        '$path:$lineNumber: invalid JSON: ${error.message}',
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw FormatException('$path:$lineNumber: expected a JSON object');
    }
    records.add(decoded);
  }
  if (records.isEmpty) {
    throw StateError('$path: no JSONL records');
  }
  return records;
}

String _expectedGroup(String metric, String level, String source, String id) {
  final supported = switch (metric) {
    'compress' => _compressLevels.contains(level),
    'decompress' => _decompressLevels.contains(level),
    'ratio' => _ratioLevels.contains(level),
    _ => false,
  };
  if (!supported) {
    throw FormatException(
      '$source: unsupported id "$id" '
      '(compress L3/L9/L19, decompress L3/L19, ratio L3/L9/L19)',
    );
  }
  final metricLabel = switch (metric) {
    'compress' => 'Compress',
    'decompress' => 'Decompress',
    'ratio' => 'Ratio',
    _ => throw FormatException('$source: unsupported id "$id"'),
  };
  return '$metricLabel · L${level.substring(1)}';
}

Map<String, Object?> _convertBenchmarkRecord(
  Map<String, Object?> record,
  String source,
) {
  final name = record['name'];
  if (name is! String) {
    throw FormatException('$source: benchmark record has no string "name"');
  }
  final match = _idPattern.firstMatch(name);
  if (match == null) {
    throw FormatException('$source: unexpected benchmark id "$name"');
  }
  final metric = match.group(1)!;
  final corpus = match.group(2)!;
  final level = match.group(3)!;

  final group = _expectedGroup(metric, level, source, name);
  if (!_corpusIds().contains(corpus)) {
    throw FormatException('$source: unknown corpus "$corpus" in "$name"');
  }

  final throughput = record['throughput'];
  if (throughput is! Map<String, Object?>) {
    throw FormatException('$source: "$name" has no throughput object');
  }
  final unit = throughput['unit'];
  if (unit != 'ops/sec') {
    throw FormatException(
      '$source: "$name" reports throughput in "$unit", expected "ops/sec"',
    );
  }
  final operationsPerSecond = _finitePositive(
    throughput['value'],
    '$source: "$name" throughput',
  );
  final value = operationsPerSecond * sliceBytes / _bytesPerMiB;

  final statistics = record['statistics'];
  if (statistics is! Map<String, Object?>) {
    throw FormatException('$source: "$name" has no statistics object');
  }
  final rme = _finiteNonNegative(
    statistics['relativeMarginOfError'],
    '$source: "$name" relativeMarginOfError',
  );
  final samples = statistics['samples'];
  if (samples is! int || samples <= 0) {
    throw FormatException(
      '$source: "$name" statistics.samples must be a positive integer',
    );
  }

  return _row(
    id: name,
    group: group,
    label: corpus,
    unit: 'MiB/s',
    value: value,
    rmePct: rme,
    samples: samples,
  );
}

Map<String, Object?> _normalizeRustRecord(
  Map<String, Object?> record,
  String source,
) {
  final id = record['id'];
  if (id is! String || !_idPattern.hasMatch(id)) {
    throw FormatException('$source: unexpected canonical id "$id"');
  }
  final match = _idPattern.firstMatch(id)!;
  final metric = match.group(1)!;
  final corpus = match.group(2)!;
  final level = match.group(3)!;
  if (!_corpusIds().contains(corpus)) {
    throw FormatException('$source: unknown corpus "$corpus" in "$id"');
  }

  final group = record['group'];
  final label = record['label'];
  final unit = record['unit'];
  final direction = record['direction'];
  final value = _finitePositive(record['value'], '$source: "$id" value');
  final stats = record['stats'];
  if (stats is! Map<String, Object?>) {
    throw FormatException('$source: "$id" has no stats object');
  }
  final rme = _finiteNonNegative(
    stats['rme_pct'],
    '$source: "$id" stats.rme_pct',
  );
  final samples = stats['samples'];
  if (samples is! int || samples <= 0) {
    throw FormatException('$source: "$id" stats.samples must be positive');
  }

  final expectedGroup = _expectedGroup(metric, level, source, id);
  if (group != expectedGroup) {
    throw FormatException(
      '$source: "$id" has group "$group", expected "$expectedGroup"',
    );
  }
  if (label != corpus) {
    throw FormatException(
      '$source: "$id" has label "$label", expected "$corpus"',
    );
  }
  final isRatio = metric == 'ratio';
  final expectedUnit = isRatio ? 'x' : 'MiB/s';
  if (unit != expectedUnit) {
    throw FormatException(
      '$source: "$id" has unit "$unit", expected "$expectedUnit"',
    );
  }
  if (isRatio) {
    if (direction != 'lower') {
      throw FormatException('$source: "$id" must have direction "lower"');
    }
  } else if (direction != null) {
    throw FormatException('$source: "$id" must not set a direction');
  }

  return _row(
    id: id,
    group: expectedGroup,
    label: corpus,
    unit: expectedUnit,
    direction: isRatio ? 'lower' : null,
    value: value,
    rmePct: rme,
    samples: samples,
  );
}

/// Computes `ratio.<corpus>.l3`, `.l9` and `.l19` once for the AOT series.
List<Map<String, Object?>> _computeRatios(String source) {
  const levels = <int>[3, 9, 19];
  final encoders = <int, ZstdEncoder>{
    for (final level in levels) level: ZstdEncoder(level: level),
  };
  final rows = <Map<String, Object?>>[];
  final seen = <String>{};
  for (final file in benchData) {
    if (file.kind != 'plain' || !seen.add(file.corpus)) {
      continue;
    }
    final plain = base64Decode(file.base64);
    if (plain.length != sliceBytes || plain.length != file.length) {
      throw StateError(
        'bench_data.g.dart: ${file.corpus} plaintext is ${plain.length} '
        'bytes, expected $sliceBytes',
      );
    }
    for (final level in levels) {
      final compressed = encoders[level]!.compress(plain);
      final ratio = compressed.length / plain.length;
      if (!ratio.isFinite || ratio <= 0) {
        throw StateError(
          '$source: degenerate level-$level ratio for ${file.corpus}',
        );
      }
      rows.add(
        _row(
          id: 'ratio.${file.corpus}.l$level',
          group: 'Ratio · L$level',
          label: file.corpus,
          unit: 'x',
          direction: 'lower',
          value: ratio,
          rmePct: 0,
          samples: 1,
        ),
      );
    }
  }
  return rows;
}

Map<String, Object?> _row({
  required String id,
  required String group,
  required String label,
  required String unit,
  String? direction,
  required double value,
  required double rmePct,
  required int samples,
}) {
  return <String, Object?>{
    'id': id,
    'group': group,
    'label': label,
    'unit': unit,
    'direction': ?direction,
    'value': _round(value, 6),
    'stats': <String, Object?>{
      'rme_pct': _round(rmePct, 4),
      'samples': samples,
    },
  };
}

double _round(double value, int places) =>
    double.parse(value.toStringAsFixed(places));

double _finitePositive(Object? value, String what) {
  if (value is! num || !value.isFinite || value <= 0) {
    throw FormatException('$what must be a finite number greater than 0');
  }
  return value.toDouble();
}

double _finiteNonNegative(Object? value, String what) {
  if (value is! num || !value.isFinite || value < 0) {
    throw FormatException('$what must be a finite non-negative number');
  }
  return value.toDouble();
}

List<Map<String, Object?>> _sorted(
  List<Map<String, Object?>> rows,
  List<String> corpora,
) {
  final corpusOrder = <String, int>{
    for (var index = 0; index < corpora.length; index++) corpora[index]: index,
  };
  final sorted = List<Map<String, Object?>>.of(rows);
  sorted.sort((a, b) {
    final groupA = _groupOrder[a['group']] ?? 99;
    final groupB = _groupOrder[b['group']] ?? 99;
    if (groupA != groupB) {
      return groupA.compareTo(groupB);
    }
    final corpusA = corpusOrder[a['label']] ?? 99;
    final corpusB = corpusOrder[b['label']] ?? 99;
    return corpusA.compareTo(corpusB);
  });
  return sorted;
}

void _requireCoverage(
  List<Map<String, Object?>> rows,
  Set<String> expected,
  String source,
) {
  final ids = <String>{};
  for (final row in rows) {
    final id = row['id'];
    if (id is! String || !ids.add(id)) {
      throw FormatException('$source: duplicate or invalid id "$id"');
    }
  }
  final missing = expected.difference(ids);
  final extra = ids.difference(expected);
  if (missing.isNotEmpty) {
    throw StateError('$source: missing ids: ${missing.join(', ')}');
  }
  if (extra.isNotEmpty) {
    throw StateError('$source: unexpected ids: ${extra.join(', ')}');
  }
}

void _validateRows(List<Map<String, Object?>> rows, String source) {
  for (final row in rows) {
    final id = row['id'];
    final unit = row['unit'];
    final value = row['value'];
    final isRatio = unit == 'x';
    if (!isRatio) {
      _finitePositive(value, '$source: "$id" value');
    } else {
      _finitePositive(value, '$source: "$id" ratio');
      if (row['direction'] != 'lower') {
        throw FormatException('$source: "$id" ratio must be lower-is-better');
      }
    }
    final stats = row['stats'];
    if (stats is! Map<String, Object?> || stats['samples'] is! int) {
      throw FormatException('$source: "$id" has invalid stats');
    }
  }
}

void _writeSeries(
  Directory outDir,
  String name,
  List<Map<String, Object?>> rows,
) {
  final buffer = StringBuffer();
  for (final row in rows) {
    buffer.writeln(jsonEncode(row));
  }
  File('${outDir.path}/$name').writeAsStringSync(buffer.toString());
}
