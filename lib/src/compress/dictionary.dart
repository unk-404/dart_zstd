import 'dart:typed_data';

import '../common/constants.dart';
import '../common/errors.dart';

/// A dictionary prepared for the encoder.
///
/// Raw-content dictionaries have no id and just provide history bytes.
/// Formatted dictionaries (`0xEC30A437`) additionally provide an id (written
/// into the frame header) and the three starting repeated offsets.
final class EncoderDictionary {
  EncoderDictionary({
    required this.dictionaryId,
    required this.content,
    required this.repOffsets,
    required this.isFormatted,
  });

  final int dictionaryId;
  final Uint8List content;
  final List<int> repOffsets;
  final bool isFormatted;

  /// Parses raw or formatted dictionary [bytes].
  static EncoderDictionary parse(Uint8List bytes) {
    if (bytes.length >= 4 && _readLe32(bytes, 0) == zstdDictionaryMagic) {
      return _parseFormatted(bytes);
    }
    return EncoderDictionary(
      dictionaryId: 0,
      content: bytes,
      repOffsets: const <int>[1, 4, 8],
      isFormatted: false,
    );
  }

  static EncoderDictionary _parseFormatted(Uint8List bytes) {
    if (bytes.length <= 8) {
      throw const ZstdException(
        ZstdErrorCode.invalidFrameHeader,
        'formatted dictionary is too small',
      );
    }
    final dictionaryId = _readLe32(bytes, 4);
    var cursor = 8;

    // Huffman tree description.
    if (cursor >= bytes.length) {
      throw const ZstdException(
        ZstdErrorCode.truncatedInput,
        'truncated dictionary Huffman table',
      );
    }
    final header = bytes[cursor];
    if (header < 128) {
      // FSE-compressed weights: `header` payload bytes follow.
      cursor += 1 + header;
    } else {
      final weightCount = header - 127;
      cursor += 1 + ((weightCount + 1) >> 1);
    }
    if (cursor > bytes.length) {
      throw const ZstdException(
        ZstdErrorCode.truncatedInput,
        'truncated dictionary Huffman table',
      );
    }

    // Offset, match length and literal length FSE tables, in that order.
    cursor = _fseTableEnd(bytes, cursor, 31);
    cursor = _fseTableEnd(bytes, cursor, 52);
    cursor = _fseTableEnd(bytes, cursor, 35);
    if (cursor + 12 > bytes.length) {
      throw const ZstdException(
        ZstdErrorCode.truncatedInput,
        'truncated dictionary entropy tables',
      );
    }
    final repOffsets = <int>[
      _readLe32(bytes, cursor),
      _readLe32(bytes, cursor + 4),
      _readLe32(bytes, cursor + 8),
    ];
    cursor += 12;
    final content = Uint8List.sublistView(bytes, cursor);
    for (final offset in repOffsets) {
      if (offset == 0 || offset > content.length) {
        throw const ZstdException(
          ZstdErrorCode.invalidFrameHeader,
          'dictionary repeated offset is invalid',
        );
      }
    }
    return EncoderDictionary(
      dictionaryId: dictionaryId,
      content: content,
      repOffsets: repOffsets,
      isFormatted: true,
    );
  }
}

/// Returns the byte offset directly after the FSE table description at
/// [start], mirroring the decoder's forward parser.
int _fseTableEnd(Uint8List data, int start, int maxSymbolValue) {
  if (start >= data.length) {
    throw const ZstdException(
      ZstdErrorCode.truncatedInput,
      'truncated dictionary FSE table',
    );
  }
  final reader = _ForwardBits(data, start);
  final accuracyLog = 5 + reader.readBits(4);
  if (accuracyLog > 15) {
    throw const ZstdException(
      ZstdErrorCode.invalidFseTable,
      'dictionary FSE accuracy log is invalid',
    );
  }
  final maxSymbols = maxSymbolValue + 1;
  final tableSize = 1 << accuracyLog;
  var remaining = tableSize + 1;
  var threshold = tableSize;
  var nbBits = accuracyLog + 1;
  var charnum = 0;
  var previousZero = false;
  while (true) {
    if (previousZero) {
      var repeat = reader.readBits(2);
      while (repeat == 3) {
        charnum += 3;
        if (charnum >= maxSymbols) {
          throw const ZstdException(
            ZstdErrorCode.invalidFseTable,
            'dictionary FSE zero run exceeds the symbol range',
          );
        }
        repeat = reader.readBits(2);
      }
      charnum += repeat;
      if (charnum >= maxSymbols) break;
    }
    final max = (2 * threshold - 1) - remaining;
    final value = reader.readBits(nbBits);
    int count;
    if ((value & (threshold - 1)) < max) {
      count = value & (threshold - 1);
      reader.rewindBits(1);
    } else {
      count = value & (2 * threshold - 1);
      if (count >= threshold) count -= max;
    }
    count--;
    if (count >= 0) {
      remaining -= count;
    } else {
      remaining += count;
    }
    if (charnum >= maxSymbols) {
      throw const ZstdException(
        ZstdErrorCode.invalidFseTable,
        'too many dictionary FSE symbols',
      );
    }
    charnum++;
    previousZero = count == 0;
    if (remaining < threshold) {
      if (remaining <= 1) break;
      nbBits = _highestSetBit(remaining) + 1;
      threshold = 1 << (nbBits - 1);
    }
    if (charnum >= maxSymbols) break;
  }
  if (remaining != 1) {
    throw const ZstdException(
      ZstdErrorCode.invalidFseTable,
      'dictionary FSE distribution is incomplete',
    );
  }
  reader.alignToByte();
  return reader.bytePosition;
}

final class _ForwardBits {
  _ForwardBits(this.data, this._byteOffset) : _bitOffset = 0;

  final Uint8List data;
  int _byteOffset;
  int _bitOffset;

  int get bytePosition => _byteOffset;

  int readBits(int count) {
    var value = 0;
    for (var i = 0; i < count; i++) {
      if (_byteOffset >= data.length) {
        throw const ZstdException(
          ZstdErrorCode.truncatedInput,
          'truncated dictionary bitstream',
        );
      }
      final bit = (data[_byteOffset] >> _bitOffset) & 1;
      value |= bit << i;
      _bitOffset++;
      if (_bitOffset == 8) {
        _bitOffset = 0;
        _byteOffset++;
      }
    }
    return value;
  }

  void rewindBits(int count) {
    _bitOffset -= count;
    while (_bitOffset < 0) {
      _bitOffset += 8;
      _byteOffset--;
    }
  }

  void alignToByte() {
    if (_bitOffset != 0) {
      _bitOffset = 0;
      _byteOffset++;
    }
  }
}

int _highestSetBit(int value) {
  var bits = 0;
  while (value > 1) {
    value >>= 1;
    bits++;
  }
  return bits;
}

int _readLe32(Uint8List data, int offset) =>
    data[offset] |
    (data[offset + 1] << 8) |
    (data[offset + 2] << 16) |
    (data[offset + 3] << 24);
