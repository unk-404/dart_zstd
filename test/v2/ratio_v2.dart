// Prints v1 vs v2 compressed sizes on the committed Silesia slices.
import 'dart:convert';
import 'dart:typed_data';

import 'package:zstd_neo/src/compress/encoder.dart' as v1;
import 'package:zstd_neo/src/v2/compress/encoder.dart';

import '../../benchmark/bench_data.g.dart';

void main() {
  final plains = <String, Uint8List>{};
  for (final file in benchData) {
    if (file.kind == 'plain') plains[file.corpus] = base64Decode(file.base64);
  }
  for (final level in <int>[3, 9, 19]) {
    var s1 = 0;
    var s2 = 0;
    for (final corpus in plains.keys.toList()..sort()) {
      final input = plains[corpus]!;
      final a = v1.ZstdEncoder(level: level).compress(input).length;
      final b = ZstdV2Encoder(level: level).compress(input).length;
      s1 += a;
      s2 += b;
      print(
        '$corpus L$level v1=$a v2=$b gap=${((b - a) / a * 100).toStringAsFixed(2)}%',
      );
    }
    print(
      'TOTAL L$level v1=$s1 v2=$s2 gap=${((s2 - s1) / s1 * 100).toStringAsFixed(2)}%',
    );
  }
}
