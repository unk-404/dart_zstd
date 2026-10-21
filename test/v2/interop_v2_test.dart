@TestOn('vm')
library;

// v2 encoder <-> libzstd interoperability. Requires ZSTD_REF to point at the
// dev-only Rust reference binary (see benchmark/rust_ref).

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zstd_neo/src/v2/compress/encoder.dart';

import '../fixtures/fixtures.g.dart';

void main() {
  final String? reference = Platform.environment['ZSTD_REF'];
  final String? skipReason = (reference == null || reference.isEmpty)
      ? 'ZSTD_REF is not set; point it at benchmark/rust_ref binary'
      : null;

  group('v2 interop', () {
    final String zstdRef = reference ?? '';
    late Directory tempDir;

    setUpAll(() {
      if (skipReason != null) return;
      expect(File(zstdRef).existsSync(), isTrue);
      tempDir = Directory('build/v2_interop_11552')
        ..createSync(recursive: true);
    });

    tearDownAll(() {
      if (skipReason == null) {
        tempDir.deleteSync(recursive: true);
      }
    });

    Uint8List rustDecode(Uint8List frame, {File? dictionary}) {
      final frameFile = File('${tempDir.path}/f.zst')..writeAsBytesSync(frame);
      final outFile = File('${tempDir.path}/f.bin');
      final args = <String>['decode', frameFile.path, outFile.path];
      if (dictionary != null) {
        args.addAll(['--dictionary', dictionary.path]);
      }
      final result = Process.runSync(zstdRef, args);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      return outFile.readAsBytesSync();
    }

    test('every level decodes byte-exactly with libzstd', () {
      final random = Random(2024);
      final data = Uint8List(48 * 1024);
      for (var i = 0; i < data.length; i++) {
        data[i] = random.nextInt(8) == 0 ? random.nextInt(256) : 0x61 + (i % 7);
      }
      for (var level = 1; level <= 19; level++) {
        final frame = ZstdV2Encoder(
          level: level,
          checksum: true,
        ).compress(data);
        expect(rustDecode(frame), data, reason: 'level $level');
      }
    });

    test('streaming frames decode with libzstd', () {
      final data = Uint8List.fromList(
        List<int>.generate(30000, (i) => 0x41 + (i * 13) % 26),
      );
      final collector = <int>[];
      final sink = ZstdV2Encoder(level: 5).startChunkedConversion(
        ByteConversionSink.withCallback(collector.addAll),
      );
      for (var i = 0; i < data.length; i += 1000) {
        sink.add(Uint8List.sublistView(data, i, min(i + 1000, data.length)));
      }
      sink.close();
      expect(rustDecode(Uint8List.fromList(collector)), data);
    });

    for (final name in <String>['rawdict', 'structdict']) {
      test('$name dictionary frames decode with libzstd', () {
        final fixture = webFixtures.firstWhere((f) => f.name == name);
        final dictionary = base64Decode(fixture.dictBase64!);
        final plain = base64Decode(fixture.binBase64);
        final dictionaryFile = File('${tempDir.path}/d.dict')
          ..writeAsBytesSync(dictionary);
        for (final level in <int>[3, 9, 19]) {
          final frame = ZstdV2Encoder(
            level: level,
            checksum: true,
            dictionary: dictionary,
          ).compress(plain);
          expect(
            rustDecode(frame, dictionary: dictionaryFile),
            plain,
            reason: 'level $level',
          );
        }
      });
    }
  }, skip: skipReason);
}
