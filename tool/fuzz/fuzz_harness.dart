// Shared machinery for the zstd_neo differential fuzz harness.
//
// This file lives outside `test/` so that `tool/fuzz/soak.dart` can reuse the
// exact same generators, campaign plan and checks. It depends on `dart:io`
// because it shells out to the dev-only Rust reference binary in
// `benchmark/rust_ref`; only `test/differential_test.dart` (which is
// `@TestOn('vm')` and gated on `ZSTD_REF`) and `tool/fuzz/soak.dart` import it.
//
// Nothing in the default `dart test` path runs this code: without `ZSTD_REF`
// every differential test is skipped, so the suite stays Rust-free.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:zstd_neo/zstd_neo.dart';

/// Sizes exercised by the differential campaign, from 0 B to 4 MiB.
const List<int> fuzzSizes = <int>[
  0,
  1,
  3,
  4,
  5,
  7,
  31,
  32,
  127,
  128,
  255,
  256,
  1023,
  1024,
  4095,
  4096,
  65535,
  65536,
  131071,
  131072,
  131073,
  262144,
  1048576,
  4194304,
];

/// Payload shapes generated deterministically from a seed.
const List<String> fuzzPatterns = <String>[
  'text',
  'json',
  'csv',
  'binary',
  'zeros',
  'random',
  'repetitive',
];

/// Largest input the default campaign may pick.
const int fuzzMaxSize = 4 * 1024 * 1024;

/// Streaming chunk sizes required by the plan.
const List<int> streamChunkSizes = <int>[1, 7, 31, 1000, 65536];

const List<int> _zstdMagic = <int>[0x28, 0xb5, 0x2f, 0xfd];

const List<String> _words = <String>[
  'zstd',
  'compression',
  'pure',
  'dart',
  'decoder',
  'encoder',
  'huffman',
  'fse',
  'sequence',
  'window',
  'block',
  'literal',
  'match',
  'offset',
  'frame',
  'checksum',
  'dictionary',
  'stream',
  'level',
  'ratio',
  'entropy',
  'table',
  'bitstream',
  'magic',
];

const List<String> _categories = <String>[
  'alpha',
  'beta',
  'gamma',
  'delta',
  'epsilon',
  'zeta',
];

// ---------------------------------------------------------------------------
// Deterministic pseudo-random numbers
// ---------------------------------------------------------------------------

/// Small, fully deterministic xorshift32 PRNG.
///
/// `dart:math`'s `Random` is not specified to be stable across SDK versions, so
/// the harness uses its own generator: a reported `seed` is always enough to
/// reproduce a finding.
final class SeededRandom {
  SeededRandom(int seed)
    : _state = (seed == 0 ? 0x9e3779b9 : seed & 0xFFFFFFFF);

  int _state;

  int nextUint32() {
    var x = _state;
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    _state = x & 0xFFFFFFFF;
    return _state;
  }

  int nextInt(int max) {
    if (max <= 0) return 0;
    return nextUint32() % max;
  }

  bool nextBool() => (nextUint32() & 1) == 1;
}

/// Mixes a base seed with a salt, deterministically and platform-stably.
int mixSeed(int seed, int salt) {
  var x = (seed ^ (salt * 0x9e3779b1)) & 0xFFFFFFFF;
  x ^= x >> 16;
  x = (x * 0x7feb352d) & 0xFFFFFFFF;
  x ^= x >> 15;
  x = (x * 0x846ca68b) & 0xFFFFFFFF;
  x ^= x >> 16;
  return x & 0xFFFFFFFF;
}

/// Stable hash of a pattern name.
int patternSeed(String pattern) {
  var hash = 0x811c9dc5;
  for (final unit in pattern.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}

// ---------------------------------------------------------------------------
// Deterministic payload generation
// ---------------------------------------------------------------------------

/// Builds exactly [size] bytes of [pattern] data, reproducibly from [seed].
Uint8List generateData(int size, String pattern, int seed) {
  if (size <= 0) return Uint8List(0);
  final random = SeededRandom(mixSeed(seed, patternSeed(pattern)));
  switch (pattern) {
    case 'zeros':
      return Uint8List(size);
    case 'random':
      final out = Uint8List(size);
      for (var i = 0; i < size; i++) {
        out[i] = random.nextUint32() & 0xFF;
      }
      return out;
    case 'text':
      return _textData(size, random);
    case 'json':
      return _jsonData(size, random);
    case 'csv':
      return _csvData(size, random);
    case 'binary':
      return _binaryData(size, random);
    case 'repetitive':
      return _repetitiveData(size);
    default:
      throw ArgumentError.value(pattern, 'pattern', 'unknown fuzz pattern');
  }
}

Uint8List _textData(int size, SeededRandom random) {
  final out = Uint8List(size);
  var at = 0;
  var lines = 0;
  while (at < size) {
    final word = _words[random.nextInt(_words.length)];
    for (var i = 0; i < word.length && at < size; i++) {
      out[at++] = word.codeUnitAt(i);
    }
    if (at < size) {
      out[at++] = lines % 12 == 11 ? 0x0A : 0x20;
    }
    lines++;
  }
  return out;
}

Uint8List _jsonData(int size, SeededRandom random) {
  final buffer = StringBuffer('[');
  var id = 0;
  while (buffer.length < size) {
    if (id > 0) buffer.write(',');
    final name = _words[random.nextInt(_words.length)];
    final tag = _words[random.nextInt(_words.length)];
    buffer.write(
      '{"id":$id,"name":"$name-${random.nextInt(1000)}",'
      '"value":${random.nextInt(100000)},"active":${random.nextBool()},'
      '"tags":["$tag","${_categories[random.nextInt(_categories.length)]}"]}',
    );
    id++;
  }
  return _truncatedUtf8(buffer, size);
}

Uint8List _csvData(int size, SeededRandom random) {
  final buffer = StringBuffer('id,name,score,category,flag\n');
  var id = 0;
  while (buffer.length < size) {
    final name = _words[random.nextInt(_words.length)];
    final category = _categories[random.nextInt(_categories.length)];
    buffer.write(
      '$id,$name-${random.nextInt(100)},${random.nextInt(100000)},'
      '$category,${random.nextInt(2)}\n',
    );
    id++;
  }
  return _truncatedUtf8(buffer, size);
}

Uint8List _truncatedUtf8(StringBuffer buffer, int size) {
  final text = buffer.toString();
  final out = Uint8List(size);
  final limit = math.min(size, text.length);
  for (var i = 0; i < limit; i++) {
    out[i] = text.codeUnitAt(i) & 0xFF;
  }
  return out;
}

Uint8List _binaryData(int size, SeededRandom random) {
  final out = Uint8List(size);
  final data = ByteData.sublistView(out);
  var at = 0;
  var record = 0;
  while (at + 16 <= size) {
    data.setUint32(at, record & 0xFFFFFFFF, Endian.little);
    data.setUint32(at + 4, random.nextUint32(), Endian.little);
    data.setUint32(at + 8, random.nextUint32() & 0xFFFF, Endian.little);
    data.setUint32(at + 12, (record * 2654435761) & 0xFFFFFFFF, Endian.little);
    at += 16;
    record++;
  }
  while (at < size) {
    out[at++] = random.nextUint32() & 0xFF;
  }
  return out;
}

Uint8List _repetitiveData(int size) {
  final block = Uint8List(64);
  for (var i = 0; i < block.length; i++) {
    block[i] = 0x61 + ((i * 7 + (i ~/ 5)) % 6);
  }
  final out = Uint8List(size);
  for (var at = 0; at < size; at += block.length) {
    final end = math.min(at + block.length, size);
    out.setRange(at, end, block);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Campaign plan
// ---------------------------------------------------------------------------

/// One differential test case.
final class FuzzCase {
  const FuzzCase({
    required this.index,
    required this.seed,
    required this.dataSeed,
    required this.size,
    required this.pattern,
    required this.level,
    required this.checksum,
  });

  /// Position in the campaign, also used to vary content-size and chunks.
  final int index;

  /// Campaign seed, echoed in failure reports.
  final int seed;

  /// Seed used by [generateData] for this case.
  final int dataSeed;

  final int size;
  final String pattern;
  final int level;
  final bool checksum;

  String get label =>
      'seed=$seed case=#$index size=$size pattern=$pattern '
      'level=$level checksum=${checksum ? 'on' : 'off'}';
}

/// Caps a requested level for a given input size.
typedef LevelCap = int Function(int level, int size);

/// Default cap: high levels only on small inputs, so the whole campaign stays
/// inside the CI time budget even for an optimal parser.
int defaultLevelCap(int level, int size) {
  if (size > 1 << 20) return level > 3 ? 1 + (level % 3) : level;
  if (size > 1 << 18) return level > 6 ? 1 + (level % 6) : level;
  if (size > 1 << 16) return level > 9 ? 1 + (level % 9) : level;
  if (size > 1 << 13) return level > 12 ? 1 + (level % 12) : level;
  return level;
}

/// Decoder-only cap: libzstd can encode any level quickly, and decoding is
/// cheap, so only the 4 MiB inputs are restricted.
int decoderLevelCap(int level, int size) {
  if (size > 1 << 20) return level > 9 ? 1 + (level % 9) : level;
  return level;
}

/// Builds a deterministic campaign of at most [cases] cases.
///
/// Coverage cases guarantee that every size (text), every pattern (4 KiB and
/// 64 KiB), every encoder level (4 KiB) and checksum on/off appear; random
/// cases then fill the rest, weighted towards small inputs. All levels are
/// capped by [levelCap] for large sizes.
List<FuzzCase> buildCampaign({
  required int cases,
  required int seed,
  required int maxLevel,
  int maxSize = fuzzMaxSize,
  LevelCap levelCap = defaultLevelCap,
  bool includeCoverage = true,
}) {
  if (cases <= 0 || maxLevel < 1) return <FuzzCase>[];
  final sizes = fuzzSizes
      .where((size) => size <= maxSize)
      .toList(growable: false);
  if (sizes.isEmpty) return <FuzzCase>[];

  final random = SeededRandom(mixSeed(seed, 0xCA11));
  final keys = <String>{};
  final plan = <FuzzCase>[];
  final baseLevel = math.min(3, maxLevel);

  void add(int size, String pattern, int level, bool checksum) {
    if (plan.length >= cases) return;
    final requested = math.max(1, math.min(level, maxLevel));
    final capped = math.max(1, math.min(levelCap(requested, size), maxLevel));
    final key = '$size|$pattern|$capped|$checksum';
    if (!keys.add(key)) return;
    final index = plan.length;
    plan.add(
      FuzzCase(
        index: index,
        seed: seed,
        dataSeed: mixSeed(seed, index * 31 + 7),
        size: size,
        pattern: pattern,
        level: capped,
        checksum: checksum,
      ),
    );
  }

  if (includeCoverage) {
    for (final size in sizes) {
      add(size, 'text', baseLevel, false);
    }
    for (final pattern in fuzzPatterns) {
      if (sizes.contains(4096)) add(4096, pattern, baseLevel, false);
      if (sizes.contains(65536)) add(65536, pattern, baseLevel, false);
    }
    for (final size in const <int>[4, 1024, 65536, 262144]) {
      if (sizes.contains(size)) add(size, 'text', baseLevel, true);
    }
    // One case per level, on a small payload, so every level is exercised.
    for (var level = 1; level <= math.min(maxLevel, 19); level++) {
      add(4096, 'text', level, false);
    }
    if (maxLevel >= 9) {
      add(65536, 'text', 9, false);
      add(65536, 'json', 9, true);
    }
    if (maxLevel >= 15) add(8192, 'text', 15, false);
    if (maxLevel >= 19) add(8192, 'json', 19, true);
  }

  var attempts = 0;
  while (plan.length < cases && attempts < cases * 64) {
    attempts++;
    final size = _pickSize(random, sizes);
    final pattern = fuzzPatterns[random.nextInt(fuzzPatterns.length)];
    final level = 1 + random.nextInt(maxLevel);
    add(size, pattern, level, random.nextBool());
  }
  return plan;
}

int _pickSize(SeededRandom random, List<int> sizes) {
  final weights = <int>[
    for (final size in sizes)
      if (size <= 4096)
        8
      else if (size <= 65536)
        4
      else if (size <= 262144)
        2
      else
        1,
  ];
  var pick = random.nextInt(weights.fold<int>(0, (total, w) => total + w));
  for (var i = 0; i < sizes.length; i++) {
    pick -= weights[i];
    if (pick < 0) return sizes[i];
  }
  return sizes.last;
}

/// Human-readable campaign summary used in test/report output.
String describeCampaign(List<FuzzCase> campaign) {
  final levels = <int, int>{};
  final patterns = <String, int>{};
  var largest = 0;
  for (final fuzzCase in campaign) {
    levels.update(fuzzCase.level, (value) => value + 1, ifAbsent: () => 1);
    patterns.update(fuzzCase.pattern, (value) => value + 1, ifAbsent: () => 1);
    if (fuzzCase.size > largest) largest = fuzzCase.size;
  }
  final levelKeys = levels.keys.toList()..sort();
  final patternKeys = patterns.keys.toList()..sort();
  return 'cases=${campaign.length} '
      'levels={${levelKeys.map((key) => '$key:${levels[key]}').join(', ')}} '
      'patterns={${patternKeys.map((key) => '$key:${patterns[key]}').join(', ')}} '
      'maxSize=$largest';
}

// ---------------------------------------------------------------------------
// Encoder capability probes
// ---------------------------------------------------------------------------

/// Returns the encoder levels that can produce output without throwing.
///
/// Levels that are not implemented throw [UnsupportedError] (or a
/// `ZstdException` with code `unsupportedFeature`); until encoder-core lands
/// levels 4..19 this reports the levels it does support instead of failing.
List<int> probeEncoderLevels({int maxLevel = 19}) {
  final supported = <int>[];
  final probe = Uint8List(128);
  for (var i = 0; i < probe.length; i++) {
    probe[i] = i & 0xFF;
  }
  for (var level = 1; level <= maxLevel; level++) {
    try {
      ZstdEncoder(level: level).compress(probe);
      supported.add(level);
    } on UnsupportedError {
      // Not implemented yet; keep probing the remaining levels.
      continue;
    } on ZstdException catch (error) {
      if (error.code != ZstdErrorCode.unsupportedFeature) rethrow;
    }
  }
  return supported;
}

/// Builds a [ZstdEncoder] with a dictionary when the public constructor
/// accepts one.
///
/// v0.1.0 only has `level`/`checksum`. v0.1.1 adds
/// `ZstdEncoder({int level, bool checksum, Uint8List? dictionary})`. Calling
/// through [Function.apply] keeps this harness compiling against both versions:
/// before the parameter lands it returns `null` (and the dictionary direction
/// is reported as pending), afterwards it is used automatically.
ZstdEncoder? tryCreateEncoderWithDictionary({
  required int level,
  required bool checksum,
  required Uint8List dictionary,
}) {
  try {
    final encoder = Function.apply(
      ZstdEncoder.new,
      const <Object?>[],
      <Symbol, Object?>{
        #level: level,
        #checksum: checksum,
        #dictionary: dictionary,
      },
    );
    return encoder as ZstdEncoder;
  } on NoSuchMethodError {
    return null;
  } on TypeError {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Streaming helpers
// ---------------------------------------------------------------------------

Uint8List compressStreaming(
  ZstdEncoder encoder,
  Uint8List input,
  int chunkSize,
) {
  if (chunkSize <= 0) throw ArgumentError.value(chunkSize, 'chunkSize');
  final builder = BytesBuilder(copy: false);
  final sink = encoder.startChunkedConversion(
    ByteConversionSink.withCallback(builder.add),
  );
  for (var offset = 0; offset < input.length; offset += chunkSize) {
    final end = math.min(offset + chunkSize, input.length);
    sink.add(Uint8List.sublistView(input, offset, end));
  }
  sink.close();
  return builder.takeBytes();
}

Uint8List decompressStreaming(
  ZstdDecoder decoder,
  Uint8List input,
  int chunkSize,
) {
  if (chunkSize <= 0) throw ArgumentError.value(chunkSize, 'chunkSize');
  final builder = BytesBuilder(copy: false);
  final sink = decoder.startChunkedConversion(
    ByteConversionSink.withCallback(builder.add),
  );
  for (var offset = 0; offset < input.length; offset += chunkSize) {
    final end = math.min(offset + chunkSize, input.length);
    sink.add(Uint8List.sublistView(input, offset, end));
  }
  sink.close();
  return builder.takeBytes();
}

/// Picks a stream chunk size, cycling through [streamChunkSizes].
///
/// Tiny chunks are only used for small buffers: a 1-byte add per byte of a
/// 4 MiB payload would dominate the run time without adding coverage.
int pickStreamChunkSize(int variant, int length) {
  final chunk = streamChunkSizes[variant % streamChunkSizes.length];
  if (length > 4096 && (chunk == 1 || chunk == 7)) return 31;
  return chunk;
}

// ---------------------------------------------------------------------------
// Assertions and reporting helpers
// ---------------------------------------------------------------------------

bool hasZstdMagic(Uint8List frame) {
  if (frame.length < _zstdMagic.length) return false;
  for (var i = 0; i < _zstdMagic.length; i++) {
    if (frame[i] != _zstdMagic[i]) return false;
  }
  return true;
}

bool bytesEqual(List<int> actual, List<int> expected) {
  if (actual.length != expected.length) return false;
  for (var i = 0; i < actual.length; i++) {
    if (actual[i] != expected[i]) return false;
  }
  return true;
}

String describeBytesDifference(Uint8List actual, Uint8List expected) {
  final limit = math.min(actual.length, expected.length);
  var offset = 0;
  while (offset < limit && actual[offset] == expected[offset]) {
    offset++;
  }
  final buffer = StringBuffer(
    'length actual=${actual.length} expected=${expected.length}, '
    'first difference at byte $offset',
  );
  if (offset < limit) {
    buffer.write(
      ', actual=${_hexSnippet(actual, offset)} '
      'expected=${_hexSnippet(expected, offset)}',
    );
  }
  return buffer.toString();
}

String _hexSnippet(Uint8List bytes, int center, {int radius = 4}) {
  final start = math.max(0, center - radius);
  final end = math.min(bytes.length, center + radius + 1);
  final buffer = StringBuffer();
  for (var i = start; i < end; i++) {
    if (buffer.isNotEmpty) buffer.write(' ');
    buffer.write(bytes[i].toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

String describeError(Object error) {
  if (error is ZstdException) {
    final offset = error.offset == null ? '' : ' at offset ${error.offset}';
    return 'ZstdException(${error.code.name}): ${error.message}$offset';
  }
  return '${error.runtimeType}: $error';
}

String stackHead(StackTrace stack, {int lines = 8}) {
  final all = stack.toString().split('\n');
  return (all.length <= lines ? all : all.take(lines)).join('\n');
}

/// A single differential finding.
final class FuzzFailure {
  FuzzFailure(this.phase, this.detail);

  final String phase;
  final String detail;

  @override
  String toString() => '[$phase] $detail';
}

/// Bounded failure list: fuzzing keeps going until [max] findings are known.
final class FailureCollector {
  FailureCollector({this.max = 20});

  final int max;
  final List<FuzzFailure> failures = <FuzzFailure>[];

  bool get isEmpty => failures.isEmpty;
  bool get isNotEmpty => failures.isNotEmpty;
  bool get shouldStop => failures.length >= max;

  void add(FuzzFailure failure) {
    if (failures.length < max) failures.add(failure);
  }

  String summary() => failures.map((failure) => failure.toString()).join('\n');
}

/// Runs [action] and records a finding unless it throws [ZstdException].
void expectZstdException({
  required FailureCollector failures,
  required String phase,
  required String description,
  required void Function() action,
}) {
  try {
    action();
    failures.add(
      FuzzFailure(
        phase,
        '$description: decoded successfully, expected a '
        'ZstdException',
      ),
    );
  } on ZstdException {
    // Expected.
  } catch (error, stack) {
    failures.add(
      FuzzFailure(
        phase,
        '$description: threw ${describeError(error)}\n${stackHead(stack)}',
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Rust reference CLI wrapper
// ---------------------------------------------------------------------------

final class ZstdRefException implements Exception {
  const ZstdRefException(this.message);

  final String message;

  @override
  String toString() => 'ZstdRefException: $message';
}

/// Thin wrapper around `benchmark/rust_ref`'s `encode`/`decode` subcommands.
///
/// The CLI is file based; scratch files live under `benchmark/.out/fuzz/` so
/// sandboxed Windows machines never need the system temp directory.
final class ZstdRef {
  ZstdRef._(this.executable, this._scratch);

  static Future<ZstdRef> start({
    required String executable,
    required Directory scratchRoot,
  }) async {
    final file = File(executable);
    if (!file.existsSync()) {
      throw ZstdRefException('ZSTD_REF does not exist: ${file.absolute.path}');
    }
    final scratch = Directory('${scratchRoot.path}/zstd-ref')
      ..createSync(recursive: true);
    final ref = ZstdRef._(file.absolute.path, scratch);
    final result = await ref._exec(const <String>['version']);
    ref._version = result.stdout.toString().trim();
    return ref;
  }

  final String executable;
  final Directory _scratch;

  String _version = '';
  int _counter = 0;

  String get version => _version;

  Future<ProcessResult> _exec(List<String> args) async {
    final ProcessResult result;
    try {
      result = await Process.run(executable, args);
    } on ProcessException catch (error) {
      throw ZstdRefException('failed to run $executable: ${error.message}');
    }
    if (result.exitCode != 0) {
      throw ZstdRefException(
        '`zstd_ref ${args.first}` exited ${result.exitCode}: '
                '${result.stderr}'
            .trim(),
      );
    }
    return result;
  }

  String _nextId() => (_counter++).toString().padLeft(6, '0');

  void _delete(String path) {
    final file = File(path);
    if (file.existsSync()) file.deleteSync();
  }

  /// `zstd_ref encode`: one complete frame for [data].
  Future<Uint8List> encode(
    Uint8List data, {
    int level = 3,
    bool checksum = false,
    bool contentSize = true,
    Uint8List? dictionary,
  }) async {
    final id = _nextId();
    final inputPath = '${_scratch.path}/in-$id.bin';
    final outputPath = '${_scratch.path}/out-$id.zst';
    String? dictionaryPath;
    try {
      File(inputPath).writeAsBytesSync(data);
      final args = <String>[
        'encode',
        inputPath,
        outputPath,
        '--level',
        '$level',
      ];
      if (checksum) args.add('--checksum');
      if (!contentSize) args.add('--no-content-size');
      if (dictionary != null && dictionary.isNotEmpty) {
        dictionaryPath = '${_scratch.path}/dict-$id.bin';
        File(dictionaryPath).writeAsBytesSync(dictionary);
        args.addAll(<String>['--dictionary', dictionaryPath]);
      }
      await _exec(args);
      return File(outputPath).readAsBytesSync();
    } finally {
      _delete(inputPath);
      _delete(outputPath);
      if (dictionaryPath != null) _delete(dictionaryPath);
    }
  }

  /// `zstd_ref decode`: libzstd's view of [frame].
  Future<Uint8List> decode(Uint8List frame, {Uint8List? dictionary}) async {
    final id = _nextId();
    final inputPath = '${_scratch.path}/in-$id.zst';
    final outputPath = '${_scratch.path}/out-$id.bin';
    String? dictionaryPath;
    try {
      File(inputPath).writeAsBytesSync(frame);
      final args = <String>['decode', inputPath, outputPath];
      if (dictionary != null && dictionary.isNotEmpty) {
        dictionaryPath = '${_scratch.path}/dict-$id.bin';
        File(dictionaryPath).writeAsBytesSync(dictionary);
        args.addAll(<String>['--dictionary', dictionaryPath]);
      }
      await _exec(args);
      return File(outputPath).readAsBytesSync();
    } finally {
      _delete(inputPath);
      _delete(outputPath);
      if (dictionaryPath != null) _delete(dictionaryPath);
    }
  }

  void dispose() {
    if (_scratch.existsSync()) _scratch.deleteSync(recursive: true);
  }
}

// ---------------------------------------------------------------------------
// Differential phases (shared by the test file and the soak tool)
// ---------------------------------------------------------------------------

/// (c) Dart encode -> Dart decode, one-shot or streaming.
void runDartRoundTrip({
  required List<FuzzCase> cases,
  required FailureCollector failures,
  bool streaming = false,
  void Function(int completed, int total)? onProgress,
}) {
  var variant = 0;
  for (var index = 0; index < cases.length; index++) {
    if (failures.shouldStop) return;
    final fuzzCase = cases[index];
    onProgress?.call(index, cases.length);
    final data = generateData(
      fuzzCase.size,
      fuzzCase.pattern,
      fuzzCase.dataSeed,
    );
    final phase = streaming ? 'dart-stream-encode' : 'dart-encode';
    final Uint8List frame;
    try {
      final encoder = ZstdEncoder(
        level: fuzzCase.level,
        checksum: fuzzCase.checksum,
      );
      frame = streaming
          ? compressStreaming(
              encoder,
              data,
              pickStreamChunkSize(variant, data.length),
            )
          : encoder.compress(data);
    } catch (error, stack) {
      failures.add(
        FuzzFailure(
          phase,
          '${fuzzCase.label}: encoder threw ${describeError(error)}\n'
          '${stackHead(stack)}',
        ),
      );
      variant++;
      continue;
    }
    if (!hasZstdMagic(frame)) {
      failures.add(
        FuzzFailure(
          phase,
          '${fuzzCase.label}: output has no zstd magic '
          '(length=${frame.length})',
        ),
      );
      variant++;
      continue;
    }
    try {
      final decoded = ZstdDecoder().decompress(frame);
      if (!bytesEqual(decoded, data)) {
        failures.add(
          FuzzFailure(
            'dart-decode',
            '${fuzzCase.label}: ${describeBytesDifference(decoded, data)}',
          ),
        );
      }
    } catch (error, stack) {
      failures.add(
        FuzzFailure(
          'dart-decode',
          '${fuzzCase.label}: ${describeError(error)}\n${stackHead(stack)}',
        ),
      );
    }
    variant++;
  }
}

/// (a) Dart encode -> Rust decode, one-shot or streaming.
Future<void> runDartToRust({
  required ZstdRef ref,
  required List<FuzzCase> cases,
  required FailureCollector failures,
  bool streaming = false,
  void Function(int completed, int total)? onProgress,
}) async {
  var variant = 0;
  for (var index = 0; index < cases.length; index++) {
    if (failures.shouldStop) return;
    final fuzzCase = cases[index];
    onProgress?.call(index, cases.length);
    final data = generateData(
      fuzzCase.size,
      fuzzCase.pattern,
      fuzzCase.dataSeed,
    );
    final phase = streaming ? 'dart-stream-encode' : 'dart-encode';
    final Uint8List frame;
    try {
      final encoder = ZstdEncoder(
        level: fuzzCase.level,
        checksum: fuzzCase.checksum,
      );
      frame = streaming
          ? compressStreaming(
              encoder,
              data,
              pickStreamChunkSize(variant, data.length),
            )
          : encoder.compress(data);
    } catch (error, stack) {
      failures.add(
        FuzzFailure(
          phase,
          '${fuzzCase.label}: encoder threw ${describeError(error)}\n'
          '${stackHead(stack)}',
        ),
      );
      variant++;
      continue;
    }
    if (!hasZstdMagic(frame)) {
      failures.add(
        FuzzFailure(
          phase,
          '${fuzzCase.label}: output has no zstd magic '
          '(length=${frame.length})',
        ),
      );
      variant++;
      continue;
    }
    try {
      final decoded = await ref.decode(frame);
      if (!bytesEqual(decoded, data)) {
        failures.add(
          FuzzFailure(
            'libzstd-decode',
            '${fuzzCase.label}: libzstd decoded the Dart frame to different '
                'bytes: ${describeBytesDifference(decoded, data)}',
          ),
        );
      }
    } on ZstdRefException catch (error) {
      failures.add(
        FuzzFailure(
          'libzstd-decode',
          '${fuzzCase.label}: libzstd rejected the Dart frame: '
              '${error.message}',
        ),
      );
    }
    variant++;
  }
}

/// (b) Rust encode -> Dart decode, one-shot or streaming.
///
/// Every [contentSizeOffEvery]-th case omits the frame content size, which
/// exercises the window-descriptor path instead of the single-segment one.
Future<void> runRustToDart({
  required ZstdRef ref,
  required List<FuzzCase> cases,
  required FailureCollector failures,
  bool streaming = false,
  int contentSizeOffEvery = 4,
  void Function(int completed, int total)? onProgress,
}) async {
  var variant = 0;
  for (var index = 0; index < cases.length; index++) {
    if (failures.shouldStop) return;
    final fuzzCase = cases[index];
    onProgress?.call(index, cases.length);
    if (failures.shouldStop) return;
    final data = generateData(
      fuzzCase.size,
      fuzzCase.pattern,
      fuzzCase.dataSeed,
    );
    final withContentSize =
        contentSizeOffEvery <= 0 || fuzzCase.index % contentSizeOffEvery != 0;
    final contentSizeLabel = withContentSize ? 'on' : 'off';
    final Uint8List frame;
    try {
      frame = await ref.encode(
        data,
        level: fuzzCase.level,
        checksum: fuzzCase.checksum,
        contentSize: withContentSize,
      );
    } on ZstdRefException catch (error) {
      failures.add(
        FuzzFailure(
          'rust-encode',
          '${fuzzCase.label} contentSize=$contentSizeLabel: ${error.message}',
        ),
      );
      continue;
    }
    final phase = streaming ? 'dart-stream-decode' : 'dart-decode';
    try {
      final decoder = ZstdDecoder();
      final decoded = streaming
          ? decompressStreaming(
              decoder,
              frame,
              pickStreamChunkSize(variant, frame.length),
            )
          : decoder.decompress(frame);
      if (!bytesEqual(decoded, data)) {
        failures.add(
          FuzzFailure(
            phase,
            '${fuzzCase.label} contentSize=$contentSizeLabel: '
            '${describeBytesDifference(decoded, data)}',
          ),
        );
      }
    } catch (error, stack) {
      failures.add(
        FuzzFailure(
          phase,
          '${fuzzCase.label} contentSize=$contentSizeLabel: '
          '${describeError(error)}\n${stackHead(stack)}',
        ),
      );
    }
    variant++;
  }
}

/// Dictionary directions: (b) Rust encode with dict -> Dart decode with dict,
/// and (d) Dart encode with dict -> Rust decode with dict once the encoder
/// exposes a `dictionary` parameter.
final class DictionaryReport {
  final List<String> notes = <String>[];
  bool encoderDictionaryAvailable = false;
  int framesChecked = 0;
}

Future<DictionaryReport> runDictionaryDifferential({
  required ZstdRef ref,
  required Directory fixtures,
  required FailureCollector failures,
  required int seed,
}) async {
  final report = DictionaryReport();
  if (!fixtures.existsSync()) {
    report.notes.add('fixture directory missing: ${fixtures.path}');
    return report;
  }

  final dictionaries = <String, Uint8List>{};
  for (final name in const <String>['rawdict', 'structdict']) {
    final file = File('${fixtures.path}/$name.dict');
    if (file.existsSync()) dictionaries[name] = file.readAsBytesSync();
  }
  if (dictionaries.isEmpty) {
    report.notes.add('no dictionary fixtures found under ${fixtures.path}');
    return report;
  }

  for (final entry in dictionaries.entries) {
    final name = entry.key;
    final dictionary = entry.value;
    // Prefer the plaintext the committed dictionary frame was built from, so
    // the encoder has a real chance to reference dictionary content.
    final plaintext = File('${fixtures.path}/$name.bin');
    final data = plaintext.existsSync()
        ? plaintext.readAsBytesSync()
        : generateData(8192, 'text', mixSeed(seed, 0xD1C7));

    // (b) libzstd with dictionary -> pure-Dart decode with dictionary.
    try {
      final frame = await ref.encode(
        data,
        level: 9,
        checksum: true,
        dictionary: dictionary,
      );
      report.framesChecked++;
      try {
        final decoded = ZstdDecoder(dictionary: dictionary).decompress(frame);
        if (!bytesEqual(decoded, data)) {
          failures.add(
            FuzzFailure(
              'dict-decode',
              '$name: ${describeBytesDifference(decoded, data)}',
            ),
          );
        }
      } catch (error, stack) {
        failures.add(
          FuzzFailure(
            'dict-decode',
            '$name: Dart decoder threw ${describeError(error)}\n'
                '${stackHead(stack)}',
          ),
        );
      }
      if (name == 'structdict') {
        expectZstdException(
          failures: failures,
          phase: 'dict-required',
          description: '$name: decoding without its dictionary',
          action: () => ZstdDecoder().decompress(frame),
        );
        final wrong = dictionaries['rawdict'];
        if (wrong != null) {
          expectZstdException(
            failures: failures,
            phase: 'dict-mismatch',
            description: '$name: decoding with the wrong dictionary',
            action: () => ZstdDecoder(dictionary: wrong).decompress(frame),
          );
        }
      }
    } on ZstdRefException catch (error) {
      failures.add(FuzzFailure('rust-encode', '$name: ${error.message}'));
    }

    // (d) pure-Dart encode with dictionary -> libzstd decode with dictionary.
    final encoder = tryCreateEncoderWithDictionary(
      level: 9,
      checksum: true,
      dictionary: dictionary,
    );
    if (encoder == null) {
      report.notes.add(
        '$name: ZstdEncoder has no `dictionary` parameter yet; '
        'Dart-encode direction pending encoder-core',
      );
      continue;
    }
    report.encoderDictionaryAvailable = true;
    final Uint8List frame;
    try {
      frame = encoder.compress(data);
    } catch (error, stack) {
      failures.add(
        FuzzFailure(
          'dart-dict-encode',
          '$name: encoder threw ${describeError(error)}\n${stackHead(stack)}',
        ),
      );
      continue;
    }
    report.framesChecked++;
    try {
      final decoded = await ref.decode(frame, dictionary: dictionary);
      if (!bytesEqual(decoded, data)) {
        failures.add(
          FuzzFailure(
            'dict-libzstd-decode',
            '$name: libzstd decoded the Dart dictionary frame to different '
                'bytes: ${describeBytesDifference(decoded, data)}',
          ),
        );
      }
    } on ZstdRefException catch (error) {
      failures.add(
        FuzzFailure(
          'dict-libzstd-decode',
          '$name: libzstd rejected the Dart dictionary frame: '
              '${error.message}',
        ),
      );
    }
    try {
      final decoded = ZstdDecoder(dictionary: dictionary).decompress(frame);
      if (!bytesEqual(decoded, data)) {
        failures.add(
          FuzzFailure(
            'dict-decode',
            '$name (Dart frame): ${describeBytesDifference(decoded, data)}',
          ),
        );
      }
    } catch (error, stack) {
      failures.add(
        FuzzFailure(
          'dict-decode',
          '$name (Dart frame): ${describeError(error)}\n${stackHead(stack)}',
        ),
      );
    }
    if (name == 'structdict') {
      // A formatted dictionary frame must declare its dictionary id, so
      // libzstd must refuse it without the dictionary.
      try {
        await ref.decode(frame);
        failures.add(
          FuzzFailure(
            'dict-id',
            '$name: libzstd decoded the Dart frame without a dictionary; a '
                'formatted dictionary frame must set the dictionary id',
          ),
        );
      } on ZstdRefException {
        // Expected: the frame header declares a dictionary id.
      }
      expectZstdException(
        failures: failures,
        phase: 'dict-required',
        description: '$name (Dart frame): decoding without its dictionary',
        action: () => ZstdDecoder().decompress(frame),
      );
    }
  }

  // Committed dictionary frames must decode with their sibling dictionary.
  for (final name in const <String>['rawdict', 'structdict']) {
    final zst = File('${fixtures.path}/$name.zst');
    final bin = File('${fixtures.path}/$name.bin');
    final dict = File('${fixtures.path}/$name.dict');
    if (!zst.existsSync() || !bin.existsSync() || !dict.existsSync()) continue;
    report.framesChecked++;
    try {
      final decoded = ZstdDecoder(dictionary: dict.readAsBytesSync())
          .decompress(zst.readAsBytesSync());
      final expected = bin.readAsBytesSync();
      if (!bytesEqual(decoded, expected)) {
        failures.add(
          FuzzFailure(
            'dict-fixture',
            '$name: ${describeBytesDifference(decoded, expected)}',
          ),
        );
      }
    } catch (error, stack) {
      failures.add(
        FuzzFailure(
          'dict-fixture',
          '$name: ${describeError(error)}\n${stackHead(stack)}',
        ),
      );
    }
  }

  return report;
}

/// Ratio sanity: compressible payloads must shrink at [levels], incompressible
/// ones must not blow up beyond a small framing overhead.
void runRatioSanity({
  required List<int> levels,
  required FailureCollector failures,
  required int seed,
}) {
  const compressible = <String>['text', 'json', 'csv', 'repetitive', 'zeros'];
  const ratioSizes = <int>[4096, 65536, 262144];
  for (final level in levels) {
    for (final pattern in compressible) {
      for (final size in ratioSizes) {
        final data = generateData(
          size,
          pattern,
          mixSeed(seed, level * 31 + size + patternSeed(pattern)),
        );
        final Uint8List frame;
        try {
          frame = ZstdEncoder(level: level).compress(data);
        } catch (error, stack) {
          failures.add(
            FuzzFailure(
              'ratio',
              'level=$level pattern=$pattern size=$size: '
                  '${describeError(error)}\n${stackHead(stack)}',
            ),
          );
          continue;
        }
        if (frame.length >= data.length) {
          failures.add(
            FuzzFailure(
              'ratio',
              'level=$level pattern=$pattern size=$size: compressed '
                  '${frame.length} >= raw ${data.length}',
            ),
          );
        }
      }
    }
    for (final size in const <int>[65536, 262144]) {
      final data = generateData(size, 'random', mixSeed(seed, level + size));
      final Uint8List frame;
      try {
        frame = ZstdEncoder(level: level).compress(data);
      } catch (error, stack) {
        failures.add(
          FuzzFailure(
            'ratio',
            'level=$level random size=$size: ${describeError(error)}\n'
                '${stackHead(stack)}',
          ),
        );
        continue;
      }
      final bound = data.length + 1024 + data.length ~/ 50;
      if (frame.length > bound) {
        failures.add(
          FuzzFailure(
            'ratio',
            'level=$level random size=$size: compressed ${frame.length} > '
                'bound $bound (raw ${data.length})',
          ),
        );
      }
    }
  }
}
