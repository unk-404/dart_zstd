import '../../common/constants.dart';
import 'byte_writer.dart';

/// Block type field values from the format specification.
const int zstdBlockTypeRaw = 0;
const int zstdBlockTypeRle = 1;
const int zstdBlockTypeCompressed = 2;

/// Writes a complete frame header.
///
/// Exactly one of the two shapes is produced:
///
/// * streaming (`singleSegment == false`, `contentSize == null`): a window
///   descriptor is always present and the content size is unknown;
/// * one-shot (`contentSize != null`): the content size is written using the
///   smallest field that can represent it, and `singleSegment` selects whether
///   a window descriptor is present. A single-segment frame implies
///   `Window_Size == Frame_Content_Size`.
void writeFrameHeader(
  ByteWriter output, {
  required int? contentSize,
  required int windowSize,
  required bool singleSegment,
  required bool checksum,
  int dictionaryId = 0,
}) {
  output.writeUint32(zstdFrameMagic);
  final fcsFlag = contentSize == null ? 0 : _fcsFlagFor(contentSize);
  final dictionaryIdFlag = dictionaryId == 0
      ? 0
      : (dictionaryId < 0x100 ? 1 : (dictionaryId < 0x10000 ? 2 : 3));
  final descriptor =
      (fcsFlag << 6) |
      (singleSegment ? 0x20 : 0) |
      (checksum ? 0x04 : 0) |
      dictionaryIdFlag;
  output.writeByte(descriptor);
  if (!singleSegment) {
    output.writeByte(_windowDescriptor(windowSize));
  }
  switch (dictionaryIdFlag) {
    case 0:
      break;
    case 1:
      output.writeByte(dictionaryId);
    case 2:
      output.writeUint16(dictionaryId);
    case 3:
      output.writeUint32(dictionaryId);
  }
  if (contentSize != null) {
    switch (fcsFlag) {
      case 0:
        output.writeByte(contentSize);
      case 1:
        // Two-byte content sizes carry an implicit +256 offset.
        output.writeUint16(contentSize - 256);
      case 2:
        output.writeUint32(contentSize);
      case 3:
        output.writeUint64(contentSize);
    }
  }
}

/// Writes a block header for a block whose content is about to be appended.
void writeBlockHeader(
  ByteWriter output, {
  required int type,
  required int size,
  required bool last,
}) {
  output.writeUint24(_blockHeaderValue(type: type, size: size, last: last));
}

/// Overwrites a block header previously reserved with [writeBlockHeader].
void patchBlockHeader(
  ByteWriter output,
  int offset, {
  required int type,
  required int size,
  required bool last,
}) {
  output.patchUint24(
    offset,
    _blockHeaderValue(type: type, size: size, last: last),
  );
}

int _blockHeaderValue({
  required int type,
  required int size,
  required bool last,
}) {
  if (type < 0 || type > 2) {
    throw ArgumentError.value(type, 'type', 'reserved block type');
  }
  if (size < 0 || size > zstdBlockSizeMax) {
    throw ArgumentError.value(size, 'size', 'block size out of range');
  }
  return (last ? 1 : 0) | (type << 1) | (size << 3);
}

int _fcsFlagFor(int contentSize) {
  if (contentSize < 256) return 0;
  if (contentSize < 65792) return 1;
  if (contentSize <= 0xFFFFFFFF) return 2;
  return 3;
}

/// Encodes `Window_Descriptor` for a power-of-two window size.
int _windowDescriptor(int windowSize) {
  if (windowSize < zstdWindowSizeMin || (windowSize & (windowSize - 1)) != 0) {
    throw ArgumentError.value(
      windowSize,
      'windowSize',
      'must be a power of two >= 1024',
    );
  }
  var windowLog = 0;
  var value = windowSize;
  while (value > 1) {
    value >>= 1;
    windowLog++;
  }
  final exponent = windowLog - 10;
  if (exponent < 0 || exponent > 31) {
    throw ArgumentError.value(windowSize, 'windowSize', 'not representable');
  }
  return exponent << 3;
}
