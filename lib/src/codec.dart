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

import 'compress/encoder.dart';
import 'decompress/decoder.dart';

/// A Zstandard [Codec] with a fixed compression level.
final class ZstdCodec extends Codec<List<int>, List<int>> {
  const ZstdCodec({this.level = 3, this.checksum = false});

  /// Compression level. `1..3` are implemented in this version.
  final int level;

  /// Whether the encoder appends the 4-byte XXH64 content checksum.
  final bool checksum;

  @override
  ZstdEncoder get encoder => ZstdEncoder(level: level, checksum: checksum);

  @override
  ZstdDecoder get decoder => ZstdDecoder();

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
