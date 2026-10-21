/// Cheap frame/block scanner used to decide whether the v2 one-shot decoder
/// can be used for a whole input.
///
/// The v2 decoder writes directly into a pre-sized output buffer and only
/// handles frames with a known content size. This scanner walks frame headers
/// and block headers (without decoding entropy) to sum the declared output
/// sizes. It returns `null` for anything it does not fully understand, so the
/// regular streaming decoder can handle unknown-content-size frames and
/// malformed input with its normal error paths.
library;

import 'dart:typed_data';

import '../common/constants.dart';
import '../common/errors.dart';
import 'bit_stream.dart';
import 'frame.dart';

/// Returns the total declared decompressed size of [input], or `null` when
/// [input] cannot be handled by the fast decoder.
///
/// Throws [ZstdException] with [ZstdErrorCode.outputTooLarge] only when the
/// declared size exceeds [maxOutputSize]; other malformed input returns `null`
/// so the v1 decoder owns the error reporting.
int? fastOutputSize(Uint8List input, int maxWindowSize, int? maxOutputSize) {
  if (input.isEmpty) return null;
  var pos = 0;
  var total = 0;
  var sawFrame = false;

  while (pos < input.length) {
    if (input.length - pos < 4) return null;
    final magic = readLe32(input, pos);
    if (magic >= zstdSkippableMagicMin && magic <= zstdSkippableMagicMax) {
      if (input.length - pos < 8) return null;
      final size = readLe32(input, pos + 4);
      if (size > input.length - pos - 8) return null;
      pos += 8 + size;
      continue;
    }
    if (magic != zstdFrameMagic) return null;
    sawFrame = true;

    final FrameHeader header;
    try {
      header = parseFrameHeader(input, pos + 4, input.length, maxWindowSize);
    } on ZstdException {
      return null;
    }
    if (!header.hasContentSize) return null;
    final contentSize = header.frameContentSize;
    if (contentSize < 0) return null;
    total += contentSize;
    if (maxOutputSize != null && total > maxOutputSize) {
      throw ZstdException(
        ZstdErrorCode.outputTooLarge,
        'decompressed size $total exceeds maxOutputSize $maxOutputSize',
      );
    }
    pos = header.headerEnd;

    var last = false;
    while (!last) {
      if (input.length - pos < 3) return null;
      final blockHeader =
          input[pos] | (input[pos + 1] << 8) | (input[pos + 2] << 16);
      pos += 3;
      last = (blockHeader & 1) != 0;
      final type = (blockHeader >> 1) & 3;
      final size = blockHeader >> 3;
      if (type == 3) return null;
      final payload = type == 1 ? 1 : size;
      if (payload > zstdBlockSizeMax) return null;
      if (payload > input.length - pos) return null;
      pos += payload;
    }
    if (header.contentChecksum) {
      if (input.length - pos < 4) return null;
      pos += 4;
    }
  }

  // A stream consisting only of skippable frames produces no output and is
  // accepted by the existing decoder.
  return sawFrame || total == 0 ? total : null;
}
