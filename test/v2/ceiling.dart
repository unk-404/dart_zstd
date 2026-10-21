// Dev-only ceiling probe: how fast can pure Dart do just the per-position
// work of a double-fast match finder (two hashes + two table updates)?
// Compile with `dart compile exe test/v2/ceiling.dart -o build/perf/ceiling.exe`.
import 'dart:typed_data';

const int prime4 = 0x9E3779B1;
const int prime8 = 0xCF1BBCDCB7A56463;

// ignore: unused_element
int _acc = 0;

double bestNsPerPosition(int positions, void Function() body) {
  for (var i = 0; i < 10; i++) {
    body();
  }
  var best = double.infinity;
  for (var i = 0; i < 30; i++) {
    final sw = Stopwatch()..start();
    body();
    sw.stop();
    final ns = sw.elapsedMicroseconds * 1000 / positions;
    if (ns < best) best = ns;
  }
  return best;
}

void main() {
  final data = Uint8List(256 * 1024);
  for (var i = 0; i < data.length; i++) {
    data[i] = (i * 31 + (i >> 7)) & 0xFF;
  }
  final view = ByteData.sublistView(data);
  final n = data.length - 8;
  final longTable = Uint32List(1 << 16);
  final shortTable = Uint32List(1 << 16);

  final hashOnly = bestNsPerPosition(n, () {
    var acc = 0;
    for (var i = 0; i < n; i++) {
      final w = view.getUint32(i, Endian.little);
      acc ^= ((w * prime4) & 0xFFFFFFFF) >>> 12;
    }
    _acc = acc;
  });
  final dfastLoop = bestNsPerPosition(n, () {
    var acc = 0;
    for (var i = 0; i < n; i++) {
      final w0 = view.getUint32(i, Endian.little);
      final w1 = view.getUint32(i + 4, Endian.little);
      final u = w0 | (w1 << 32);
      final hLong = ((u * prime8) >>> (64 - 16)) & 0xFFFF;
      final hShort = ((w0 * prime4) & 0xFFFFFFFF) >>> 16;
      final previousLong = longTable[hLong];
      longTable[hLong] = i + 1;
      final previousShort = shortTable[hShort];
      shortTable[hShort] = i + 1;
      acc ^= previousLong ^ previousShort;
    }
    _acc = acc;
  });
  final byteReadLoop = bestNsPerPosition(n, () {
    var acc = 0;
    for (var i = 0; i < n; i++) {
      final w =
          data[i] |
          (data[i + 1] << 8) |
          (data[i + 2] << 16) |
          (data[i + 3] * 0x1000000);
      acc ^= w;
    }
    _acc = acc;
  });
  print(
    'hashOnly    ${hashOnly.toStringAsFixed(2)} ns/pos '
    '(${(0.25 / (hashOnly * n / 1e9)).toStringAsFixed(0)} MiB/s)',
  );
  print(
    'dfastLoop   ${dfastLoop.toStringAsFixed(2)} ns/pos '
    '(${(0.25 / (dfastLoop * n / 1e9)).toStringAsFixed(0)} MiB/s)',
  );
  print('byteReads   ${byteReadLoop.toStringAsFixed(2)} ns/pos');
}
