/// Zstandard format constants shared by the decoder and the encoder.
library;

/// Magic number of a standard zstd frame: `0xFD2FB528`, little-endian.
const int zstdFrameMagic = 0xFD2FB528;

/// Skippable frames use `0x184D2A50 ..= 0x184D2A5F`.
const int zstdSkippableMagicMin = 0x184D2A50;
const int zstdSkippableMagicMax = 0x184D2A5F;

/// Magic number of a formatted dictionary: `0xEC30A437`, little-endian.
const int zstdDictionaryMagic = 0xEC30A437;

/// Maximum uncompressed and compressed block size (128 KiB).
const int zstdBlockSizeMax = 128 * 1024;

/// Minimum window size representable by the frame header (1 KiB).
const int zstdWindowSizeMin = 1 << 10;

/// Default decoder window limit (64 MiB). Comfortably above the 8 MiB the
/// specification recommends, while still bounding memory use.
const int zstdDefaultMaxWindowSize = 64 << 20;

/// The largest `Block_Maximum_Size` is 128 KiB.
const int zstdMaxBlockSize = zstdBlockSizeMax;

/// Size of the streaming checksum state (XXH64).
const int zstdChecksumSize = 4;
