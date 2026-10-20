@TestOn('vm')
library;

// Cross-implementation interoperability tests.
//
// These tests need an independent zstd implementation, so they only run when
// `ZSTD_REF` points at the dev-only Rust binary (see benchmark/rust_ref):
//
//   cargo build --release --manifest-path benchmark/rust_ref/Cargo.toml
//   ZSTD_REF=$PWD/benchmark/rust_ref/target/release/zstd_ref dart test test/interop_test.dart
//
// Without `ZSTD_REF` every test in this file is skipped, so the default
// `dart test` run never requires Rust.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zstd_neo/zstd_neo.dart';

import 'fixtures/fixtures.g.dart';

const String _fixturesDir = 'test/fixtures';

void main() {
  final String? reference = Platform.environment['ZSTD_REF'];
  final String? skipReason = (reference == null || reference.isEmpty)
      ? 'ZSTD_REF is not set; point it at the built benchmark/rust_ref binary '
            'to run interoperability tests'
      : null;

  group('interop', () {
    final String zstdRef = reference ?? '';

    setUpAll(() {
      expect(
        File(zstdRef).existsSync(),
        isTrue,
        reason: 'ZSTD_REF points at a file that does not exist: $zstdRef',
      );
      expect(
        Directory(_fixturesDir).existsSync(),
        isTrue,
        reason: 'missing fixture directory $_fixturesDir',
      );
    });

    test('fixture inventory is complete and self-consistent', () {
      final frames = _committedFrames();
      expect(frames, isNotEmpty);

      final malformed = <String>{};
      for (final file in _zstFiles()) {
        final stem = _stem(file);
        final plaintext = _sibling(file, 'bin');
        if (stem.startsWith('malformed_')) {
          malformed.add(stem);
          expect(
            plaintext.existsSync(),
            isFalse,
            reason: 'malformed fixture $stem must not have a .bin',
          );
          continue;
        }
        expect(
          plaintext.existsSync(),
          isTrue,
          reason: 'missing expected plaintext for $stem',
        );
      }

      expect(
        malformed,
        equals(malformedFixtures.map((fixture) => fixture.name).toSet()),
        reason: 'malformed fixtures on disk and in fixtures.g.dart disagree',
      );
      expect(
        frames.map(_stem),
        containsAll(<String>[
          'text_16k_l1',
          'text_16k_l3',
          'text_16k_l9',
          'text_16k_l19',
          'text_4k_checksum',
          'text_4k_nochecksum',
          'json_4k_contentsize',
          'json_4k_nocontentsize',
          'multiframe',
          'skippable_prefix',
          'skippable_between',
          'rawdict',
          'structdict',
        ]),
      );

      expect(webFixtures, isNotEmpty);
      for (final fixture in webFixtures) {
        expect(
          base64Decode(fixture.zstBase64),
          hasLength(fixture.zstLength),
          reason: 'zst length mismatch for ${fixture.name}',
        );
        expect(
          base64Decode(fixture.binBase64),
          hasLength(fixture.binLength),
          reason: 'bin length mismatch for ${fixture.name}',
        );
        if (fixture.dictBase64 != null) {
          expect(
            base64Decode(fixture.dictBase64!),
            hasLength(fixture.dictLength),
            reason: 'dict length mismatch for ${fixture.name}',
          );
        }
      }
      for (final input in webInputs) {
        expect(
          base64Decode(input.binBase64),
          hasLength(input.binLength),
          reason: 'input length mismatch for ${input.name}',
        );
      }
    });

    test('libzstd fixtures decode with ZstdDecoder', () {
      final frames = _committedFrames();
      expect(frames, isNotEmpty);

      for (final file in frames) {
        final stem = _stem(file);
        final encoded = file.readAsBytesSync();
        final expected = _sibling(file, 'bin').readAsBytesSync();
        final dictionaryFile = _sibling(file, 'dict');
        final dictionary = dictionaryFile.existsSync()
            ? dictionaryFile.readAsBytesSync()
            : null;

        final decoded = ZstdDecoder(dictionary: dictionary).decompress(encoded);
        expect(decoded, equals(expected), reason: 'fixture $stem');
      }
    });

    test('base64 fixtures decode with ZstdDecoder (browser path)', () {
      expect(webFixtures, isNotEmpty);

      for (final fixture in webFixtures) {
        final dictionary = fixture.dictBase64 == null
            ? null
            : base64Decode(fixture.dictBase64!);
        final decoded = ZstdDecoder(dictionary: dictionary)
            .decompress(base64Decode(fixture.zstBase64));
        expect(
          decoded,
          equals(base64Decode(fixture.binBase64)),
          reason: 'fixture ${fixture.name}',
        );
      }
    });

    test('dictionary frames need their dictionary', () {
      final structured = File('$_fixturesDir/structdict.zst').readAsBytesSync();
      expect(
        () => ZstdDecoder().decompress(structured),
        throwsA(isA<ZstdException>()),
        reason: 'a structured dictionary frame must not decode without it',
      );
    });

    test('Dart encoder output is accepted by the Rust decoder', () async {
      // Keep scratch files inside the repository: on some sandboxed dev
      // machines the Rust child process cannot write to the system temp dir,
      // and `benchmark/.out/` is already gitignored.
      final scratch = Directory('benchmark/.out/interop')
        ..createSync(recursive: true);
      final temp = Directory(
        '${scratch.path}/${DateTime.now().microsecondsSinceEpoch}',
      )..createSync(recursive: true);
      addTearDown(() => temp.deleteSync(recursive: true));

      final encoder = ZstdEncoder(level: 3, checksum: true);
      try {
        encoder.compress(Uint8List(0));
      } on UnsupportedError catch (error) {
        markTestSkipped('Dart encoder is not implemented yet: $error');
        return;
      } on ZstdException catch (error) {
        if (error.code != ZstdErrorCode.unsupportedFeature) {
          rethrow;
        }
        markTestSkipped('Dart encoder is not implemented yet: $error');
        return;
      }

      for (final sample in _encoderSamples()) {
        final compressed = encoder.compress(sample.bytes);
        final tempPath = temp.absolute.path;
        final compressedFile = File('$tempPath/${sample.name}.zst')
          ..writeAsBytesSync(compressed);
        final decodedFile = File('$tempPath/${sample.name}.decoded');

        final result = await Process.run(zstdRef, <String>[
          'decode',
          compressedFile.path,
          decodedFile.path,
        ]);
        expect(
          result.exitCode,
          0,
          reason:
              'Rust failed to decode Dart output for ${sample.name}: '
              '${result.stderr}',
        );
        expect(
          decodedFile.readAsBytesSync(),
          equals(sample.bytes),
          reason: 'Dart -> Rust round trip for ${sample.name}',
        );

        // The encoded frame must not be empty and must carry the zstd magic.
        expect(compressed.length, greaterThan(4), reason: sample.name);
        expect(
          compressed.sublist(0, 4),
          equals(<int>[0x28, 0xb5, 0x2f, 0xfd]),
          reason: 'frame magic for ${sample.name}',
        );
      }
    });

    test('malformed frames are rejected', () {
      expect(malformedFixtures, isNotEmpty);
      for (final fixture in malformedFixtures) {
        expect(
          () => ZstdDecoder().decompress(base64Decode(fixture.zstBase64)),
          throwsA(anything),
          reason: 'malformed fixture ${fixture.name}',
        );
      }

      // A truncated valid frame must fail rather than return partial output.
      final valid = File('$_fixturesDir/text_16k_l3.zst').readAsBytesSync();
      expect(
        () => ZstdDecoder().decompress(
          Uint8List.sublistView(valid, 0, valid.length ~/ 2),
        ),
        throwsA(anything),
        reason: 'truncated frame',
      );

      // A corrupted content checksum must be detected.
      final checksum = Uint8List.fromList(
        File('$_fixturesDir/text_4k_checksum.zst').readAsBytesSync(),
      );
      checksum[checksum.length - 1] ^= 0xff;
      expect(
        () => ZstdDecoder().decompress(checksum),
        throwsA(anything),
        reason: 'corrupted checksum',
      );
    });
  }, skip: skipReason);
}

/// A named plaintext sample for the encoder direction of the round trip.
final class _Sample {
  const _Sample(this.name, this.bytes);

  final String name;
  final Uint8List bytes;
}

List<_Sample> _encoderSamples() {
  final samples = <_Sample>[
    for (final input in webInputs)
      _Sample('dart_${input.name}', base64Decode(input.binBase64)),
  ];
  final large = File('$_fixturesDir/text_64k.bin');
  if (large.existsSync()) {
    samples.add(_Sample('dart_text_64k', large.readAsBytesSync()));
  }
  return samples;
}

List<File> _zstFiles() {
  final files =
      Directory(_fixturesDir)
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.zst'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return files;
}

List<File> _committedFrames() =>
    _zstFiles().where((file) => !_stem(file).startsWith('malformed_')).toList();

String _stem(File file) {
  final name = file.uri.pathSegments.last;
  return name.substring(0, name.length - '.zst'.length);
}

File _sibling(File zst, String extension) {
  final path = zst.path;
  return File('${path.substring(0, path.length - '.zst'.length)}.$extension');
}
