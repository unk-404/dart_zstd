// Hardening fuzz for the v2 decoder engine.
//
// Every malformed or truncated input must surface as a ZstdException (the
// documented error type), never a RangeError/StateError/crash, and the decoder
// must not write outside the destination buffer. The destination is a view into
// a larger buffer with canary bytes after it, so an out-of-bounds store through
// the unchecked hot paths shows up as a changed canary.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zstd_neo/src/common/errors.dart';
import 'package:zstd_neo/src/v2/decompress/decoder.dart' as v2;

const int _canary = 64;
const int _cap = 1 << 20;
const int _canaryByte = 0xAB;

class _RunResult {
  _RunResult(this.error, this.canaryOk);

  final Object? error;
  final bool canaryOk;
}

_RunResult _run(Uint8List src, Random random) {
  // Random destination capacity in a plausible range so the decoder hits both
  // "output fits" and "output buffer too small" paths.
  final capacity = 1 + random.nextInt(_cap - _canary);
  final full = Uint8List(capacity + _canary);
  full.fillRange(capacity, full.length, _canaryByte);
  final dst = Uint8List.sublistView(full, 0, capacity);
  Object? error;
  try {
    v2.V2ZstdDecoder(maxWindowSize: 1 << 30).decodeInto(src, dst);
  } on ZstdException {
    error = null;
  } catch (e) {
    error = e;
  }
  var canaryOk = true;
  for (var i = capacity; i < full.length; i++) {
    if (full[i] != _canaryByte) {
      canaryOk = false;
      break;
    }
  }
  return _RunResult(error, canaryOk);
}

void main() {
  final manifest = jsonDecode(
    File('test/conformance/manifest.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final frames = (manifest['frames'] as List<dynamic>)
      .cast<Map<String, dynamic>>();

  test('mutated and truncated conformance frames only throw ZstdException', () {
    final random = Random(0xC0FFEE);
    final failures = <String>[];
    var cases = 0;
    for (final frame in frames) {
      final zst = File('test/conformance/${frame['zst']}').readAsBytesSync();
      for (var mutation = 0; mutation < 4; mutation++) {
        // 1) flip a random byte, 2) truncate, 3) splice random bytes in,
        // 4) append garbage.
        final mutated = Uint8List.fromList(zst);
        switch (mutation) {
          case 0:
            if (mutated.isNotEmpty) {
              final at = random.nextInt(mutated.length);
              mutated[at] ^= 1 << random.nextInt(8);
            }
          case 1:
            final keep = random.nextInt(mutated.length + 1);
            final truncated = Uint8List.sublistView(mutated, 0, keep);
            final r = _run(truncated, random);
            cases++;
            _check(r, '${frame['zst']} truncate@$keep', failures);
            continue;
          case 2:
            final at = random.nextInt(mutated.length + 1);
            final extra = List<int>.generate(
              1 + random.nextInt(32),
              (_) => random.nextInt(256),
            );
            final spliced = Uint8List.fromList([
              ...mutated.sublist(0, at),
              ...extra,
              ...mutated.sublist(at),
            ]);
            final r = _run(spliced, random);
            cases++;
            _check(r, '${frame['zst']} splice@$at', failures);
            continue;
          default:
            final extra = Uint8List(1 + random.nextInt(64));
            for (var i = 0; i < extra.length; i++) {
              extra[i] = random.nextInt(256);
            }
            final appended = Uint8List.fromList([...mutated, ...extra]);
            final r = _run(appended, random);
            cases++;
            _check(r, '${frame['zst']} append', failures);
            continue;
        }
        final r = _run(mutated, random);
        cases++;
        _check(r, '${frame['zst']} flip', failures);
      }
      if (failures.length > 12) break;
    }
    expect(
      failures,
      isEmpty,
      reason: '${failures.length}/$cases failures:\n${failures.join('\n')}',
    );
  });

  test('random byte streams only throw ZstdException', () {
    final random = Random(0xBADC0DE);
    final failures = <String>[];
    for (var i = 0; i < 400; i++) {
      final length = random.nextInt(4096);
      final src = Uint8List(length);
      for (var j = 0; j < length; j++) {
        src[j] = random.nextInt(256);
      }
      final r = _run(src, random);
      _check(r, 'random[$length]', failures);
      if (failures.length > 12) break;
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  });

  test('valid frames never touch the canary', () {
    for (final name in <String>['text_16k_l3', 'golden_rle_first_block']) {
      final zst = File('test/fixtures/$name.zst').readAsBytesSync();
      final bin = File('test/fixtures/$name.bin').readAsBytesSync();
      final full = Uint8List(bin.length + _canary);
      full.fillRange(bin.length, full.length, _canaryByte);
      final dst = Uint8List.sublistView(full, 0, bin.length);
      final written = v2.V2ZstdDecoder().decodeInto(zst, dst);
      expect(written, bin.length);
      expect(Uint8List.sublistView(full, 0, written), bin);
      for (var i = bin.length; i < full.length; i++) {
        expect(full[i], _canaryByte, reason: 'canary byte $i');
      }
    }
  });
}

void _check(_RunResult r, String label, List<String> failures) {
  if (r.error != null) {
    failures.add('$label: ${r.error.runtimeType}: ${r.error}');
  }
  if (!r.canaryOk) {
    failures.add('$label: destination canary was overwritten');
  }
}
