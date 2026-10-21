// Standalone best-of-N AOT micro-benchmark: v0.1.2 vs v2 encoder on the
// committed Silesia slices. Run via:
//   dart compile exe test/v2/bench_exe.dart -o build/perf/v2bench.exe
//   build/perf/v2bench.exe
// Prints one line per (level, corpus) with the best of N timings, so noisy
// shared-host scheduling affects all variants equally (runs are interleaved).
import 'dart:convert';
import 'dart:typed_data';

import 'package:zstd_neo/src/compress/encoder.dart' as v1;
import 'package:zstd_neo/src/v2/compress/encoder.dart';

import '../../benchmark/bench_data.g.dart';

int _sink = 0;

double _bestMiB(
  Uint8List input,
  int Function() run, {
  int warmup = 5,
  int runs = 15,
}) {
  for (var i = 0; i < warmup; i++) {
    _sink = run();
  }
  var best = double.infinity;
  for (var i = 0; i < runs; i++) {
    final sw = Stopwatch()..start();
    _sink = run();
    sw.stop();
    final seconds = sw.elapsedMicroseconds / 1e6;
    if (seconds < best) best = seconds;
  }
  return input.length / (1 << 20) / best;
}

void main() {
  final plains = <String, Uint8List>{};
  for (final file in benchData) {
    if (file.kind == 'plain') {
      plains[file.corpus] = base64Decode(file.base64);
    }
  }
  final corpora = plains.keys.toList()..sort();
  for (final level in <int>[3, 9, 19]) {
    for (final corpus in corpora) {
      final input = plains[corpus]!;
      final e1 = v1.ZstdEncoder(level: level);
      final e2 = ZstdV2Encoder(level: level);
      final m1 = _bestMiB(input, () => e1.compress(input).length);
      final m2 = _bestMiB(input, () => e2.compress(input).length);
      print(
        'RESULT $level $corpus '
        'v1=${m1.toStringAsFixed(2)} v2=${m2.toStringAsFixed(2)} '
        'speedup=${(m2 / m1).toStringAsFixed(2)}',
      );
    }
  }
  print('sink=$_sink');
}
