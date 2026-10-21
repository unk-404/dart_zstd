/// Platform probe for the v2 one-shot decoder.
///
/// The v2 engine is much faster on the Dart VM/AOT, but slower than the v1
/// streaming engine on dart2js/dart2wasm. Web builds therefore keep v1.
library;

/// Whether [ZstdDecoder.decompress] should try the v2 one-shot engine.
const bool kUseFastDecoder = true;
