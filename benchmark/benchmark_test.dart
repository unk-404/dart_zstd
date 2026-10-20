/// Browser-safe benchmark suite for the pure-Dart `zstd_neo` codec.
///
/// Every input is a deterministic 256 KiB Silesia slice embedded as base64 in
/// `bench_data.g.dart`, so this file runs unchanged on the VM (AOT/JIT),
/// dart2js and dart2wasm. It never touches `dart:io`.
///
/// Run it through the `benchmark_test` CLI, for example:
///
/// ```text
/// dart run benchmark_test --compile aot --output jsonl benchmark/benchmark_test.dart
/// ```
///
/// The ids match the libzstd reference measurements in
/// `benchmark/rust_ref/src/bench.rs`, so `report.dart` and benchcat can compare
/// the two series directly.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:benchmark_test/benchmark_test.dart';
import 'package:test/test.dart';
import 'package:zstd_neo/zstd_neo.dart';

import 'bench_data.g.dart';

/// Size of one benchmark input slice, in bytes (256 KiB).
const int sliceBytes = 256 * 1024;

/// Set after every measured operation so the optimizer cannot discard the
/// result. A top-level variable is used because the benchmark closures are
/// invoked by `benchmark_test`, not by this library.
int _sink = 0;

/// Benchmark registration knobs: short enough for CI, stable enough to plot.
const Duration _minDuration = Duration(milliseconds: 500);
const int _minSamples = 10;
const double _targetRme = 2.0;
const int _maxSamples = 100;

/// One corpus: plaintext plus its deterministic level-3 and level-19 frames.
final class _Corpus {
  _Corpus({
    required this.id,
    required this.plain,
    required this.l3,
    required this.l19,
  });

  final String id;
  final Uint8List plain;
  final Uint8List l3;
  final Uint8List l19;

  /// One encoder per corpus, created once outside the benchmark closure.
  final ZstdEncoder encoder = ZstdEncoder(level: 3);
}

List<_Corpus> _loadCorpora() {
  final plain = <String, Uint8List>{};
  final l3 = <String, Uint8List>{};
  final l19 = <String, Uint8List>{};
  final order = <String>[];

  for (final file in benchData) {
    final bytes = base64Decode(file.base64);
    if (bytes.length != file.length) {
      throw StateError(
        'bench_data.g.dart: ${file.corpus}.${file.kind} claims '
        '${file.length} bytes but decodes to ${bytes.length}',
      );
    }
    if (file.kind == 'plain' && bytes.length != sliceBytes) {
      throw StateError(
        'bench_data.g.dart: ${file.corpus}.${file.kind} is ${bytes.length} '
        'bytes, expected $sliceBytes',
      );
    }
    switch (file.kind) {
      case 'plain':
        plain[file.corpus] = bytes;
        if (!order.contains(file.corpus)) {
          order.add(file.corpus);
        }
      case 'l3':
        l3[file.corpus] = bytes;
      case 'l19':
        l19[file.corpus] = bytes;
      default:
        throw StateError('bench_data.g.dart: unknown kind ${file.kind}');
    }
  }

  return [
    for (final id in order)
      _Corpus(
        id: id,
        plain: plain[id] ?? (throw StateError('missing plaintext for $id')),
        l3: l3[id] ?? (throw StateError('missing level-3 frame for $id')),
        l19: l19[id] ?? (throw StateError('missing level-19 frame for $id')),
      ),
  ];
}

void main() {
  final corpora = _loadCorpora();
  const decoder = ZstdDecoder();

  test('embedded L3/L19 frames decode to their plaintext', () {
    expect(corpora, isNotEmpty);
    for (final corpus in corpora) {
      expect(
        decoder.decompress(corpus.l3),
        equals(corpus.plain),
        reason: '${corpus.id} level 3',
      );
      expect(
        decoder.decompress(corpus.l19),
        equals(corpus.plain),
        reason: '${corpus.id} level 19',
      );
    }
  });

  for (final corpus in corpora) {
    benchmark(
      'compress.${corpus.id}.l3',
      () {
        _sink = corpus.encoder.compress(corpus.plain).length;
      },
      minDuration: _minDuration,
      minSamples: _minSamples,
      targetRme: _targetRme,
      maxSamples: _maxSamples,
    );

    benchmark(
      'decompress.${corpus.id}.l3',
      () {
        _sink = decoder.decompress(corpus.l3).length;
      },
      minDuration: _minDuration,
      minSamples: _minSamples,
      targetRme: _targetRme,
      maxSamples: _maxSamples,
    );

    benchmark(
      'decompress.${corpus.id}.l19',
      () {
        _sink = decoder.decompress(corpus.l19).length;
      },
      minDuration: _minDuration,
      minSamples: _minSamples,
      targetRme: _targetRme,
      maxSamples: _maxSamples,
    );
  }

  tearDownAll(() {
    // Read the write-only sink after the measured loops so the analyzer and
    // the optimizer both see that the benchmark results are observable.
    expect(_sink, greaterThan(0));
  });
}
