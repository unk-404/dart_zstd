import 'dart:convert';
import 'dart:typed_data';

import '../common/constants.dart';
import '../common/errors.dart';
import '../common/xxh64.dart';
import 'bit_stream.dart';
import 'block.dart';
import 'dictionary.dart';
import 'frame.dart';
import 'window.dart';

/// Streaming-capable Zstandard decoder.
///
/// The one-shot [decompress] fast path and the chunked [startChunkedConversion]
/// path share the frame/block implementation in this directory.
final class ZstdDecoder extends Converter<List<int>, List<int>> {
  const ZstdDecoder({
    this.dictionary,
    this.maxWindowSize = zstdDefaultMaxWindowSize,
    this.verifyChecksum = true,
    this.maxOutputSize,
  }) : assert(
         maxOutputSize == null || maxOutputSize >= 0,
         'maxOutputSize must be non-negative',
       );

  /// Optional Zstandard dictionary (formatted or raw content).
  final Uint8List? dictionary;

  /// Upper bound on a frame's declared window; larger frames are rejected
  /// with [ZstdErrorCode.windowTooLarge].
  final int maxWindowSize;

  /// Whether frame content checksums are verified.
  final bool verifyChecksum;

  /// Optional upper bound on the total number of decompressed bytes produced
  /// by one [decompress] call or by one chunked conversion, including all
  /// concatenated frames.
  ///
  /// When the bound would be exceeded, decoding stops and throws
  /// [ZstdException] with [ZstdErrorCode.outputTooLarge]. `null` (the default)
  /// means unlimited.
  final int? maxOutputSize;

  /// Fast path: decompress a contiguous byte buffer.
  Uint8List decompress(Uint8List input) {
    try {
      return _decompressAll(input);
    } on ZstdException {
      rethrow;
    } catch (error) {
      throw ZstdException(
        ZstdErrorCode.invalidFrameHeader,
        'corrupt zstd data: $error',
      );
    }
  }

  @override
  Uint8List convert(List<int> input) =>
      decompress(input is Uint8List ? input : Uint8List.fromList(input));

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) =>
      _ZstdDecodingSink(this, sink);

  ParsedDictionary? _parseDictionary() {
    final bytes = dictionary;
    if (bytes == null || bytes.isEmpty) return null;
    return ParsedDictionary.parse(bytes);
  }

  Uint8List _decompressAll(Uint8List input) {
    if (input.isEmpty) {
      throw const ZstdException(
        ZstdErrorCode.truncatedInput,
        'empty zstd input',
      );
    }
    final parsedDictionary = _parseDictionary();
    final parts = <Uint8List>[];
    var position = 0;
    var producedTotal = 0;
    while (position < input.length) {
      if (input.length - position < 4) {
        throw ZstdException(
          ZstdErrorCode.truncatedInput,
          'truncated frame magic',
          offset: position,
        );
      }
      final magic = readLe32(input, position);
      if (magic == zstdFrameMagic) {
        final remaining = maxOutputSize == null
            ? null
            : maxOutputSize! - producedTotal;
        final frame = _decodeFrame(
          input,
          position + 4,
          parsedDictionary,
          remaining,
        );
        parts.add(frame.bytes);
        producedTotal += frame.bytes.length;
        position = frame.next;
      } else if (magic >= zstdSkippableMagicMin &&
          magic <= zstdSkippableMagicMax) {
        if (input.length - position < 8) {
          throw ZstdException(
            ZstdErrorCode.truncatedInput,
            'truncated skippable frame header',
            offset: position,
          );
        }
        final size = readLe32(input, position + 4);
        position += 8;
        if (size > input.length - position) {
          throw ZstdException(
            ZstdErrorCode.truncatedInput,
            'truncated skippable frame payload',
            offset: position,
          );
        }
        position += size;
      } else {
        throw ZstdException(
          ZstdErrorCode.invalidMagic,
          'not a zstd frame magic',
          offset: position,
        );
      }
    }
    if (parts.isEmpty) return Uint8List(0);
    if (parts.length == 1) return parts[0];
    var total = 0;
    for (final part in parts) {
      total += part.length;
    }
    final result = Uint8List(total);
    var at = 0;
    for (final part in parts) {
      result.setRange(at, at + part.length, part);
      at += part.length;
    }
    return result;
  }

  _DecodedFrame _decodeFrame(
    Uint8List input,
    int descriptorStart,
    ParsedDictionary? parsedDictionary,
    int? outputLimit,
  ) {
    final header = parseFrameHeader(
      input,
      descriptorStart,
      input.length,
      maxWindowSize,
    );
    _applyDictionary(header, parsedDictionary);
    final context = FrameContext(header, parsedDictionary);

    var buffer = Uint8List(0);
    var length = 0;

    void ensureCapacity(int needed) {
      if (buffer.length >= needed && buffer.isNotEmpty) return;
      var capacity = buffer.isEmpty ? 64 : buffer.length;
      while (capacity < needed) {
        capacity <<= 1;
      }
      final grown = Uint8List(capacity);
      if (length > 0) grown.setRange(0, length, buffer);
      buffer = grown;
    }

    void checkOutputSize(int produced) {
      final limit = outputLimit;
      if (limit != null && produced > limit - context.frameOut) {
        throw ZstdException(
          ZstdErrorCode.outputTooLarge,
          'decompressed output exceeds maxOutputSize ($limit bytes)',
        );
      }
    }

    if (header.hasContentSize) {
      var hint = header.frameContentSize < (4 << 20)
          ? header.frameContentSize
          : (4 << 20);
      if (outputLimit != null && hint > outputLimit) hint = outputLimit;
      if (hint > 0) ensureCapacity(hint);
    }

    var cursor = header.headerEnd;
    var lastBlock = false;
    while (!lastBlock) {
      if (input.length - cursor < 3) {
        throw ZstdException(
          ZstdErrorCode.truncatedInput,
          'truncated block header',
          offset: cursor,
        );
      }
      final blockHeader = readLe24(input, cursor);
      cursor += 3;
      lastBlock = (blockHeader & 1) != 0;
      final blockType = (blockHeader >> 1) & 3;
      final blockSize = blockHeader >> 3;

      switch (blockType) {
        case 0: // raw
          if (blockSize > zstdBlockSizeMax) {
            throw ZstdException(
              ZstdErrorCode.invalidBlockHeader,
              'raw block is too large',
              offset: cursor - 3,
            );
          }
          if (blockSize > input.length - cursor) {
            throw ZstdException(
              ZstdErrorCode.truncatedInput,
              'truncated raw block',
              offset: cursor,
            );
          }
          checkOutputSize(blockSize);
          ensureCapacity(length + blockSize);
          if (blockSize > 0) {
            buffer.setRange(length, length + blockSize, input, cursor);
          }
          length += blockSize;
          cursor += blockSize;
          context.blockOut = blockSize;
          context.frameOut += blockSize;
        case 1: // RLE
          if (blockSize > zstdBlockSizeMax) {
            throw ZstdException(
              ZstdErrorCode.invalidBlockHeader,
              'RLE block is too large',
              offset: cursor - 3,
            );
          }
          if (cursor >= input.length) {
            throw ZstdException(
              ZstdErrorCode.truncatedInput,
              'truncated RLE block',
              offset: cursor,
            );
          }
          checkOutputSize(blockSize);
          ensureCapacity(length + blockSize);
          final value = input[cursor];
          if (blockSize > 0) {
            buffer.fillRange(length, length + blockSize, value);
          }
          length += blockSize;
          cursor += 1;
          context.blockOut = blockSize;
          context.frameOut += blockSize;
        case 2: // compressed
          if (blockSize > context.blockMax) {
            throw ZstdException(
              ZstdErrorCode.invalidBlockHeader,
              'compressed block is larger than the block maximum size',
              offset: cursor - 3,
            );
          }
          if (blockSize > input.length - cursor) {
            throw ZstdException(
              ZstdErrorCode.truncatedInput,
              'truncated compressed block',
              offset: cursor,
            );
          }
          ensureCapacity(length + context.blockMax);
          final writer = ContiguousBlockOutput(context, buffer, length);
          decodeCompressedBlock(
            context,
            input,
            cursor,
            cursor + blockSize,
            writer,
          );
          checkOutputSize(writer.blockOut);
          length += writer.blockOut;
          context.blockOut = writer.blockOut;
          context.frameOut += writer.blockOut;
          cursor += blockSize;
        default:
          throw ZstdException(
            ZstdErrorCode.invalidBlockHeader,
            'reserved block type',
            offset: cursor - 3,
          );
      }

      if (header.hasContentSize && context.frameOut > header.frameContentSize) {
        throw ZstdException(
          ZstdErrorCode.invalidFrameHeader,
          'frame produces more than its declared content size',
          offset: cursor,
        );
      }
    }

    if (header.contentChecksum) {
      if (input.length - cursor < 4) {
        throw ZstdException(
          ZstdErrorCode.truncatedInput,
          'truncated frame checksum',
          offset: cursor,
        );
      }
      final expected = readLe32(input, cursor);
      cursor += 4;
      if (verifyChecksum) {
        final hasher = Xxh64();
        if (length > 0) hasher.update(buffer, 0, length);
        final actual = hasher.digest().low32;
        if ((actual & 0xFFFFFFFF) != expected) {
          throw ZstdException(
            ZstdErrorCode.checksumMismatch,
            'frame content checksum mismatch',
            offset: cursor - 4,
          );
        }
      }
    }

    if (header.hasContentSize && context.frameOut != header.frameContentSize) {
      throw ZstdException(
        ZstdErrorCode.truncatedInput,
        'frame ended before its declared content size',
        offset: cursor,
      );
    }

    // Do not retain a large buffer for a tiny output (a frame may declare a
    // large content size without actually producing it).
    if (buffer.length > 4096 && length * 4 < buffer.length) {
      final exact = Uint8List(length);
      exact.setRange(0, length, buffer);
      buffer = exact;
    }

    return _DecodedFrame(Uint8List.sublistView(buffer, 0, length), cursor);
  }

  void _applyDictionary(
    FrameHeader header,
    ParsedDictionary? parsedDictionary,
  ) {
    if (header.dictionaryId != 0) {
      if (parsedDictionary == null) {
        throw ZstdException(
          ZstdErrorCode.dictionaryRequired,
          'frame requires dictionary ${header.dictionaryId}',
          offset: header.headerEnd,
        );
      }
      if (parsedDictionary.dictionaryId != header.dictionaryId) {
        throw ZstdException(
          ZstdErrorCode.dictionaryMismatch,
          'frame dictionary ${header.dictionaryId} does not match the '
          'provided dictionary ${parsedDictionary.dictionaryId}',
          offset: header.headerEnd,
        );
      }
    }
  }
}

final class _DecodedFrame {
  _DecodedFrame(this.bytes, this.next);

  final Uint8List bytes;
  final int next;
}

enum _DecoderState {
  magic,
  frameHeader,
  blockHeader,
  blockContent,
  checksum,
  frameEnd,
  skipSize,
  skipData,
}

final class _ZstdDecodingSink extends ByteConversionSink {
  _ZstdDecodingSink(this.decoder, this.sink);

  final ZstdDecoder decoder;
  final Sink<List<int>> sink;

  Uint8List _input = Uint8List(4096);
  int _start = 0;
  int _end = 0;

  _DecoderState _state = _DecoderState.magic;
  FrameContext? _context;
  RingWindow? _ring;
  Xxh64? _hasher;
  ParsedDictionary? _parsedDictionary;
  bool _dictionaryParsed = false;
  bool _sawFrame = false;
  bool _closed = false;
  bool _sinkClosed = false;

  int _blockType = 0;
  int _blockSize = 0;
  int _blockNeeded = 0;
  bool _lastBlock = false;

  /// Decompressed bytes handed to [sink] for the whole conversion, so that
  /// [ZstdDecoder.maxOutputSize] covers concatenated frames as well.
  int _totalOut = 0;

  @override
  void add(List<int> chunk) {
    _checkOpen();
    try {
      final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      _append(bytes, 0, bytes.length);
      _process();
      _compact();
    } on ZstdException {
      rethrow;
    } catch (error) {
      throw ZstdException(
        ZstdErrorCode.invalidFrameHeader,
        'corrupt zstd data: $error',
      );
    }
  }

  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    _checkOpen();
    RangeError.checkValidRange(start, end, chunk.length);
    try {
      if (chunk is Uint8List) {
        _append(chunk, start, end);
      } else {
        final copy = Uint8List.fromList(chunk.sublist(start, end));
        _append(copy, 0, copy.length);
      }
      _process();
      _compact();
      if (isLast) close();
    } on ZstdException {
      rethrow;
    } catch (error) {
      throw ZstdException(
        ZstdErrorCode.invalidFrameHeader,
        'corrupt zstd data: $error',
      );
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    try {
      _process();
      if (_state != _DecoderState.magic || _start != _end) {
        throw const ZstdException(
          ZstdErrorCode.truncatedInput,
          'zstd stream ended in the middle of a frame',
        );
      }
      if (!_sawFrame) {
        throw const ZstdException(
          ZstdErrorCode.truncatedInput,
          'empty zstd stream',
        );
      }
    } on ZstdException {
      rethrow;
    } catch (error) {
      throw ZstdException(
        ZstdErrorCode.invalidFrameHeader,
        'corrupt zstd data: $error',
      );
    }
    // The downstream sink must be closed: buffering sinks (for example
    // `ByteConversionSink.withCallback`) only flush on close.
    if (!_sinkClosed) {
      _sinkClosed = true;
      sink.close();
    }
  }

  void _checkOpen() {
    if (_closed) {
      throw StateError('ZstdDecoder sink is already closed');
    }
  }

  ParsedDictionary? _dictionary() {
    if (_dictionaryParsed) return _parsedDictionary;
    _dictionaryParsed = true;
    final bytes = decoder.dictionary;
    if (bytes == null || bytes.isEmpty) return null;
    return _parsedDictionary = ParsedDictionary.parse(bytes);
  }

  void _process() {
    while (true) {
      switch (_state) {
        case _DecoderState.magic:
          if (_end - _start < 4) return;
          final magic = readLe32(_input, _start);
          _start += 4;
          if (magic == zstdFrameMagic) {
            _sawFrame = true;
            _state = _DecoderState.frameHeader;
          } else if (magic >= zstdSkippableMagicMin &&
              magic <= zstdSkippableMagicMax) {
            _sawFrame = true;
            _state = _DecoderState.skipSize;
          } else {
            throw ZstdException(
              ZstdErrorCode.invalidMagic,
              'not a zstd frame magic',
              offset: _start - 4,
            );
          }
        case _DecoderState.frameHeader:
          if (_end - _start < 1) return;
          final descriptor = _input[_start];
          if (_end - _start < _frameHeaderSize(descriptor)) return;
          final header = parseFrameHeader(
            _input,
            _start,
            _end,
            decoder.maxWindowSize,
          );
          _start += _frameHeaderSize(descriptor);
          final dictionary = _dictionary();
          _checkDictionary(header, dictionary);
          final context = FrameContext(header, dictionary);
          _context = context;
          final ring = RingWindow(header.windowSize);
          _ring = ring;
          if (header.hasContentSize && header.frameContentSize > 0) {
            // Pre-size the ring for frames whose output is small enough to be
            // known up front; this avoids repeated history re-copies while the
            // ring grows. Large/unknown frames keep growing lazily.
            var expected = header.frameContentSize;
            if (expected > header.windowSize) expected = header.windowSize;
            if (expected > (4 << 20)) expected = 4 << 20;
            final limit = decoder.maxOutputSize;
            if (limit != null && expected > limit) expected = limit;
            if (expected > 0) ring.ensure(0, expected + context.blockMax);
          }
          _hasher = (header.contentChecksum && decoder.verifyChecksum)
              ? Xxh64()
              : null;
          _state = _DecoderState.blockHeader;
        case _DecoderState.blockHeader:
          if (_end - _start < 3) return;
          final blockHeader = readLe24(_input, _start);
          _start += 3;
          _lastBlock = (blockHeader & 1) != 0;
          _blockType = (blockHeader >> 1) & 3;
          _blockSize = blockHeader >> 3;
          final context = _context!;
          if (_blockType == 3) {
            throw ZstdException(
              ZstdErrorCode.invalidBlockHeader,
              'reserved block type',
              offset: _start - 3,
            );
          }
          if (_blockType == 0 || _blockType == 1) {
            if (_blockSize > zstdBlockSizeMax) {
              throw ZstdException(
                ZstdErrorCode.invalidBlockHeader,
                'block is too large',
                offset: _start - 3,
              );
            }
          } else if (_blockSize > context.blockMax) {
            throw ZstdException(
              ZstdErrorCode.invalidBlockHeader,
              'compressed block is larger than the block maximum size',
              offset: _start - 3,
            );
          }
          _blockNeeded = _blockType == 1 ? 1 : _blockSize;
          _state = _DecoderState.blockContent;
        case _DecoderState.blockContent:
          if (_end - _start < _blockNeeded) return;
          _decodeBlock();
          _start += _blockNeeded;
          final context = _context!;
          if (context.header.hasContentSize &&
              context.frameOut > context.header.frameContentSize) {
            throw ZstdException(
              ZstdErrorCode.invalidFrameHeader,
              'frame produces more than its declared content size',
              offset: _start,
            );
          }
          if (_lastBlock) {
            _state = context.header.contentChecksum
                ? _DecoderState.checksum
                : _DecoderState.frameEnd;
          } else {
            _state = _DecoderState.blockHeader;
          }
        case _DecoderState.checksum:
          if (_end - _start < 4) return;
          final expected = readLe32(_input, _start);
          _start += 4;
          final hasher = _hasher;
          if (hasher != null) {
            final actual = hasher.digest().low32;
            if ((actual & 0xFFFFFFFF) != expected) {
              throw ZstdException(
                ZstdErrorCode.checksumMismatch,
                'frame content checksum mismatch',
                offset: _start - 4,
              );
            }
          }
          _state = _DecoderState.frameEnd;
        case _DecoderState.frameEnd:
          final context = _context!;
          if (context.header.hasContentSize &&
              context.frameOut != context.header.frameContentSize) {
            throw ZstdException(
              ZstdErrorCode.truncatedInput,
              'frame ended before its declared content size',
              offset: _start,
            );
          }
          _context = null;
          _ring = null;
          _hasher = null;
          _state = _DecoderState.magic;
        case _DecoderState.skipSize:
          if (_end - _start < 4) return;
          _blockSize = readLe32(_input, _start);
          _start += 4;
          _state = _DecoderState.skipData;
        case _DecoderState.skipData:
          if (_end - _start < _blockSize) return;
          _start += _blockSize;
          _state = _DecoderState.magic;
      }
    }
  }

  void _decodeBlock() {
    final context = _context!;
    final ring = _ring!;
    final history = context.windowSize < context.frameOut
        ? context.windowSize
        : context.frameOut;

    if (_blockType == 0) {
      if (context.header.hasContentSize &&
          context.frameOut + _blockSize > context.header.frameContentSize) {
        throw ZstdException(
          ZstdErrorCode.invalidFrameHeader,
          'frame produces more than its declared content size',
          offset: _start,
        );
      }
      _checkOutputSize(_blockSize);
      ring.ensure(history, _blockSize);
      final blockStart = ring.position;
      ring.writeRaw(_input, _start, _blockSize);
      context.blockOut = _blockSize;
      context.frameOut += _blockSize;
      _totalOut += _blockSize;
      _emit(blockStart, _blockSize);
    } else if (_blockType == 1) {
      if (context.header.hasContentSize &&
          context.frameOut + _blockSize > context.header.frameContentSize) {
        throw ZstdException(
          ZstdErrorCode.invalidFrameHeader,
          'frame produces more than its declared content size',
          offset: _start,
        );
      }
      _checkOutputSize(_blockSize);
      ring.ensure(history, _blockSize);
      final blockStart = ring.position;
      ring.fill(_input[_start], _blockSize);
      context.blockOut = _blockSize;
      context.frameOut += _blockSize;
      _totalOut += _blockSize;
      _emit(blockStart, _blockSize);
    } else {
      ring.ensure(history, context.blockMax);
      final blockStart = ring.position;
      final writer = RingBlockOutput(context, ring);
      decodeCompressedBlock(
        context,
        _input,
        _start,
        _start + _blockSize,
        writer,
      );
      final produced = writer.blockOut;
      context.blockOut = produced;
      context.frameOut += produced;
      if (context.header.hasContentSize &&
          context.frameOut > context.header.frameContentSize) {
        throw ZstdException(
          ZstdErrorCode.invalidFrameHeader,
          'frame produces more than its declared content size',
          offset: _start,
        );
      }
      _checkOutputSize(produced);
      _totalOut += produced;
      _emit(blockStart, produced);
    }
  }

  void _checkOutputSize(int produced) {
    final limit = decoder.maxOutputSize;
    if (limit != null && produced > limit - _totalOut) {
      throw ZstdException(
        ZstdErrorCode.outputTooLarge,
        'decompressed output exceeds maxOutputSize ($limit bytes)',
      );
    }
  }

  void _emit(int start, int length) {
    if (length <= 0) return;
    final hasher = _hasher;
    final ring = _ring!;
    ring.forEachSegment(start, length, (bytes) {
      hasher?.update(bytes);
      // Copy: the ring is overwritten by later blocks, while a sink may keep
      // the chunks it receives.
      sink.add(Uint8List.fromList(bytes));
    });
  }

  void _checkDictionary(FrameHeader header, ParsedDictionary? dictionary) {
    if (header.dictionaryId == 0) return;
    if (dictionary == null) {
      throw ZstdException(
        ZstdErrorCode.dictionaryRequired,
        'frame requires dictionary ${header.dictionaryId}',
        offset: _start,
      );
    }
    if (dictionary.dictionaryId != header.dictionaryId) {
      throw ZstdException(
        ZstdErrorCode.dictionaryMismatch,
        'frame dictionary ${header.dictionaryId} does not match the provided '
        'dictionary ${dictionary.dictionaryId}',
        offset: _start,
      );
    }
  }

  int _frameHeaderSize(int descriptor) {
    final singleSegment = (descriptor >> 5) & 1;
    final fcsFlag = descriptor >> 6;
    final dictionaryIdFlag = descriptor & 3;
    final fcsSize = fcsFlag == 0
        ? (singleSegment != 0 ? 1 : 0)
        : (fcsFlag == 1
              ? 2
              : fcsFlag == 2
              ? 4
              : 8);
    final didSize = dictionaryIdFlag == 0
        ? 0
        : (dictionaryIdFlag == 1
              ? 1
              : dictionaryIdFlag == 2
              ? 2
              : 4);
    return 1 + (singleSegment != 0 ? 0 : 1) + didSize + fcsSize;
  }

  void _append(Uint8List data, int start, int end) {
    final count = end - start;
    if (count <= 0) return;
    if (_end + count > _input.length) {
      final remaining = _end - _start;
      if (_start > 0) {
        _input.setRange(0, remaining, _input, _start);
        _start = 0;
        _end = remaining;
      }
      if (_end + count > _input.length) {
        var capacity = _input.isEmpty ? 4096 : _input.length;
        while (capacity < _end + count) {
          capacity <<= 1;
        }
        final grown = Uint8List(capacity);
        grown.setRange(0, _end, _input);
        _input = grown;
      }
    }
    _input.setRange(_end, _end + count, data, start);
    _end += count;
  }

  void _compact() {
    if (_start == _end) {
      _start = 0;
      _end = 0;
      return;
    }
    if (_start > 4096 && _start * 2 > _input.length) {
      final remaining = _end - _start;
      _input.setRange(0, remaining, _input, _start);
      _start = 0;
      _end = remaining;
    }
  }
}
