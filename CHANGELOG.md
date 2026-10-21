## 0.2.0

### v2 engine
- New one-shot decoder engine with a 64-bit bit window, 4-symbol-unrolled
  Huffman decode, packed FSE rows, fused sequence execution, specialized match
  copies and an optimized XXH64. On the Dart VM/AOT `decompressInto` is ~1.4-1.6x the v0.1.2
  decoder (allocating `decompress` ~1.2-1.4x) and reaches ~37-40% of native zstd; the 80%-of-native pure-Dart
  research target was not reached (per-sequence overhead and checksum).
- New one-shot encoder engine with word-based hashing and a leaner match loop;
  ~1.1x the v0.1.2 encoder at equal ratio. Streaming keeps the v0.1.2 engine.
- Web keeps the v0.1.2 engine: v2 is verified correct on JS/Wasm but slower
  there.
- Added `ZstdDecoder.decompressInto` for caller-provided output buffers.
- Hardened the v2 decoder with malformed-input fuzzing, destination canaries
  and the 278-frame conformance corpus.
- Added v2 conformance/fuzz/web tests; full suite remains green.

### blit / UnsafeBytes
- Upgrade to `blit 0.2.1` and use its `UnsafeBytes` for an externally owned
  decode buffer. `ZstdDecoder.decompressUnsafe` returns a `ZstdBuffer` whose
  memory is native `malloc` (VM) or the web WebAssembly-memory arena; call
  `free()` exactly once. It is ~1.2x faster than managed `decompress` on the
  local AOT benchmark (500 x 256 KiB: 463 ms -> 382 ms).
- Keep `decompressInto` for caller-provided `Uint8List` output and
  `decompress` for a managed result.
- Add unsafe-buffer tests; the full suite is 577 tests with `ZSTD_REF`.
- The 80%-of-native pure-Dart target is not reached; v2 remains ~37-40%
  native, and the externally owned path removes output GC/allocation overhead
  only.

## 0.1.2

### Conformance
- Committed an official zstd `decodecorpus` corpus (278 frames, 5.9 MB with
  plaintext; random/default, content-size, 128 KiB blocks, forced
  raw/RLE/compressed blocks, larger content) and a VM conformance test that
  byte-compares every frame.
- Added frame-header edge coverage: 1/2/4/8-byte content sizes, unused/reserved
  bits, window limits, content-size mismatch and skippable-only streams.
- Documented the precise Zstandard conformance scope and deliberate resource
  limits in `CONFORMANCE.md`.

### Performance
- Encoder (Dart AOT, Silesia slices): ~1.55x at L3, ~1.85x at L9 and ~2.21x
  at L19; ratio cost +0.70% / +0.49% / +0.09%.
- Decoder: ~1.3–1.5x AOT at L3/L19, ~1.90x/1.90x on dart2js and
  ~1.47x/1.48x on dart2wasm. The JS decode path is partly checksum-bound.
- XXH64: ~2x native, ~1.55x JS, ~1.81x dart2wasm.
- Rewrote match finding (word-based hash, closure-free lazy/lazy2, cheap
  candidate rejection), bit/sequence writing, Huffman package-merge and the
  decoder bit reader/FSE/match-copy loops.
- 51 MB Silesia validation: L1/L3/L9/L19 frames byte-identical under libzstd.
- Benchcat now supplies its own font catalogue; the bundled font is gone.

## 0.1.1

- Production encoder covering levels 1–19:
  - Huffman literal coding with a length-limited (≤11 bit) tree, direct or
    FSE-compressed weight descriptions, 1-stream and 4-stream layouts, and
    treeless/repeat tables.
  - Custom FSE sequence tables (normalization, table descriptions, CTable,
    RLE/predefined/custom/repeat selection) and exact repeat-offset encoding.
  - Fast, double-fast, greedy, lazy and lazy2 match finders; levels 10–19 use
    deep lazy2 chains as an approximation of the reference `btopt` parsers.
  - Raw-content and formatted dictionaries, including dictionary ids and
    initial repeat offsets, for one-shot and streaming use.
- Decoder hardening: optional `maxOutputSize` limit, broader malformed-input
  coverage, and hot-path optimizations (packed entropy tables, fused backward
  bit reads, pattern-doubling match copies, ring pre-sizing).
- Differential and corruption fuzzing against libzstd, plus a web-safe
  robustness suite.
- Fixed a custom-FSE table-description bug for long zero runs and a web-only
  32-bit shift overflow in the 5-byte literals header.

## 0.1.0

- Initial release.
- Complete pure-Dart Zstandard decoder: frames, skippable frames, raw/RLE/
  compressed blocks, Huffman literals (1 and 4 streams), FSE sequence tables,
  repeat offsets, checksums, structured/raw dictionaries, streaming.
- Encoder for levels 1–3: fast/double-fast match finding, raw/RLE literals,
  predefined FSE sequence tables, optional checksum, streaming.
- Works on the Dart VM, dart2js and dart2wasm.

