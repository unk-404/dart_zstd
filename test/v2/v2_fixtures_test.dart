// v2 decoder development tests against the shared fixture matrix.
//
// The fixtures are produced by the Rust reference harness and committed as
// `.zst`/`.bin` pairs, so this test is VM-only (dart:io).
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zstd_neo/src/v2/decompress/decoder.dart' as v2;

const int _slack = 1 << 17;

Uint8List _read(String name) => File('test/fixtures/$name').readAsBytesSync();

void _expectFrame(String name, {String? dictionary}) {
  final zst = _read('$name.zst');
  final bin = _read('$name.bin');
  final decoder = v2.V2ZstdDecoder(
    dictionary: dictionary == null ? null : _read(dictionary),
    maxWindowSize: 1 << 30,
  );
  final dst = Uint8List(bin.length + _slack);
  final written = decoder.decodeInto(zst, dst);
  expect(written, bin.length, reason: name);
  expect(Uint8List.sublistView(dst, 0, written), bin, reason: name);
}

void main() {
  test('v2 decodes one-shot fixtures', () {
    for (final name in <String>[
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
      'golden_block_128k',
      'golden_empty_block',
      'golden_rle_first_block',
      'golden_zero_seq_2b',
      'silesia_dickens_64k',
      'silesia_xml_64k',
      'silesia_osdb_64k',
      'silesia_xray_64k',
      'text_256k_l3',
    ]) {
      _expectFrame(name);
    }
  });

  test('v2 decodes raw and structured dictionary fixtures', () {
    _expectFrame('rawdict', dictionary: 'rawdict.dict');
    _expectFrame('structdict', dictionary: 'structdict.dict');
  });

  test('v2 decompress() convenience matches decodeInto', () {
    final zst = _read('text_16k_l3.zst');
    final bin = _read('text_16k_l3.bin');
    final out = v2.V2ZstdDecoder().decompress(zst);
    expect(out, bin);
  });

  test('v2 rejects a corrupted checksum', () {
    final zst = Uint8List.fromList(_read('text_4k_checksum.zst'));
    zst[zst.length - 1] ^= 0xFF;
    expect(
      () => v2.V2ZstdDecoder().decodeInto(zst, Uint8List(1 << 16)),
      throwsA(isA<Exception>()),
    );
  });
}
