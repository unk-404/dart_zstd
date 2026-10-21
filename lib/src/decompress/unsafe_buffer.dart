import 'dart:typed_data';

import 'package:blit/unsafe.dart';

/// Ownership handle for a decoded buffer outside the Dart GC.
///
/// The bytes are allocated with blit's [UnsafeBytes] (native `malloc`, or the
/// web WebAssembly memory arena). The caller must call [free] exactly once
/// after finishing with [view]; the handle has no finalizer and no bounds or
/// double-free checks.
final class ZstdBuffer {
  ZstdBuffer._(this._bytes, this.length);

  /// Wraps an existing [UnsafeBytes] allocation.
  ///
  /// [length] is the number of valid decoded bytes. Ownership transfers to
  /// this buffer; call [free] exactly once.
  factory ZstdBuffer.fromUnsafe(UnsafeBytes bytes, int length) =>
      ZstdBuffer._(bytes, length);

  final UnsafeBytes _bytes;

  /// Number of valid decoded bytes at the start of the allocation.
  final int length;

  /// Zero-copy view of the decoded bytes. Do not use after [free].
  Uint8List get view => _bytes.view(length);

  /// Releases the allocation. Double-free/use-after-free is undefined.
  void free() => _bytes.free();
}
