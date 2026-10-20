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
- (in progress)

## 0.1.1

- Production encoder covering levels 1鈥?9:
  - Huffman literal coding with a length-limited (鈮?1 bit) tree, direct or
    FSE-compressed weight descriptions, 1-stream and 4-stream layouts, and
    treeless/repeat tables.
  - Custom FSE sequence tables (normalization, table descriptions, CTable,
    RLE/predefined/custom/repeat selection) and exact repeat-offset encoding.
  - Fast, double-fast, greedy, lazy and lazy2 match finders; levels 10鈥?9 use
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
- Encoder for levels 1鈥?: fast/double-fast match finding, raw/RLE literals,
  predefined FSE sequence tables, optional checksum, streaming.
- Works on the Dart VM, dart2js and dart2wasm.

