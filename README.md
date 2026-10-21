# zstd_neo

A from-scratch, **pure Dart** implementation of the
[Zstandard](https://facebook.github.io/zstd/) compression format.

- Runs on the Dart VM, dart2js and dart2wasm — no FFI, no native libraries.
- Complete Zstandard decoder, including dictionaries, skippable frames,
  concatenated frames, content checksums and streaming.
- Streaming encoder with `Converter` / `startChunkedConversion`, plus a
  one-shot fast path.

> **Status: v0.2.1.** The new v2 one-shot engine is the default on the Dart
> VM/AOT: AOT `decompressInto` is roughly 1.4-1.6x the v0.1.2 decoder
> (allocating `decompress` ~1.2-1.4x) and one-shot encode roughly 1.1x; measured throughput is about 37-40% of native zstd (decode) and
> 20% (L3 encode). The 80%-of-native pure-Dart research target was not reached:
> per-sequence bit/copy overhead and XXH64 are the structural limits. Web keeps
> the v0.1.2 engine (v2 is correct but slower there). The encoder covers levels
> 1-19; levels 10-19 use a deeper-search lazy2 parser rather than `btopt`.

## Usage

```dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:zstd_neo/zstd_neo.dart';

void main() {
  final input = utf8.encode('hello hello hello hello');

  final codec = ZstdCodec(level: 3);
  final compressed = codec.encode(input);
  final restored = codec.decode(compressed);

  // Zero-allocation decode into a caller buffer (VM/AOT fast path):
  final dst = Uint8List(restored.length + 128 * 1024);
  final n = const ZstdDecoder().decompressInto(compressed, dst);
  print(n);
  // Or an externally owned blit UnsafeBytes buffer (native malloc / web arena):
  final buffer = const ZstdDecoder().decompressUnsafe(compressed);
  try {
    print(buffer.view.length);
  } finally {
    buffer.free();
  }

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

v0.2.1 switches the Dart VM/AOT one-shot path to a new v2 engine and uses
blit 0.2.1 `UnsafeBytes` for an externally owned decode buffer:
`decompressInto` is roughly **1.4–1.6x** the v0.1.2 decoder, allocating
`decompress` ~1.2–1.4x, `decompressUnsafe` about **1.2x faster than the managed
path**, and one-shot encode roughly **1.1x**.
Measured throughput is about **37–40% of native** for decode and about **20%**
for L3 encode; the 80%-of-native pure-Dart research target was not reached
because per-sequence bit operations and the XXH64 checksum dominate at this
point. Web keeps the v0.1.2 engine (v2 is correct but slower on JS/Wasm).
Compression ratios remain close to libzstd at levels 3 and 9 and about 6–8%
behind at level 19, because the high levels approximate `btopt`. Native C
remains faster; the chart makes the trade-off explicit.

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

