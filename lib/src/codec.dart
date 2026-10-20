/// One-shot and streaming Zstandard codec.
///
/// ```dart
/// final codec = ZstdCodec(level: 3);
/// final compressed = codec.encode(utf8.encode('hello'));
/// final restored = codec.decode(compressed);
/// ```
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:blit/blit.dart';

import 'common/constants.dart';
import 'compress/encoder.dart';
import 'decompress/decoder.dart';

/// A Zstandard [Codec] with fixed encoder and decoder options.
///
/// The encoder supports levels 1..19. The decoder verifies checksums by
/// default, supports formatted and raw-content dictionaries, and can enforce
/// a maximum window and output size.
final class ZstdCodec extends Codec<List<int>, List<int>> {
  const ZstdCodec({
    this.level = 3,
    this.checksum = false,
    this.dictionary,
    this.maxWindowSize = zstdDefaultMaxWindowSize,
    this.verifyChecksum = true,
    this.maxOutputSize,
  });

  /// Compression level, `1..19`.
  final int level;

  /// Whether the encoder appends the 4-byte XXH64 content checksum.
  final bool checksum;

  /// Optional formatted or raw-content zstd dictionary, used by both the
  /// encoder and the decoder.
  final Uint8List? dictionary;

  /// Upper bound on a frame's declared window accepted by the decoder.
  final int maxWindowSize;

  /// Whether the decoder verifies frame content checksums.
  final bool verifyChecksum;

  /// Optional upper bound on decompressed bytes; see [ZstdDecoder].
  final int? maxOutputSize;

  @override
  ZstdEncoder get encoder =>
      ZstdEncoder(level: level, checksum: checksum, dictionary: dictionary);

  @override
  ZstdDecoder get decoder => ZstdDecoder(
    dictionary: dictionary,
    maxWindowSize: maxWindowSize,
    verifyChecksum: verifyChecksum,
    maxOutputSize: maxOutputSize,
  );

  /// Compresses [input] without an intermediate `List<int>` copy.
  Uint8List compress(Uint8List input) => encoder.compress(input);

  /// Decompresses [input] without an intermediate `List<int>` copy.
  Uint8List decompress(Uint8List input) => decoder.decompress(input);

  /// Zero-copy [Bytes] convenience wrappers.
  Bytes compressBytes(Bytes input) =>
      Bytes.fromUint8List(compress(input.asUint8List()));

  Bytes decompressBytes(Bytes input) =>
      Bytes.fromUint8List(decompress(input.asUint8List()));
}
