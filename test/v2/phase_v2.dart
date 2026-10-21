// Dev-only phase profiler for the v2 encoder: how much of the compression
// time is match finding vs literals/entropy coding.
import 'dart:convert';
import 'dart:typed_data';

import 'package:zstd_neo/src/v2/compress/block_encoder.dart';
import 'package:zstd_neo/src/v2/compress/byte_writer.dart';
import 'package:zstd_neo/src/v2/compress/match_finder.dart';
import 'package:zstd_neo/src/v2/compress/sequences.dart';

import '../../benchmark/bench_data.g.dart';

void main() {
  final plains = <String, Uint8List>{};
  for (final file in benchData) {
    if (file.kind == 'plain') plains[file.corpus] = base64Decode(file.base64);
  }
  final corpora = plains.keys.toList()..sort();
  for (final level in <int>[3, 9, 19]) {
    final params = compressionParametersFor(level, 256 * 1024);
    print(
      'L$level strategy=${params.strategy.name} '
      'hashLog=${params.hashLog} chainLog=${params.chainLog} '
      'searchDepth=${params.searchDepth} minMatch=${params.minMatch}',
    );
    for (final corpus in corpora) {
      final input = plains[corpus]!;
      final matcher = MatchFinder(params);
      final store = SequenceStore(params.blockSize ~/ 4 + 8);

      int find() {
        var sequences = 0;
        for (var pos = 0; pos < input.length; pos += params.blockSize) {
          final end = pos + params.blockSize < input.length
              ? pos + params.blockSize
              : input.length;
          store.clear();
          matcher.findMatches(input, pos, end, const [1, 4, 8], store);
          sequences += store.count;
        }
        return sequences;
      }

      int encode() {
        final encoder = BlockEncoder(params);
        final out = ByteWriter(300000);
        for (var pos = 0; pos < input.length; pos += params.blockSize) {
          final end = pos + params.blockSize < input.length
              ? pos + params.blockSize
              : input.length;
          encoder.writeBlock(out, input, pos, end, last: end == input.length);
        }
        return out.length;
      }

      for (var i = 0; i < 4; i++) {
        find();
      }
      var bestFind = 1 << 30;
      var seqs = 0;
      for (var i = 0; i < 8; i++) {
        final sw = Stopwatch()..start();
        seqs = find();
        sw.stop();
        if (sw.elapsedMicroseconds < bestFind) {
          bestFind = sw.elapsedMicroseconds;
        }
      }
      final encoderSize = encode();
      for (var i = 0; i < 4; i++) {
        encode();
      }
      var bestFull = 1 << 30;
      for (var i = 0; i < 8; i++) {
        final sw = Stopwatch()..start();
        encode();
        sw.stop();
        if (sw.elapsedMicroseconds < bestFull) {
          bestFull = sw.elapsedMicroseconds;
        }
      }
      final findMiB = 0.25 / (bestFind / 1e6);
      final fullMiB = 0.25 / (bestFull / 1e6);
      final nsPerPosition = bestFind * 1000 / input.length;
      print(
        '$corpus L$level matchFind=${findMiB.toStringAsFixed(1)} MiB/s '
        'full=${fullMiB.toStringAsFixed(1)} MiB/s '
        'share=${(bestFind / bestFull * 100).toStringAsFixed(0)}% '
        'ns/pos=${nsPerPosition.toStringAsFixed(2)} '
        'seqs=$seqs size=$encoderSize',
      );
    }
  }
}
