/// XXH64, used for the zstd frame content checksum.
///
/// This facade picks the native (64-bit `int`) implementation on the VM and
/// the two-limb implementation on the web.
library;

export 'xxh64_native.dart' if (dart.library.js_interop) 'xxh64_web.dart';
