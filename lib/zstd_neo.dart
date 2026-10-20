/// Pure Dart Zstandard (zstd) codec.
///
/// A complete decoder and a streaming encoder for the Zstandard frame format,
/// usable on the Dart VM, dart2js and dart2wasm.
library;

export 'src/codec.dart' show ZstdCodec;
export 'src/common/errors.dart' show ZstdErrorCode, ZstdException;
export 'src/compress/encoder.dart' show ZstdEncoder;
export 'src/decompress/decoder.dart' show ZstdDecoder;
