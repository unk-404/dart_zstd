# Benchmark harness

Development-only benchmark pipeline for `zstd_neo`: one benchcat card
comparing the pure-Dart codec (AOT, dart2js, dart2wasm) with libzstd through
the Rust reference crate in [`rust_ref/`](rust_ref/).

Nothing here is part of the published package (`.pubignore` excludes
`benchmark/`), and no Rust binary is needed at test time.

## Data

[`bench_data/`](bench_data/) is generated deterministically from the first
256 KiB of four [Silesia corpus](corpus/README.md) files:

| corpus | source | plaintext | L3 frame | L19 frame |
| --- | --- | ---: | ---: | ---: |
| `dickens` | English text | 262,144 B | 101,735 B | 86,985 B |
| `xml` | XML | 262,144 B | 20,285 B | 12,998 B |
| `x-ray` | medical image | 262,144 B | 190,622 B | 165,397 B |
| `osdb` | database dump | 262,144 B | 96,616 B | 91,631 B |

The `.l3.zst`/`.l19.zst` frames are libzstd level 3/19 with the content
checksum enabled, and `manifest.json` records ids, source paths, sizes and
frame lengths. [`bench_data.g.dart`](bench_data.g.dart) embeds all twelve
files as base64 so the web benchmark needs no `dart:io`. Both directories are
committed because CI consumes them and does not regenerate the data.

Regenerate from the repository root (the generator decodes every frame with
libzstd and aborts on a mismatch, so the data is self-checking):

```sh
cargo run --release --manifest-path benchmark/rust_ref/Cargo.toml -- bench-data
dart format benchmark/bench_data.g.dart
```

## Pipeline

```sh
# libzstd reference (canonical JSONL, 4 corpora x 8 metrics)
cargo run --release --manifest-path benchmark/rust_ref/Cargo.toml -- bench

# Dart VM/AOT benchmark_test JSONL
mkdir -p build/bench
dart run benchmark_test --compile aot --output jsonl \
  benchmark/benchmark_test.dart > build/bench/raw-dart-aot.jsonl

# Dart web series (CI only; needs Chrome)
dart run benchmark_test --compile js --output jsonl \
  benchmark/benchmark_test.dart > build/bench/raw-dart-js.jsonl
dart run benchmark_test --compile wasm --output jsonl \
  benchmark/benchmark_test.dart > build/bench/raw-dart-wasm.jsonl

# normalize into the four canonical series
dart run benchmark/report.dart
```

`report.dart` reads `build/bench/raw-dart-{aot,js,wasm}.jsonl` and
`build/bench/series-rust.jsonl` by default, writes
`build/bench/series-dart-{aot,js,wasm}.jsonl` and `series-rust.jsonl`, and
fails on missing AOT/Rust inputs. The js/wasm inputs are optional so a local
run can validate the AOT path without a browser; missing ones are skipped with
a warning.

`benchmark_test --output jsonl` interleaves its test-reporter progress with the
records, so `report.dart` only parses lines that start with `{` and still
enforces the exact id set for each series.

## Records

Each canonical line is one benchmark record:

```json
{"id":"compress.dickens.l9","group":"Compress · L9","label":"dickens","unit":"MiB/s","value":6.473736,"stats":{"rme_pct":2.1772,"samples":100}}
{"id":"ratio.dickens.l19","group":"Ratio · L19","label":"dickens","unit":"x","direction":"lower","value":0.352791,"stats":{"rme_pct":0.0,"samples":1}}
```

* `compress.<corpus>.l3` / `.l9` / `.l19` — MiB/s of plaintext;
* `decompress.<corpus>.l3` / `.l19` — MiB/s of decompressed plaintext, from
  the committed L3/L19 frames;
* `ratio.<corpus>.l3` / `.l9` / `.l19` — compressed/original, lower is
  better; AOT only.

That is 20 throughput rows plus 12 ratio rows (32) for the AOT and Rust
series, and 20 rows for each Web series. L9 frames are not committed: the L9
ratio is measured by compressing in `bench` and in `report.dart` instead.

The Rust harness runs three warm-up iterations, then repetitions until at least
300 ms elapsed or 200 repetitions; `stats.rme_pct` is the approximate 95%
relative margin of error. `benchmark_test` runs with `minDuration` 500 ms,
`minSamples` 10, `targetRme` 2 and `maxSamples` 100.

## Chart

[`benchcat.toml`](benchcat.toml) defines one card with four series and eight
groups (three compression levels, two decompression levels, three ratio
levels). Groups come from each record's `group` field; missing series are
skipped. CI renders `assets/benchmarks.svg` from the four canonical files and
commits it from the default branch.
