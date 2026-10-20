## 0.1.0

- Initial release.
- Complete pure-Dart Zstandard decoder: frames, skippable frames, raw/RLE/
  compressed blocks, Huffman literals (1 and 4 streams), FSE sequence tables,
  repeat offsets, checksums, structured/raw dictionaries, streaming.
- Encoder for levels 1–3: fast/double-fast match finding, raw/RLE literals,
  predefined FSE sequence tables, optional checksum, streaming.
- Works on the Dart VM, dart2js and dart2wasm.
