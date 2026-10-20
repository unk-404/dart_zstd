# zstd_neo

A from-scratch, **pure Dart** implementation of the
[Zstandard](https://facebook.github.io/zstd/) compression format.

- Runs on the Dart VM, dart2js and dart2wasm — no FFI, no native libraries.
- Complete Zstandard decoder, including dictionaries, skippable frames,
  concatenated frames, content checksums and streaming.
- Streaming encoder with `Converter` / `startChunkedConversion`, plus a
  one-shot fast path.

> **Status: v0.1.2 (production).** Format conformance is verified against the
> official zstd `decodecorpus` corpus, and the v0.1.2 performance phase improved
> the AOT encoder by roughly 1.55x/1.85x/2.21x at levels 3/9/19 and the AOT
> decoder by roughly 1.5x, with smaller but real JS/Wasm gains.
> The encoder covers levels 1–19 with Huffman literals (1/4 streams, treeless
> repeat), custom FSE sequence tables, repeat/RLE modes and raw/formatted
> dictionary support. Levels 10–19 use a deeper-search lazy2 parser rather than
> the reference `btopt`, so they produce valid frames and competitive ratios but
> may trail libzstd at the very highest levels.

## Usage

```dart
import 'dart:convert';

import 'package:zstd_neo/zstd_neo.dart';

void main() {
  final input = utf8.encode('hello hello hello hello');

  final codec = ZstdCodec(level: 3);
  final compressed = codec.encode(input);
  final restored = codec.decode(compressed);

  print(utf8.decode(restored)); // hello hello hello hello
}
```

### Streaming

```dart
import 'dart:convert';

import 'package:zstd_neo/zstd_neo.dart';

void main() {
  final output = <int>[];
  final sink = ZstdDecoder().startChunkedConversion(
    ByteConversionSink.withCallback(output.addAll),
  );

  sink.add(compressedPart1);
  sink.add(compressedPart2);
  sink.close();

  print(output.length);
}
```

### `Bytes` fast path

`blit`'s `Bytes` can be passed without an intermediate copy:

```dart
final compressed = codec.compressBytes(inputBytes); // Bytes -> Bytes
final restored = codec.decompressBytes(compressed);
```

### Dictionaries

```dart
final codec = ZstdCodec(level: 9, dictionary: dictionaryBytes);
final frame = codec.encode(payload);
final data = codec.decode(frame);
```

Raw-content dictionaries and formatted zstd dictionaries
(magic `0xEC30A437`, including its dictionary id) are supported by both the
encoder and the decoder.

### Output limits

```dart
final decoder = ZstdDecoder(maxOutputSize: 64 << 20); // 64 MiB
```

The default is unlimited; production services receiving untrusted input should
set `maxOutputSize` (and optionally a smaller `maxWindowSize`).

## Format support

| Feature | Decode | Encode |
| --- | :---: | :---: |
| Raw / RLE / compressed blocks | ✓ | ✓ |
| Raw / RLE literals | ✓ | ✓ |
| Huffman literals, 1 & 4 streams | ✓ | ✓ |
| Treeless literals / repeat Huffman | ✓ | ✓ |
| Predefined / RLE / FSE / repeat sequence tables | ✓ | ✓ |
| Repeat offsets | ✓ | ✓ |
| Content checksum (XXH64) | ✓ | optional |
| Frame content size / single segment | ✓ | one-shot |
| Skippable frames, concatenated frames | ✓ | — |
| Structured & raw dictionaries | ✓ | ✓ |
| Streaming | ✓ | ✓ |

The decoder rejects windows larger than `maxWindowSize` (64 MiB by default)
and verifies checksums when present.

## Conformance

Format conformance is verified against the **official zstd `decodecorpus`**
generator, not just hand-written vectors: a committed corpus of 278 frames
(5.9 MB with plaintext) covers random frames, forced content sizes, 128 KiB
blocks, forced raw/RLE/compressed blocks and larger content. Every frame is
byte-compared in `test/conformance_test.dart`, alongside official golden/error
vectors and differential fuzzing against libzstd 1.5.7.

See [CONFORMANCE.md](CONFORMANCE.md) for the exact coverage matrix and the
documented resource limits (window/output limits, 8-byte content-size ceiling,
and the fact that legacy/seekable formats and LDM encoding are out of scope).

## Performance

![zstd_neo benchmarks](https://raw.githubusercontent.com/unk-404/dart_zstd/HEAD/assets/benchmarks.svg)

The card compares Dart AOT, dart2js, dart2wasm and the native Rust `zstd`
crate on 256 KiB Silesia slices at levels 3, 9 and 19, including ratios. It is
generated and committed automatically by CI on the default branch; a missing
series is omitted rather than faked.

On the current runners, v0.1.2 improves the v0.1.1 numbers by roughly **1.55x**
(AOT L3 encode), **1.85x** (L9) and **2.21x** (L19), while the decoder is about
**1.5x** faster on AOT and **1.3–1.4x** on JS/Wasm. The checksum path was also
optimized (native XXH64 about 2x; JS/Wasm 1.55–1.8x). Compression ratios remain
close to libzstd at levels 3 and 9 and about 6–8% behind at level 19, because the
high levels approximate the reference `btopt` parser. Native C remains faster;
the chart makes the trade-off explicit, and the JS decode numbers are partly
checksum-bound because JavaScript has no native 64-bit integers.

## Development

```sh
dart pub get
dart analyze
dart test        # Windows / Linux / macOS VM tests
```

Web tests (CI): `dart test -p chrome` and `dart test -p chrome -c dart2wasm`.

Test fixtures are generated by the dev-only Rust harness:

```sh
cd benchmark/rust_ref
cargo run --release -- gen-fixtures --out ../../test/fixtures
```

Rust is only used for tests, fixtures and benchmarks; the published library is
pure Dart.

## License

MIT — see [LICENSE](LICENSE). Test vectors derived from the reference zstd
project and the Silesia corpus are covered by [NOTICE](NOTICE).

