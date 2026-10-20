# zstd_ref

Dev-only Rust reference harness for the pure-Dart [`zstd_neo`](../../) codec.

It wraps libzstd (through the [`zstd`](https://crates.io/crates/zstd) crate) and
does two jobs:

1. produce/verify the committed interoperability fixtures in
   [`test/fixtures/`](../../test/fixtures/), and
2. act as the independent decoder/encoder in the `interop` CI job and in
   `test/interop_test.dart`.

**This crate is not part of the published Dart package.** Nothing under
`lib/` or the default `dart test` path may depend on it; only the dedicated
interop job builds it and exports `ZSTD_REF` pointing at the binary.

```text
$ cargo build --release
$ target/release/zstd_ref version
zstd_ref 0.1.0 (zstd crate 0.14, libzstd 1.5.7)
```

## Commands

```text
zstd_ref encode <in> <out> [--level N] [--checksum] [--no-content-size]
                           [--dictionary FILE]
zstd_ref decode <in> <out> [--dictionary FILE]
zstd_ref gen-fixtures [--out DIR] [--corpus DIR] [--zstd-tests DIR]
zstd_ref bench-data [--out DIR] [--corpus DIR] [--dart-out FILE]
zstd_ref bench [--data DIR] [--out FILE]
zstd_ref version
```

`encode` writes exactly one complete frame:

* `--level N` — zstd level (`3` by default; fixtures use `1/3/9/19`);
* `--checksum` — append the 4-byte XXH64 content checksum;
* `--no-content-size` — omit `Frame_Content_Size` from the frame header
  (the encoder explicitly pledges the source size first, so the flag has a
  well-defined effect);
* `--dictionary FILE` — raw-content **or** structured dictionary; libzstd
  auto-detects which.

`decode` handles a single frame, concatenated frames and skippable frames, and
takes the same optional `--dictionary`.

`gen-fixtures` writes the deterministic fixture matrix (levels, checksum,
content-size, multi-frame, skippable, raw/structured dictionaries), copies the
official zstd golden/error samples when a local zstd test checkout is provided
via `--zstd-tests`, and regenerates `test/fixtures/fixtures.g.dart`. It decodes
every frame with libzstd and aborts on any mismatch, so the fixture set is
self-checking.

```text
# from the repository root
cargo run --release --manifest-path benchmark/rust_ref/Cargo.toml -- gen-fixtures
dart format test/fixtures/fixtures.g.dart
```

Paths in `gen-fixtures` default to the repository layout
(`--out test/fixtures`, `--corpus benchmark/corpus/silesia`,
`--zstd-tests test/zstd-tests`); pass `--corpus`/`--zstd-tests` when running
from elsewhere. Missing official zstd vectors only produce a warning, so the
crate can be built and used by CI without a zstd source checkout.

## Benchmark data and series

`bench-data` writes the deterministic 256 KiB benchmark slices to
`benchmark/bench_data/`:

| file | contents |
| --- | --- |
| `<corpus>.bin` | first 262,144 bytes of dickens / xml / x-ray / osdb |
| `<corpus>.l3.zst` | libzstd level 3 frame, content checksum on |
| `<corpus>.l19.zst` | libzstd level 19 frame, content checksum on |
| `manifest.json` | ids, source paths, byte counts and frame sizes |

It also embeds all twelve files as base64 in
[`benchmark/bench_data.g.dart`](../bench_data.g.dart), which imports nothing so
the Dart web benchmark can use it. Every frame is decoded with libzstd and
compared with its slice before anything is written.

`bench` reads that manifest, measures level-3 compression, level-3
decompression, level-19 decompression and the level-3 ratio, and writes
canonical JSONL for the chart:

```sh
cargo run --release --manifest-path benchmark/rust_ref/Cargo.toml -- bench-data
cargo run --release --manifest-path benchmark/rust_ref/Cargo.toml -- bench
dart format benchmark/bench_data.g.dart
```

`bench` defaults to `--data benchmark/bench_data` and
`--out build/bench/series-rust.jsonl`. Each operation runs three warm-up
iterations, then repetitions until at least 300 ms elapsed or 200 repetitions.
Throughput is MiB/s of plaintext; `ratio.<corpus>.l3` is compressed/original
and is marked `direction = "lower"`.

## Why no `clap`?

The CLI is deliberately dependency-light: `zstd` is the only dependency. The
argument parser is a few dozen lines in `src/main.rs`; `serde_json` is not
needed because the browser-safe fixture data is emitted directly as Dart
source (`src/fixtures.rs`).

## Files

| path | purpose |
| --- | --- |
| `src/main.rs` | CLI, frame encode/decode helpers |
| `src/fixtures.rs` | deterministic fixture matrix + `fixtures.g.dart` emitter |
| `src/bench_data.rs` | Silesia slices, L3/L19 frames, manifest + `bench_data.g.dart` emitter |
| `src/bench.rs` | libzstd measurements, canonical JSONL series |
| `src/base64.rs` | minimal standard base64 encoder (no dependency) |

See [`test/fixtures/README.md`](../../test/fixtures/README.md) for fixture
provenance, sizes and licenses.
