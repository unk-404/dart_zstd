/// Zstandard dictionary parsing.
///
/// Both raw-content dictionaries and formatted dictionaries (magic
/// `0xEC30A437`) populate the initial frame state: back-reference content,
/// optional entropy tables and the three starting repeated offsets.
library;

import 'dart:typed_data';

import '../../common/constants.dart';
import '../../common/errors.dart';
import 'bit_stream.dart';
import 'fse.dart';
import 'huffman.dart';

/// A dictionary ready to seed a frame decoder.
final class ParsedDictionary {
  ParsedDictionary({
    required this.dictionaryId,
    required this.content,
    this.huffman,
    this.ofTable,
    this.mlTable,
    this.llTable,
    this.repOffsets,
  });

  /// Dictionary id; 0 for raw-content dictionaries.
  final int dictionaryId;

  /// Back-reference content (the whole buffer for raw dictionaries).
  final Uint8List content;

  /// Entropy tables, present only for formatted dictionaries.
  final HuffmanTable? huffman;
  final FseTable? ofTable;
  final FseTable? mlTable;
  final FseTable? llTable;

  /// Starting repeated offsets, present only for formatted dictionaries.
  final List<int>? repOffsets;

  bool get isFormatted => huffman != null;

  /// Parses [bytes] as either a formatted or a raw-content dictionary.
  static ParsedDictionary parse(Uint8List bytes) {
    if (bytes.length >= 4 && readLe32(bytes, 0) == zstdDictionaryMagic) {
      return _parseFormatted(bytes);
    }
    return ParsedDictionary(dictionaryId: 0, content: bytes);
  }

  static ParsedDictionary _parseFormatted(Uint8List bytes) {
    if (bytes.length <= 8) {
      throw const ZstdException(
        ZstdErrorCode.invalidFrameHeader,
        'formatted dictionary is too small',
      );
    }
    final dictionaryId = readLe32(bytes, 4);
    final reader = ForwardBitReader(bytes, 8, bytes.length);

    final huffman = HuffmanTable.readFrom(reader);
    final ofTable = FseTable.readFrom(reader, kMaxOffsetCode, 8);
    final mlTable = FseTable.readFrom(reader, kMaxMlCode, 9);
    final llTable = FseTable.readFrom(reader, kMaxLlCode, 9);

    final tableEnd = reader.position;
    if (tableEnd + 12 > bytes.length) {
      throw const ZstdException(
        ZstdErrorCode.truncatedInput,
        'truncated dictionary entropy tables',
      );
    }
    final repOffsets = <int>[
      readLe32(bytes, tableEnd),
      readLe32(bytes, tableEnd + 4),
      readLe32(bytes, tableEnd + 8),
    ];
    final content = Uint8List.sublistView(bytes, tableEnd + 12);
    for (final off in repOffsets) {
      if (off == 0 || off > content.length) {
        throw const ZstdException(
          ZstdErrorCode.invalidFrameHeader,
          'dictionary repeated offset is invalid',
        );
      }
    }

    return ParsedDictionary(
      dictionaryId: dictionaryId,
      content: content,
      huffman: huffman,
      ofTable: ofTable,
      mlTable: mlTable,
      llTable: llTable,
      repOffsets: repOffsets,
    );
  }
}
