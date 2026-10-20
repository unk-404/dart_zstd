import 'dart:convert';

import 'package:zstd_neo/zstd_neo.dart';

void main() {
  const text =
      'zstd_neo is a pure Dart Zstandard codec. '
      'It runs on the Dart VM, in JavaScript and in WebAssembly.';
  final original = utf8.encode(text);

  final codec = ZstdCodec(level: 3);
  final compressed = codec.encode(original);
  final restored = codec.decode(compressed);

  print('original:   ${original.length} bytes');
  print('compressed: ${compressed.length} bytes');
  print('restored:   ${utf8.decode(restored) == text}');
}
