/// v2 one-shot Zstandard decoder.
///
/// This engine is built for the single hot path `decodeInto(src, dst)`:
/// the compressed frame is copied once into a padded scratch buffer (so the
/// backward bit readers never need bounds checks), the output is written
/// directly into a caller-provided buffer, and frame entropy tables are
/// reused across blocks.
library;

import 'dart:typed_data';

import '../../common/constants.dart';
import '../../common/errors.dart';
import '../../common/xxh64.dart';
import 'checksum.dart';
import 'bit_stream.dart';
import 'block.dart';
import 'dictionary.dart';
import 'frame.dart';

/// Number of zero bytes kept in front of the compressed frame in the scratch
/// buffer. Backward readers are allowed to slide into this area when a stream
/// is shorter than the 64-bit window.
const int _kInputPad = 8;

/// Zero bytes kept after the compressed frame for unchecked wide loads.
const int _kInputTail = 16;

/// One-shot v2 Zstandard decoder.
///
/// The engine is optimised for the [decodeInto] hot path: the compressed frame
/// is copied once into a padded scratch buffer (so bit readers never need
/// end-of-input checks), the output is written directly into a caller-provided
/// buffer, and per-block entropy state is reused.
///
/// Instances are reusable and hold scratch buffers, so keep one decoder alive
/// across calls (decoding is synchronous and single-threaded). The engine is
/// AOT-focused; the dart2js fallback is correct but slower than v0.1.2, while
/// the dart2wasm/VM paths use the full 64-bit design.
///
/// The hot loops use `@pragma('vm:unsafe:no-bounds-checks')` only where the
/// indices are validated before entry (masked Huffman state, FSE table sizes,
/// literal/sequence length checks, guarded copy overruns). Malformed input is
/// fuzzed to surface as [ZstdException] only.
final class V2ZstdDecoder {
  V2ZstdDecoder({
    this.dictionary,
    this.maxWindowSize = zstdDefaultMaxWindowSize,
    this.verifyChecksum = true,
  });

  /// Optional raw-content or formatted dictionary.
  final Uint8List? dictionary;

  /// Maximum back-reference window accepted for a frame.
  final int maxWindowSize;

  /// Whether frame content checksums are verified (default true).
  final bool verifyChecksum;

  ParsedDictionary? _parsedDictionary;
  Uint8List _input = Uint8List(0);

  int _lastContentSize = -1;
  int _lastDictionaryId = 0;
  bool _lastHadChecksum = false;

  /// Declared content size of the most recently decoded frame (-1 if absent).
  int get lastContentSize => _lastContentSize;

  /// Dictionary id of the most recently decoded frame (0 for none).
  int get lastDictionaryId => _lastDictionaryId;

  /// Whether the most recently decoded frame carried a content checksum.
  bool get lastHadChecksum => _lastHadChecksum;

  /// Decodes every frame in [src] into [dst], starting at [dstOffset], and
  /// returns the number of bytes written.
  ///
  /// [dst] must provide at least `zstdBlockSizeMax` (128 KiB) of slack beyond
  /// the expected output: a block may write up to its block maximum, and the
  /// copy fast paths keep an 8-byte overrun window inside that slack.
  int decodeInto(Uint8List src, Uint8List dst, {int dstOffset = 0}) {
    if (src.isEmpty) return 0;
    _prepareInput(src);
    final input = _input;
    final end = _kInputPad + src.length;
    var position = _kInputPad;
    var produced = 0;
    _lastContentSize = -1;
    _lastDictionaryId = 0;
    _lastHadChecksum = false;
    while (position < end) {
      if (end - position < 4) {
        throw ZstdException(
          ZstdErrorCode.truncatedInput,
          'truncated frame magic',
          offset: position - _kInputPad,
        );
      }
      final magic = readLe32(input, position);
      if (magic == zstdFrameMagic) {
        produced += _decodeFrame(
          input,
          position + 4,
          end,
          dst,
          dstOffset + produced,
        );
        position = _frameNext;
      } else if (magic >= zstdSkippableMagicMin &&
          magic <= zstdSkippableMagicMax) {
        if (end - position < 8) {
          throw ZstdException(
            ZstdErrorCode.truncatedInput,
            'truncated skippable frame header',
            offset: position - _kInputPad,
          );
        }
        final size = readLe32(input, position + 4);
        position += 8;
        if (size > end - position) {
          throw ZstdException(
            ZstdErrorCode.truncatedInput,
            'truncated skippable frame payload',
            offset: position - _kInputPad,
          );
        }
        position += size;
      } else {
        throw ZstdException(
          ZstdErrorCode.invalidMagic,
          'not a zstd frame magic',
          offset: position - _kInputPad,
        );
      }
    }
    return produced;
  }

  int _frameNext = 0;

  ParsedDictionary? _parseDictionary() {
    if (dictionary == null) return null;
    return _parsedDictionary ??= ParsedDictionary.parse(dictionary!);
  }

  void _prepareInput(Uint8List src) {
    final needed = _kInputPad + src.length + _kInputTail;
    if (_input.length < needed) {
      var capacity = _input.isEmpty ? 1 << 16 : _input.length;
      while (capacity < needed) {
        capacity <<= 1;
      }
      _input = Uint8List(capacity);
    }
    // Zero the prefix and tail so short/unchecked wide loads are well-defined.
    _input.fillRange(0, _kInputPad, 0);
    _input.setRange(_kInputPad, _kInputPad + src.length, src);
    final tailStart = _kInputPad + src.length;
    _input.fillRange(tailStart, tailStart + _kInputTail, 0);
  }

  int _decodeFrame(
    Uint8List input,
    int descriptorStart,
    int inputEnd,
    Uint8List dst,
    int dstStart,
  ) {
    final header = parseFrameHeader(
      input,
      descriptorStart,
      inputEnd,
      maxWindowSize,
    );
    final parsedDictionary = _parseDictionary();
    if (header.dictionaryId != 0) {
      if (parsedDictionary == null) {
        throw ZstdException(
          ZstdErrorCode.dictionaryRequired,
          'frame requires dictionary ${header.dictionaryId}',
          offset: descriptorStart - _kInputPad,
        );
      }
      if (parsedDictionary.dictionaryId != header.dictionaryId) {
        throw ZstdException(
          ZstdErrorCode.dictionaryMismatch,
          'frame dictionary ${header.dictionaryId} does not match the '
          'provided dictionary ${parsedDictionary.dictionaryId}',
          offset: descriptorStart - _kInputPad,
        );
      }
    }
    final context = FrameContext(header, parsedDictionary);
    final dstLimit = dst.length;
    final capacity = dstLimit - dstStart;

    var cursor = header.headerEnd;
    var lastBlock = false;
    while (!lastBlock) {
      if (inputEnd - cursor < 3) {
        throw ZstdException(
          ZstdErrorCode.truncatedInput,
          'truncated block header',
          offset: cursor - _kInputPad,
        );
      }
      final blockHeader = readLe24(input, cursor);
      cursor += 3;
      lastBlock = (blockHeader & 1) != 0;
      final blockType = (blockHeader >> 1) & 3;
      final blockSize = blockHeader >> 3;
      final produced = context.frameOut;

      switch (blockType) {
        case 0: // raw
          if (blockSize > zstdBlockSizeMax) {
            throw ZstdException(
              ZstdErrorCode.invalidBlockHeader,
              'raw block is too large',
              offset: cursor - 3 - _kInputPad,
            );
          }
          if (blockSize > inputEnd - cursor) {
            throw ZstdException(
              ZstdErrorCode.truncatedInput,
              'truncated raw block',
              offset: cursor - _kInputPad,
            );
          }
          if (blockSize > capacity - produced) {
            throw const ZstdException(
              ZstdErrorCode.outputTooLarge,
              'decompressed output exceeds the output buffer',
            );
          }
          if (blockSize > 0) {
            dst.setRange(
              dstStart + produced,
              dstStart + produced + blockSize,
              input,
              cursor,
            );
          }
          context.blockOut = blockSize;
          context.frameOut += blockSize;
          cursor += blockSize;
        case 1: // RLE
          if (blockSize > zstdBlockSizeMax) {
            throw ZstdException(
              ZstdErrorCode.invalidBlockHeader,
              'RLE block is too large',
              offset: cursor - 3 - _kInputPad,
            );
          }
          if (cursor >= inputEnd) {
            throw ZstdException(
              ZstdErrorCode.truncatedInput,
              'truncated RLE block',
              offset: cursor - _kInputPad,
            );
          }
          if (blockSize > capacity - produced) {
            throw const ZstdException(
              ZstdErrorCode.outputTooLarge,
              'decompressed output exceeds the output buffer',
            );
          }
          if (blockSize > 0) {
            dst.fillRange(
              dstStart + produced,
              dstStart + produced + blockSize,
              input[cursor],
            );
          }
          context.blockOut = blockSize;
          context.frameOut += blockSize;
          cursor += 1;
        case 2: // compressed
          if (blockSize > context.blockMax) {
            throw ZstdException(
              ZstdErrorCode.invalidBlockHeader,
              'compressed block is larger than the block maximum size',
              offset: cursor - 3 - _kInputPad,
            );
          }
          if (blockSize > inputEnd - cursor) {
            throw ZstdException(
              ZstdErrorCode.truncatedInput,
              'truncated compressed block',
              offset: cursor - _kInputPad,
            );
          }
          if (context.blockMax > capacity - produced) {
            throw const ZstdException(
              ZstdErrorCode.outputTooLarge,
              'output buffer is too small for a full block',
            );
          }
          final writer = BlockOutput.contiguous(
            context,
            dst,
            dstStart + produced,
          );
          decodeCompressedBlock(
            context,
            input,
            cursor,
            cursor + blockSize,
            writer,
          );
          if (writer.blockOut > capacity - produced) {
            throw const ZstdException(
              ZstdErrorCode.outputTooLarge,
              'decompressed output exceeds the output buffer',
            );
          }
          context.blockOut = writer.blockOut;
          context.frameOut += writer.blockOut;
          cursor += blockSize;
        default:
          throw ZstdException(
            ZstdErrorCode.invalidBlockHeader,
            'reserved block type',
            offset: cursor - 3 - _kInputPad,
          );
      }

      if (header.hasContentSize && context.frameOut > header.frameContentSize) {
        throw ZstdException(
          ZstdErrorCode.invalidFrameHeader,
          'frame produces more than its declared content size',
          offset: cursor - _kInputPad,
        );
      }
    }

    if (header.contentChecksum) {
      if (inputEnd - cursor < 4) {
        throw ZstdException(
          ZstdErrorCode.truncatedInput,
          'truncated frame checksum',
          offset: cursor - _kInputPad,
        );
      }
      final expected = readLe32(input, cursor);
      cursor += 4;
      if (verifyChecksum) {
        final int actual;
        if (kHasInt64) {
          actual = xxh64Low32(dst, dstStart, dstStart + context.frameOut);
        } else {
          final hasher = Xxh64();
          if (context.frameOut > 0) {
            hasher.update(dst, dstStart, dstStart + context.frameOut);
          }
          actual = hasher.digest().low32;
        }
        if (actual != expected) {
          throw ZstdException(
            ZstdErrorCode.checksumMismatch,
            'frame content checksum mismatch',
            offset: cursor - 4 - _kInputPad,
          );
        }
      }
    }

    if (header.hasContentSize && context.frameOut != header.frameContentSize) {
      throw ZstdException(
        ZstdErrorCode.truncatedInput,
        'frame ended before its declared content size',
        offset: cursor - _kInputPad,
      );
    }

    _lastContentSize = header.hasContentSize ? header.frameContentSize : -1;
    _lastDictionaryId = header.dictionaryId;
    _lastHadChecksum = header.contentChecksum;
    _frameNext = cursor;
    return context.frameOut;
  }

  /// Convenience wrapper that allocates the output buffer.
  Uint8List decompress(Uint8List src) {
    if (src.isEmpty) return Uint8List(0);
    final header = _peekHeader(src);
    final capacity = header >= 0 ? header + zstdBlockSizeMax : (4 << 20);
    final buffer = Uint8List(capacity);
    final written = decodeInto(src, buffer);
    return Uint8List.sublistView(buffer, 0, written);
  }

  /// Best-effort frame content size for the first frame (-1 when unknown).
  int _peekHeader(Uint8List src) {
    try {
      if (src.length < 5 || readLe32(src, 0) != zstdFrameMagic) return -1;
      final header = parseFrameHeader(src, 4, src.length, maxWindowSize);
      return header.hasContentSize ? header.frameContentSize : -1;
    } on ZstdException {
      return -1;
    }
  }
}
