# Interoperability fixtures

Reference Zstandard frames and their exact plaintext, used by the Dart test
suite and by the dev-only Rust harness under [`benchmark/rust_ref`](../../benchmark/rust_ref/).

These files are **data**, not part of the published package. Nothing here
requires Rust at test time: the `.zst`/`.bin` files are committed, and the
browser-safe subset is embedded in [`fixtures.g.dart`](fixtures.g.dart).

## Layout

| pattern | meaning |
| --- | --- |
| `<name>.zst` | one zstd frame (or a concatenation of frames/skippable frames) |
| `<name>.bin` | the exact plaintext `<name>.zst` must decode to |
| `<name>.dict` | dictionary bytes required to decode `<name>.zst` |
| `malformed_<name>.zst` | input a conforming decoder must reject (there is no `.bin`) |
| `fixtures.g.dart` | generated base64 constants + expected lengths (imports nothing) |

Decoder rules used by `test/interop_test.dart`:

* every `*.zst` with a sibling `*.bin` must decode to that `.bin`;
* if a sibling `*.dict` exists, the decoder must be given that dictionary;
* every `malformed_*.zst` must throw.

Frames without a registered content size (`json_4k_nocontentsize`) and frames
with a checksum (`text_4k_checksum`) are marked by name, but the decoder must
infer all of it from the frame header.

## Provenance

All frames were produced by **libzstd 1.5.7**, reached through the
[`zstd` 0.14.3 Rust crate](https://crates.io/crates/zstd) and the CLI in
`benchmark/rust_ref`:

```text
$ benchmark/rust_ref/target/release/zstd_ref.exe version
zstd_ref 0.1.0 (zstd crate 0.14, libzstd 1.5.7)
```

Regenerate (deterministic for a given libzstd version, from the repository
root):

```text
cargo run --release --manifest-path benchmark/rust_ref/Cargo.toml -- gen-fixtures \
  --out test/fixtures --zstd-tests <path-to-zstd-checkout>/tests
dart format test/fixtures/fixtures.g.dart
```

`--zstd-tests` is optional; omit it to regenerate only the synthetic frames.
The committed `golden_*`/`malformed_*` bytes are the source of truth.

`gen-fixtures` decodes every generated frame with libzstd and aborts on any
round-trip mismatch, so a committed fixture set is self-checking.

Inputs are generated deterministically in `benchmark/rust_ref/src/fixtures.rs`
with a SplitMix64 stream: repeated word text, a JSON array of records, a
fixed-size binary record stream, all-zero data and uniform pseudo-random bytes.
There are no timestamps or random seeds in the output.

### Official zstd test vectors

The `golden_*` and `malformed_*` files are byte-for-byte copies of the zstd
project's own test vectors, from a local checkout of zstd at
`zstd 1.6.0-dev` (not shipped):

| fixture | original file |
| --- | --- |
| `golden_block_128k.zst` | `tests/golden-decompression/block-128k.zst` |
| `golden_empty_block.zst` | `tests/golden-decompression/empty-block.zst` |
| `golden_rle_first_block.zst` | `tests/golden-decompression/rle-first-block.zst` |
| `golden_zero_seq_2b.zst` | `tests/golden-decompression/zeroSeq_2B.zst` |
| `malformed_off0.zst` | `tests/golden-decompression-errors/off0.bin.zst` |
| `malformed_truncated_huff_state.zst` | `tests/golden-decompression-errors/truncated_huff_state.zst` |
| `malformed_zero_seq_extraneous.zst` | `tests/golden-decompression-errors/zeroSeq_extraneous.zst` |

Their `.bin` plaintexts were produced by decoding the valid frames with
libzstd 1.5.7. Note that `golden_rle_first_block.zst` is 45 bytes but expands
to 1 MiB of RLE data — it is intentionally kept out of the base64 subset.

### Silesia corpus

`silesia_dickens_64k`, `silesia_xml_64k`, `silesia_xray_64k` and
`silesia_osdb_64k` are the **first 64 KiB** of the corresponding files in
[`benchmark/corpus/silesia/`](../../benchmark/corpus/silesia/), which is the
unmodified Silesia compression corpus by Sebastian Deorowicz (see
[`benchmark/corpus/README.md`](../../benchmark/corpus/README.md) for source,
hashes and per-file provenance). They are used for benchmarking only, are not
redistributed through pub.dev (`.pubignore` excludes the corpus), and remain
subject to their original provenance/license as documented there.

## Fixture matrix

Generated frames (25, including 3 malformed):

| fixture | zst bytes | bin bytes | dict bytes | covers |
| --- | ---: | ---: | ---: | --- |
| `text_16k_l1` | 1,436 | 16,384 | – | level 1 |
| `text_16k_l3` | 1,147 | 16,384 | – | level 3 |
| `text_16k_l9` | 720 | 16,384 | – | level 9 |
| `text_16k_l19` | 490 | 16,384 | – | level 19 (btopt literals/sequences) |
| `text_4k_checksum` | 582 | 4,096 | – | checksum on |
| `text_4k_nochecksum` | 578 | 4,096 | – | checksum off |
| `json_4k_contentsize` | 442 | 4,014 | – | Frame_Content_Size present |
| `json_4k_nocontentsize` | 441 | 4,014 | – | Frame_Content_Size absent |
| `multiframe` | 1,678 | 16,384 | – | two concatenated frames (L1 + L9, checksum) |
| `skippable_prefix` | 619 | 4,096 | – | skippable frame before a zstd frame |
| `skippable_between` | 1,058 | 8,110 | – | skippable frame between two zstd frames |
| `silesia_dickens_64k` | 27,128 | 65,536 | – | English text, level 3 |
| `silesia_xml_64k` | 6,099 | 65,536 | – | XML, level 3 |
| `silesia_xray_64k` | 51,729 | 65,536 | – | incompressible image data, level 3 |
| `silesia_osdb_64k` | 27,292 | 65,536 | – | database dump, level 3 |
| `text_256k_l3` | 1,159 | 262,144 | – | multi-block (>128 KiB) text, level 3 |
| `rawdict` | 7,109 | 16,384 | 8,192 | raw-content dictionary |
| `structdict` | 7,070 | 16,384 | 8,192 | trained (structured) dictionary, dictionary id in header |
| `golden_block_128k` | 131,081 | 131,068 | – | official: 128 KiB incompressible block |
| `golden_empty_block` | 11 | 0 | – | official: empty frame |
| `golden_rle_first_block` | 45 | 1,048,576 | – | official: RLE block, 1 MiB plaintext |
| `golden_zero_seq_2b` | 25 | 13 | – | official: 2-byte sequences edge case |
| `malformed_off0` | 17 | – | – | official: offset 0 (must reject) |
| `malformed_truncated_huff_state` | 19 | – | – | official: truncated Huffman state (must reject) |
| `malformed_zero_seq_extraneous` | 27 | – | – | official: extraneous sequences bytes (must reject) |

Deterministic inputs without a matching frame:

| fixture | bytes | content |
| --- | ---: | --- |
| `empty` | 0 | empty input |
| `one_byte` | 1 | `0x00` |
| `three_bytes` | 3 | `abc` |
| `bytes_256` | 256 | bytes `0x00..0xff` |
| `text_4k` | 4,096 | repeated words |
| `json_4k` | 4,014 | JSON array of records |
| `binary_4k` | 4,096 | fixed-size binary records |
| `text_16k` | 16,384 | repeated words |
| `text_64k` | 65,536 | repeated words |
| `json_64k` | 65,443 | JSON array of records |
| `binary_64k` | 65,536 | fixed-size binary records |
| `zeros_64k` | 65,536 | all zero bytes |
| `random_64k` | 65,536 | SplitMix64 pseudo-random bytes |

Total committed fixture payload (`.zst` + `.bin` + `.dict`, including the
generated Dart constants which are roughly 0.3 MB): about **2.8 MB**. All of
it is tracked in git; the VM tests read the files directly.

## Browser-safe subset (`fixtures.g.dart`)

`gen-fixtures` embeds a frame when `zst + bin + dict <= 32 KiB`, plus every
deterministic input of at most 8 KiB. This keeps the `.g.dart` file well under
2 MB while still covering

* empty / 1-byte / 3-byte / 256-byte / 4 KiB inputs,
* all four compression levels,
* checksum on/off,
* content size present/absent,
* multi-frame and both skippable-frame placements,
* raw and structured dictionaries (dictionary bytes included as base64),
* the official empty-block and 2-byte-sequence frames, and all malformed
  samples.

Large VM-only fixtures (`text_64k`, `text_256k_l3`, the 64 KiB Silesia
frames, the 128 KiB official block and the 1 MiB RLE expansion) are read from
disk by `test/interop_test.dart` instead.

## Licenses

* The generator code (`benchmark/rust_ref/`) is MIT, like the rest of this
  repository.
* Frames derived from the zstd test suite and the zstd format itself are
  BSD-3-Clause, © Meta Platforms, Inc. and affiliates (see the zstd
  `LICENSE` upstream; it is not shipped here).
* The Silesia corpus slices remain under the provenance of the original
  corpus files; see `benchmark/corpus/README.md`.
* The deterministic synthetic inputs and generated base64 constants are
  original to this repository (MIT).

The zstd project's BSD-3-Clause notice applies to `golden_*`/`malformed_*`
files. If you redistribute this repository, keep this file with them.
