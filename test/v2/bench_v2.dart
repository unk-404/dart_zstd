/// Benchmarks the v2 encoder against the v0.1.2 encoder on the committed
/// 256 KiB Silesia slices, using the same harness/knobs as
/// `benchmark/benchmark_test.dart`.
///
/// Run with:
///   dart run benchmark_test --compile aot --output jsonl test/v2/bench_v2.dart
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:benchmark_test/benchmark_test.dart';
import 'package:zstd_neo/src/compress/encoder.dart' as v1;
import 'package:zstd_neo/src/v2/compress/encoder.dart';

import '../../benchmark/bench_data.g.dart';

// ignore: unused_element
int _sink = 0;

final class _Corpus {
  _Corpus(this.id, this.plain);
  final String id;
  final Uint8List plain;
  final v1.ZstdEncoder encoder1L3 = v1.ZstdEncoder(level: 3);
  final v1.ZstdEncoder encoder1L9 = v1.ZstdEncoder(level: 9);
  final v1.ZstdEncoder encoder1L19 = v1.ZstdEncoder(level: 19);
  final ZstdV2Encoder encoder2L3 = ZstdV2Encoder(level: 3);
  final ZstdV2Encoder encoder2L9 = ZstdV2Encoder(level: 9);
  final ZstdV2Encoder encoder2L19 = ZstdV2Encoder(level: 19);
}

void _benchmark(String id, void Function() body) {
  benchmark(
    id,
    body,
    minDuration: const Duration(milliseconds: 500),
    minSamples: 10,
    targetRme: 2.0,
    maxSamples: 100,
  );
}

void main() {
  final plains = <String, Uint8List>{};
  final order = <String>[];
  for (final file in benchData) {
    if (file.kind == 'plain') {
      plains[file.corpus] = base64Decode(file.base64);
      if (!order.contains(file.corpus)) order.add(file.corpus);
    }
  }
  final corpora = [for (final id in order) _Corpus(id, plains[id]!)];
  for (final corpus in corpora) {
    _benchmark('compress.v1.${corpus.id}.l3', () {
      _sink = corpus.encoder1L3.compress(corpus.plain).length;
    });
    _benchmark('compress.v1.${corpus.id}.l9', () {
      _sink = corpus.encoder1L9.compress(corpus.plain).length;
    });
    _benchmark('compress.v1.${corpus.id}.l19', () {
      _sink = corpus.encoder1L19.compress(corpus.plain).length;
    });
    _benchmark('compress.v2.${corpus.id}.l3', () {
      _sink = corpus.encoder2L3.compress(corpus.plain).length;
    });
    _benchmark('compress.v2.${corpus.id}.l9', () {
      _sink = corpus.encoder2L9.compress(corpus.plain).length;
    });
    _benchmark('compress.v2.${corpus.id}.l19', () {
      _sink = corpus.encoder2L19.compress(corpus.plain).length;
    });
  }
}
