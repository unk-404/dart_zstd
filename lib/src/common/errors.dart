/// Errors raised by `zstd_neo`.
///
/// Every malformed or unsupported input is reported as a [ZstdException];
/// the decoder never returns partially-decoded data silently.
library;

/// Machine-readable reason for a [ZstdException].
enum ZstdErrorCode {
  /// The first four bytes are neither a zstd frame magic nor a skippable
  /// frame magic.
  invalidMagic,

  /// The input ended before a complete frame/block could be read.
  truncatedInput,

  /// A reserved bit/field was set (frame header, block header, ...).
  reservedField,

  /// The frame asks for a window larger than `maxWindowSize`.
  windowTooLarge,

  /// A frame header field is not valid.
  invalidFrameHeader,

  /// A block header is not valid.
  invalidBlockHeader,

  /// The literals section is inconsistent.
  invalidLiterals,

  /// The Huffman tree description is invalid.
  invalidHuffmanTree,

  /// An FSE table description is invalid.
  invalidFseTable,

  /// A sequence is inconsistent (bad offset, literal overrun, ...).
  invalidSequence,

  /// The frame needs a dictionary that was not supplied.
  dictionaryRequired,

  /// The supplied dictionary does not match the frame's dictionary id.
  dictionaryMismatch,

  /// The frame content checksum did not match.
  checksumMismatch,

  /// A valid feature that this implementation does not support (yet).
  unsupportedFeature,

  /// The decoder would exceed its configured output limit.
  outputTooLarge,
}

/// Exception thrown for invalid, unsupported or corrupt zstd data.
final class ZstdException implements Exception {
  const ZstdException(this.code, this.message, {this.offset});

  final ZstdErrorCode code;
  final String message;

  /// Byte offset in the input where the problem was detected, when known.
  final int? offset;

  @override
  String toString() {
    final where = offset == null ? '' : ' at offset $offset';
    return 'ZstdException(${code.name}): $message$where';
  }
}
