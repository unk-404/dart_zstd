import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zstd_neo/src/common/constants.dart';
import 'package:zstd_neo/src/common/xxh64.dart';
import 'package:zstd_neo/src/decompress/bit_stream.dart';
import 'package:zstd_neo/src/decompress/block.dart';
import 'package:zstd_neo/src/decompress/dictionary.dart';
import 'package:zstd_neo/src/decompress/frame.dart';
import 'package:zstd_neo/src/decompress/window.dart';
import 'package:zstd_neo/zstd_neo.dart';

import 'fixtures/fixtures.g.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Uint8List _b64(String encoded) => base64Decode(encoded);

ZstdFixture _fixture(String name) =>
    webFixtures.firstWhere((fixture) => fixture.name == name);

Uint8List _fixtureZst(String name) => _b64(_fixture(name).zstBase64);

Uint8List _fixtureBin(String name) => _b64(_fixture(name).binBase64);

Uint8List _fixtureDict(String name) => _b64(_fixture(name).dictBase64!);

final class _CountingSink implements Sink<List<int>> {
  final List<int> bytes = <int>[];
  bool closed = false;

  @override
  void add(List<int> data) {
    bytes.addAll(data);
  }

  @override
  void close() {
    closed = true;
  }
}

Uint8List _streamDecode(
  ZstdDecoder decoder,
  Uint8List input,
  List<int> boundaries,
) {
  final sink = _CountingSink();
  final chunked = decoder.startChunkedConversion(sink);
  var previous = 0;
  for (final boundary in boundaries) {
    chunked.add(Uint8List.sublistView(input, previous, boundary));
    previous = boundary;
  }
  chunked.close();
  expect(sink.closed, isTrue);
  return Uint8List.fromList(sink.bytes);
}

List<int> _uniformBoundaries(int length, int chunkSize) {
  final boundaries = <int>[];
  for (var at = chunkSize; at < length; at += chunkSize) {
    boundaries.add(at);
  }
  boundaries.add(length);
  return boundaries;
}

List<int> _randomBoundaries(int length, Random random) {
  final boundaries = <int>[];
  var at = 0;
  while (at < length) {
    at += 1 + random.nextInt(67);
    if (at >= length) break;
    boundaries.add(at);
  }
  boundaries.add(length);
  return boundaries;
}

void _expectZstdException(void Function() action, {ZstdErrorCode? code}) {
  try {
    action();
  } on ZstdException catch (error) {
    if (code != null) expect(error.code, code, reason: error.toString());
    return;
  } catch (error) {
    fail('non-ZstdException escaped: $error');
  }
  fail('expected a ZstdException');
}

const List<int> _magic = <int>[0x28, 0xB5, 0x2F, 0xFD];

List<int> _blockHeader({
  required bool last,
  required int type,
  required int size,
}) {
  final value = (last ? 1 : 0) | (type << 1) | (size << 3);
  return <int>[value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF];
}

List<int> _le32(int value) => <int>[
  value & 0xFF,
  (value >> 8) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 24) & 0xFF,
];

int _xxh64Low32(Uint8List data) {
  final hasher = Xxh64();
  if (data.isNotEmpty) hasher.update(data);
  return hasher.digest().low32 & 0xFFFFFFFF;
}

const int _defaultWindowDescriptor = 10 << 3; // windowLog 20 => 1 MiB.

/// Frame with a window descriptor and any number of raw blocks.
Uint8List _rawBlocksFrame(
  List<Uint8List> blocks, {
  bool checksum = false,
  int windowDescriptor = _defaultWindowDescriptor,
}) {
  final builder = BytesBuilder(copy: false);
  builder.add(_magic);
  builder.add(<int>[checksum ? 0x04 : 0x00, windowDescriptor]);
  final all = BytesBuilder(copy: false);
  for (var i = 0; i < blocks.length; i++) {
    builder.add(
      _blockHeader(
        last: i == blocks.length - 1,
        type: 0,
        size: blocks[i].length,
      ),
    );
    builder.add(blocks[i]);
    all.add(blocks[i]);
  }
  if (checksum) builder.add(_le32(_xxh64Low32(all.toBytes())));
  return builder.toBytes();
}

Uint8List _rleBlocksFrame(
  int blockCount,
  int blockSize,
  int value, {
  bool checksum = false,
}) {
  final builder = BytesBuilder(copy: false);
  builder.add(_magic);
  builder.add(<int>[checksum ? 0x04 : 0x00, _defaultWindowDescriptor]);
  final output = Uint8List(blockCount * blockSize)
    ..fillRange(0, blockCount * blockSize, value);
  for (var i = 0; i < blockCount; i++) {
    builder.add(
      _blockHeader(last: i == blockCount - 1, type: 1, size: blockSize),
    );
    builder.addByte(value);
  }
  if (checksum) builder.add(_le32(_xxh64Low32(output)));
  return builder.toBytes();
}

Uint8List _windowRawFrame(Uint8List payload, {int windowDescriptor = 0}) {
  final builder = BytesBuilder(copy: false);
  builder.add(_magic);
  builder.add(<int>[0x00, windowDescriptor]);
  builder.add(_blockHeader(last: true, type: 0, size: payload.length));
  builder.add(payload);
  return builder.toBytes();
}

Uint8List _singleSegmentFrame(List<int> payload, {bool checksum = false}) {
  final content = Uint8List.fromList(payload);
  final builder = BytesBuilder(copy: false)
    ..add(_magic)
    ..add(<int>[(1 << 5) | (checksum ? 1 << 2 : 0), content.length])
    ..add(_blockHeader(last: true, type: 0, size: content.length))
    ..add(content);
  if (checksum) builder.add(_le32(_xxh64Low32(content)));
  return builder.toBytes();
}

Uint8List _skippableFrame(List<int> userData, {int tag = 0}) {
  final builder = BytesBuilder(copy: false)
    ..add(_le32(0x184D2A50 + tag))
    ..add(_le32(userData.length))
    ..add(userData);
  return builder.toBytes();
}

Uint8List _corruptCopy(Uint8List bytes, int index, [int mask = 0xFF]) {
  final copy = Uint8List.fromList(bytes);
  copy[index] ^= mask;
  return copy;
}

/// Deterministic large plaintext shared with the reference encoder that
/// produced [_largeFrameBase64].
Uint8List _deterministicText(int length) {
  const words = <String>[
    'zstandard',
    'frame',
    'block',
    'sequence',
    'literal',
    'window',
    'dart',
    'web',
    'decode',
    'checksum',
    'dictionary',
    'entropy',
    'huffman',
    'fse',
    'offset',
    'match',
    'stream',
    'level',
    'table',
    'token',
  ];
  var state = 0x12345678;
  int next() {
    state = (state * 1664525 + 1013904223) & 0x7FFFFFFF;
    return (state >> 16) & 0x7FFF;
  }

  final output = Uint8List(length);
  var at = 0;
  while (at < length) {
    final word = words[next() % words.length];
    final repetitions = 1 + next() % 7;
    for (var r = 0; r < repetitions && at < length; r++) {
      final unit = word.codeUnits;
      for (var i = 0; i < unit.length && at < length; i++) {
        output[at++] = unit[i];
      }
      if (at < length && next() % 5 == 0) output[at++] = 0x0A;
      if (at < length) output[at++] = 0x20;
    }
  }
  return output;
}

/// libzstd 1.5.7 frame (level 19, checksum) for `_deterministicText(192 KiB)`.
const String _largeFrameBase64 =
    'KLUv/aQAAAMABD4BgsscFZC5xcAbrhSfbYCoIu24u7uzWZtWAf+/5v//////mj8St/JFzVSjpqGm4VEGz8ThWl0p1NqEv+uOjQi4tQejEGDKuqSENcKx0S1cARGHDgYDYwdmj7A/60661QUhgsgG8ESdJCTpiMwjsA1NwsNAtYSD2pCBqGS/EAHQAgMwALBAEAgHiMXj8Zw6fRQAAAAKDDgIwABgwAMAQUMAKwAPABQBDIQBADgEGAEYMAFYDMHqMWFzO0TNh8t9PR7H4Z9rLVZvXXq9r8yp6xOp3JdZB2aJdu6KIrD5sjigEnRCBvYtiUe+ssLmsEzlglmvw1gZBnvJuL3i6dlrNOa5RNhrYJLgjPl9Tz0sJzc8aMqxBZtREMFxGbWktQsI0vR0tECGg0wqdmBB1Wtze/UDCp11POYGMgb2LVgSg/XIksUJ69ziD4owFMj0fcifWyRhkemstvtC+4fgW9qWyVwf5V8ec4kma8IXCeCn3Z3dI+fbHA22QdLx0m+tyWaozPRVjUS4IlFmrVWg1Wqe0SejFqu85YRo7yLNVs1EirmDFogHOfDnXoj3sbvOpadzfRNAr7csZd/QkTd/oap+9Zz50bsJIpkCrgsp/1n7nZZoMpuXvaNU8uV1CiMK3PH7pnr25XJqs3A2LP56gPesm5ctJGT4e94l96vPz4kPW26cDtkfF9Ey3sLy0jvaW5xUJ0l3QUCllXq7RFTRduOgQ9yOQjqyeSSLjnFZvdecYttPgU5ulzbaTz6KxkR5V5SSC/KeyZrWwDKb4sRREmrKzazKcQ1VBh4uZ2jKJe/7VrBPO2yZEer/bPEPWu6O9w9FhQfCkYa/n836KzseRUtyxUy3rlor6BDyT77PimrcDSheaeNBrSHR9M2bZJAKCfJO/+yfCtdabu6jeFkbQq/iQagQcYV0bdb4SNvC9UtZoKt1YTTg53oREs5eqc1kT0HgX0Sn5wsp4SYLwQG718L7/SWZqENtJ53oc4oq9pf/mm3idEc7MHEwYzfNTJ6f3iuLhmi1MGs7rpSgwd5SI72MO5iItk0hBJ6g3aMBMmelzc8a4m57ki5ugGYJZ52JLsfBYNhQLuIqsPSfxqXK+cbBYOMkXVtvU0h2l4KAFkdBNGkDUawPthWSLDzFIIlihg1uxO6S3wykSFkGQX5JG9cR1eCvQThH3KmkVmKfK7/ueQrd7A2B+xG86GEEyS5jteFIpCFRrO6JEi3Oz27LU/OQFdgqQkTC73UIFI4IaeezBiVkI9e2nI50QcudNBOi76VU1F5T2WuOSSL4OPaNzVToduCqKHbYllor9vSWDNnDY4Kb3EKAkHsbpRakBE9g46ztTz7Jdkeye1HSD8FrIh/F4CSTH3sBVp8Ytn89TMDAFjkY5fwJ8yJOK4Z/rdp5rVnSjvNsESs3gGvteqcLx0Cn2LIWn3ms+VXN7C4iCHsxXhT4MgD1ODviskl3xfPNlP8b6uZQZbHo0XXEQMM9uLl3i1YyRgN48HZ/YE4ynHsIxgHyFsa2ka4zLIMxNJ3oF0navlAxwBhql90uAy5hEEd9No4n6hkwBQho672LlrX356KLxAvHQSE/vHW7LMWKbO6kcJD/Wc30llNv72fIh1agTKHVLxrDXTOgQHZr+H30Ec2KpNhH8bPY3E+cGIFB2PYA23o0li7hSAFFQUKP91AjOHK6l4AZgLJ5qhDIz6mrBYVxaFuj0xEd0ox7RHJ4bGsc+cPyVFF4VrnlrOlJVLCu5g8REepls8v0CLdlhUgcD2DKu2WRq794xpqtRKBdt1c7rzeLm8xJuiqBIOZPUg/hMKxREIFSTRpVD0tAwaU2XdUefUgRJ9PJHepEFuTcl/fKJJN93gWMPzj5xxfAei7xjW7K+4xx1AQGNrRUWXQ5AwUaLY8RpdVw0c5oDjC7BG8AhYgoprCQNVIT+IdQSIHiWSE3sVsLG4GS6HVzM8DvDfU2BzpdbuwlB8wMaxxFx4wj50z/VHfRpCRmLFLodXeX74Vp4cVbBgn2wquGgHrbrQIcj6Vtzg2Yt4fe4lx237jEQv3NC0Sywv4zypcRA/TmCejEDpXE4VfOm4l6QNqkf+hfTd3szs0EuRB3XgeqTbMobuQQJ9NQqBkrVnPkcdDvm+OTEutBh6k+NvfCUOG5DsrH4VcSV8eI4S+v7v6Cw+BieKzCTk4e5iXjZhG7o6gf5T7O50HP+vkSCZrHQGYw7AhifqUpOhrtLsOxJtbVXXj/ZgTgb3pbsAi6dXRX2izRETpKG3a4mHtm1esgm5uNN2fUqwq54o1A0nTMPWR0oPlr4QxesEomOZqnlIsG9lihUC2viAeuDBUoKPGpTjLcsnXHzdi/+vXP6fXrjeu2fmyDRsnl3XufGicYfL9DjU4qOxjSGGD5weChnicmO8hILiQmoPA0BogUmqU2bB1ZYfDE00gZpN+2d03kog7NSUELIiRxDO+Yuxwwt64HVxvclsuGk57gkD0IRYzRiJEMWQ5VTRjEAM5kNVsHTsN9LhOz4CM+BFdyMpfZTyK7KcmyWqomOIO7Tjb8Q2WLPurLD2hjUfRFG1BkpZoKRsITqnij2JXVSTjjDfKbcm93Ad+py60poflYMxKVjP3LOPySrJK+ODpbSNlz0voLENOqrNw5ZWKR8U9Fg0gJ3P4ISyeEjXURdNKE3gL5SAsPEUpzecfhFV+L7zhH2iQwm1smCd8SqtmiK557TeFUbTnB5OnwbrwF0jDEB1RSdoHGlGQOa2dK+D3t8xfKlvKNuPVjTGnM+J1NzUb1LR9q3QnzAL2GqzPTPxprNUd3tNAnW2LWq5twfNk4ZLeBNinD18aEq1oPAbfD4siq8erOLKIFz2H9zL6O3lwfzqpDar4L2gOytizDIGrn2hHutGaPMdIlq4Ncq4S0V3yDPMuRoUBuyfzR0pj4Z6kVBt8y9OuzotjH5e+y9kwtUYidyAsWddu0ksZ/MnzEiVH5UD3lstVFKqeblqKhTXJre0boXjDaY2AZC6fvUBWoGAmJMgsYlBXBY2evdTsDpW5IESFA+Ei9JEA2gWdosvprL0LY6X4zq5oqagC+drzLJPxuXRU5LwikI1gh9SM0k3rKfnELJ36D2nDrYTLfXvzXFop4bMyAqgZpg/5ycPfCfWFvAtZwVxaeNQMpCT/7+KJFQIWzdXNcNDkg2DMxfWeis80uUigwNq99andprL44b+O37AyiIgFdM1V1HVw0kmWGJ+HFlQ873glAh02yXDt8ZzPj2sWtXeWoKSrQGLoQGZi/hSzcabDikLppjXFjX6ylIjxJcv6ChzrJ2+Hi9qmUjwV0FoVcfZeXB1Yh5QYS4iG6ZJgYpvGWPGMeOgTZGPND/ith1LI5XEb2cju1fGvoV3AhuIcNG2I8O57+TQ0OoaMPNvaW+lsWSDPAAR8fZRZ5h1T3mujj+A6M42eO6EosVXAmPpPdbGPhpB9Tf8J6xVwOhoHDEZ+IbKmr97L6RkzaFjZ3WkmkPDIVACLCMqF1sqSRwGJUXmpwHdsEDe4I5+4bAY43WNMF3LTpTSymuscZ6UWo/jgrGV7FvcjQDUi3d3eD19FU8rZqzlvvlfD9ZnPjRLcZAeP1MP5pQlGMEhVdgGOvB6aQIydhNiz+0E2BRSoeXB8hqQjHFPvMRaJaVCxGuk+vKGO1UMWlC+vp5kDj0w4F69MGyqW0jKpYdMevIEkM+MPANoBs3MzjOhcibkmJsEtcnAnnMz1BjXknywrE/8Il53vtLFBEPoOZ+sQf0qjrRIRYU1EP8DwWRcEhcx4SCtWCoMhJfOIJ7/rqU9m3nHwJ8fYzEHYWGWkqQc8hcQZVnZGdzcb+G6+nQK+BUYXbgNtYKbLFsAo0+uQNOSyaTgcHKNzyh+iiHBVkAXo7OYULVybr+7K5v22rLyCc6+TI2GsYAPcdeffq0uOlqLgqWnHPpzcSG0FrFCdiyjxMReivpdUOMJpKFzRHlYtBRqnHR7g+RQRevnsOHwEwOYSt0EZcA4UBxeFQquEZw3W6HpzwGk+rbA89FfbXEZpQ2o44bzmwJ+uaLu66n1XkebjX+DWKpJMyzdE/v38uOxMbUTUSbGvXAYuYyhsGVa4lKS6YMNz5XnQvoWvbKK/2QRfRpJ2Zum03cv7hYGFI74QUCncrA5k0htW6I5WNEA88k6R10Qp0C1X/l99iJ2DPGw6oV8bXo8KIg8K/gfdIk3nIdAqVeivH9MBNYo/RVcSmbPiyBEZ71QoPl93LLrcfdwZSTuiQFO6LY3vQwiDX5FGa2nA5TTHnJvEeKqh5+y9Jy40U05T8jLTOj7V4ytuRU1kRo1JkWCtaNgSrqiRHAUDhgiuS+doFQEzHDP+tcgbIDZKvd9DYzpaNKH1KxHgnl2jyO0jOY7DQMmELFzn2wj6jHTH65X92AVMVd/E9w2pIgFkulaoOQRxw4wN2irdBtqUvAK/Qn19sKZ5CIWeD/AozqmCIdEN2Kpg7y4DaISZ9AEZY6o7IKcPt1hJF0awTYaWYoBCiy6XlKxCEaG7OI2uzIH5qlNvW77vA6PlKbO7Lc6aN40yj9exJ1CpN2KfBE1z4yH7I/Gc/m1nteSj3fOKw+q6TTc8lSUwz6knSzRLcKBHRihHIzWA4XwkR1BrNjQyRvsLoHZh+w5RMMVkZaI9zDusXfYZKBZ4L1hifNYfJXkEVcchMkTMserXsuv5+vb8MCyCAZ62pPlAhco65TBLvvHEShTYkDF9wfhXiELhcSIlTZk2eGJLsESKXG0WxoBXCI+Sh0QUAUDklQ2eP8ndbajFV2tV1ASocvHUcBhYx4felq6We3Yk98dfqfx8BNLtTWXFHVQo5Clb17LhwJB+itt4RFyJvGpHJg0uL6mK4GkJVku9kvHOmeD/oXxQBzhYSjmxGBsQWxPy75oVmBLCtGNBcpYBRevIqdGKSlRuswhPhEq8+2NWCZ7i5AoxKNy6HdS09OtlySdALxySNcq46Y/MuC8hsojylporCZZDJq8AmFPPSv/vVotvRjh52Ntlq4tn1TIQyDYUX3dli2UC2hZ0DFbRaHkgrqXr6WraIZijRozTZg2vQjGo9cUfGcItC3vbU0p0wq4UekoMOOcEhTF1oXwg6jch3UlVA6ubi8ARHsopSLwhhODWuUmJeEIyBaqwn6g0wePDmFZWyONcYEsjPEC+2WB/vO2EMbIYCxUE5cUltfF4ErwnXiLDZ3bUR+/W02WB0AKgKSC+ePEftSSeT0PjBVgYmOUo1APR/7CS5aoSvjnYP6XAZZW6Ld7gJuehqQO1Uk8q4zFuOnPWGWLTtXECrtH/3nnTKKRogjZ2WXWUEOIlIF+VQzY1gwx2Xy7/CW12zbvx683I5ziS84KtlW3i6oKgl/Vzo2+AlsWDiDiHa2+C1X0P2AB1+CsEdOrB2PNA47vQvOtgAJFriAMu5UGOZLUZfusbxeMR/5x9QpIVh/WtyUE3AiS8ihoZIx/Xj5rBvYXiW0JinPgovnZXB86wcfAiqGo00NlByH1/X0juESPvnVic9CgqjF4IrhufRJbo3wqvuqPVDJXCqyESOqZ1ib3gkfk3pxREH8liUnDN6P36iIwxY75Bwpq0CKCyKyCZ2DxPnlYhbVBAva9JIspSi3/mPAYzqJcOPOBW6AXTZ6bY86YHSApERfh84GaUqnQ9uYhxDFkdyKmDJd+hGd0mzfBwmgU+EF1FITWjsfPF7JfEHcF69HiMyuiPA3J3Ok1sjIV2N+X1eqKdHzjrrxf6uTHXksQrJtUhZTGJPdREtLdQO+/k8PrMLclOYzx8DhpOomIZiqnFAi8/ayx3NhpLeTLxYLYIXNi+1Wo5UPpD8y0DCAlKcY/MQqBc6Z1AkE8K7S4kBDio6W7l7ii2U2GhyEAFVYnEsNH2g/1lcpWsUX7XHcly3N7BTCgIm5fyATQJl8bcLbRflNHdzsqqXHoNwVWPktumXx5VAb3fbG1UiMYiQH2mOSc30sjCpo8OT2mECNqzf5sbA2Xpx/LUTqipud/PG3p1MhIn/fMj0d7zZFShR9Z31zX+OOI/tQrXmYZTislkPbuHRARqZPdqSge5ZAYgNSkAqKKcDBNYtrz959Jg2LBUmjvexD4OSQ3cWPAv5B9aoanPW8fi+fjYQFGqewMZX0fW6ooB4GxAB3NgXwD5poZu4xVbY/sIWZ0FD67/Am/7fBw9HELDMBhyDBm7ok10tgP+9Q2bELZKzcUfXD2V2J7+jwcaCiQX1WKDx2jaX81HWkN62ShiyUn4jxGzO4+hCopplyVJht7LjqX9QR6BQAKWteZTBSd3m8C3ODkyO6oeYpL9jLmTHReUOI0NH7RYHodRQF5VOHziz6KvtSkbu9DPkPfbOjNfWsl7fQij+KHESkTTl40BNQ1yDT+DIAa5RZK+Ieg2poVHKwJcipaDP3XpZgxMM/XRpcliyGu0b/QM9+/6DSchYvxndxv7WlLxPTaFyfQBBxjYwGA2Oz/HNkdQcbqv92GEzZ6RbqdNb92RGolTZNXL8yDES3SYivhmj4/YxFwzKMAiDozZtEysV4StFAi+YOnXgz3Y3sON7sshkP3YyoKavhxwvLMgK0fqPl2yCjpIdbkd1vr3k+J89nWzvm+8bE0UXH7NBGdzXCNmCErRmAjWUpz3FFUqNtivBJ3TiJlNw6VaKbS7SEisBGWbZR2dPfEBWNTf0cKiCi9l/CVA7P6+dC/RWLbZ1N44hhQPichek3DnWFIWqT4S8q0wTsAdMFsX5pZhrjCDTsERtADSPNHvymyk3s+8HflP9etMhD6fKz/l4IIT+ZfzW5zo2iWxN/U7pIXc56DMF3GJgtpF+IH7qWEoY8DTicpi9ME8J/rAIlcqE/OkWEkpl3qfbhbobkROgzJ8epd3cba7kOClasPLqlYcBw2WUTU6hajBzy2Q5Gfr4AILkrGMqj+rPQOr7xrcCTYTrZFrbLfXNX0lb0NoeLHWUFVkL10nxIS2GbSl6XqHT2LS5mt4avFTP+Ybgw2REN7nsAe4gDf1Li2Y1uimTTtM8HnRDKBR/7AFyY0ESzOX+uXb+SQo+FAAkZZx5vGpz3Vtot4aKrYBAmQ6vbIUJVSAnRuVkgxaDu5wDzOAffFdM7Wf1FhHzusap0+fvUeyNiRSSsoEsTiTHVI2kROaNxDY3oMugHTRYcDa1xMVbh2+ZhUdUvUWyMh17n5/bRYjUd5y6ihVhv9KU/nNnFij4/oAqP6ooMt4jepVmiefcSvqi82BPlsQ5348K/VGECrIfhxK5XLhdwYbD7+FHDnkJFqmZ/Aznv7kI7eDVnG4fO70zunkV3OiN8l+xA3zVXMqhnSbsN40SNCAQ9rZDGOpujn/Mj25rizzp99AgNwOPR7S5eLHZIRMUqHQvZMZmUBwx5N9Ey5hRA78UiboiDmtD8wIoOGB5GgeDYvWFwQIB1xA+MTPOlhwLPHSN5iVbvNLj0WGe3Kdd1NOPlybVneze1VYBq6XyJxZm8iCqEqFvez45KJdqAuMvRCiX7QH7rG+ubH3TI+rssBtLL87iG/lv/aXsV4JrR50Yd6BZJu1K1tKuDLRmEN2VQ5IIZcKpd70yC+1T8MfsnpVuaIcYWVxaFh/Mv+h4iGW0e4TbJpMlS3elt4JCxSXGT+yY5QEsC9eFxXr40UlCiEmrt5tuDwfoY+s1o6oNDKcF7m5Sq8VDIG/neeVsQjnSkjBhB1gcAo3YX4PWkhk6aoQqYUrhLMLnnK3Nyb6NfYBkgjA/nfYpDZBt2cGljKq774HwsmSyvZIByE3zdXJOFOZlPFb5WNJDFPB/TANVFB/IAppj6spqlXalNydeOH9xeMx0d1pYqnaqoze+I+AyHAtsskAASsFgiu1/DpTGotCLCNWo9NYf07cLvkTMqccXgu+AK3Hh9YYZEHgd/RAu/+qWpBdzvDydVDkmjBEfGmeRZzM8hDpsNaBKTvxD/6zMtKz+65tJONrfV7IoAXa/FDnN9oTe3ilsC/WWeTBaAzGKZ3ARfNBs53GybnAyVNT1b8wIbAcqwVWbeP79bcpqzD+QFgVaVWwWMYWOCDZK0zE0rwRQEu2n+PHRzGafgBbnZZ+ilsNcQw0d+BN1+lAvYRJV7VcmmHOyRcc5KANPB7UWbtWbcqIkh4kleCts012SqJDID46Hr4bgJ7LqPi+lqNyTjZOp7rr9+bAkvtxDUgB/khzhBwQnFnx3y2aP5eD+QqqNdMcE6P/ET4hpTPM2il3/OxvDQm/pSdG92M9xaRZA224A717YR9/mWyni5x4B3I1aAzATO0S/njUsiK9eUzkf9aHLC4DRayiTZNt7+hjtqgPlYFLQL0CESxN5MaMwVSno6PORyFDIkpHz9fI4LwF712V00V1OIIjiWLrmjrD8uSJQoeffTDIRXW8jGQUbnRtMwrL0sNYBfGJ5zm9XpIfK4lSVVHgocFnuD8XhmsVmdIcy1t+WdkSR0F5AHd7rpQ4nUy3/JzUIA/c4DsVdOF1LJJ5p9Mog061R3UXhNzDWTlrvayL7E6Wh3jsv+xqdbRev/1cmW4Tlo3lemmOhVAM8Y6IUTr1IFa2qosYlFO0Tf2WUaVtcUAFzIQCg0W5kKKqpe24einJp8rTNDbf8EXEgUVUn6YA7ZuXZa7by/UnJZYjxJxmHC4pB1fZsehFSf6snxuYIdjm5LepfE4ymZaO9XDRUEw42TFuLxtWy3jvMQx64DqsYr24dssk+25okXU44I3zKJPJer9H8N9kOBpZS5/0KDabx3IEDpg275Sg8fLp9nkmeFWpO1ASJl1Db626gmuciMoWb+tjpAkiIsLwD41ZRdhDH1FFI4FmAi2RYlTL++z6FfV/zXsBcuBR5jHh3fgCbkqz+P42hxQm8MJ6uEf0rDOFARxqDyuaheOq5s+1CzzemIvtqbTLTNMAYycz/KrPFLPux29E2JCRcepZs0+vepQrSUYTkbRbJKmP/fsq2yEWFbOvGJ96p2U72mb8NOYvRl42/xYD0fs9CyK675XBT0q5V1vm8RoDiV34xQheyBMPzPuBykMobLZOM4KAzaImAI7IgeuO9Dfbpwkobpz0ZoxfSxwKZTg7Zt+X5tvRh59LENoB/hC3TMLfASB7/bHkJS9TI0oCkEYBalF8m8tAUP+iNbBZQ345gBDBymDEx1kGRBC+agw1zFS0Mic/5qw/2nMtRWxY3GcsLvEkCvClUnbIIqRhXm8M//tdiWLUj7Dw0LYV5AtC79f7La62F6rOpPFJk94uIQk0vHjraIyENN9JmqAH/a+TJEwzv6WgfOGSvwfsVormrnM5uRZoD+dRV9EAfxoJsUhLv80gJkIcXyqjNfEU+EWQoUYG1A4tstfUoJ09n3j7iHyJSWGE/DPev6GiGH/dXh0LapYRVpkWVLuKUoYcrAKhBsWpMhL4EngpI1snIDTbloHLYC2FftltThi4R+BZkd7hpVY46gjz8RRgWZTizfFqjcuzwoMu7ZkObMEHlchIzXfNr7H9RdM8C7byXsnTwjo1XUHMjwv9WjfBoFkzwlNyvkzx390RQDklshRA00Wo3pLbRJQm8nCXcRFu5uhJI+eBW26ChDOw1OfPl8ZCdf4OK040yChNLozz/2NC+pwq9/JGEScqROIDRf7Ud7dRzWIgiOp9Y8f+HjqGEEUDDVFXSapLhdC33cyHP0JgzkitEsnSXhnui86YueL+kH93/F/ZgEVcHNyHYceSu+ZWt7QIILG4md1TCHxw92lw8kvdCLPtHNA7GeTyfyx6r7e4HpEIyvkW4V+/KO/XM3ePW9Y4vqBcoG2xI1EKS+pm7DJ3jqMfilAKH8bbC77amCWkdH262y68QqzZdpaEcvJ3kjFP88HuWdcYbRtyx5INNw960DS7iqpznCLX2mH3QTFzfspB8iRoq32FByjLWcg0v1AN1XSpvMcXni7mBPg1+r0i0u5ZUBfk0jHRTImZ9rF5A0X9U4+92/jT7sEx4rghpWy4Il5D7ilior5eZNjQNXjUKSjy83pBoQ6ktLFPeHRn1PnOkE5ZVImEpBONGvUek8k5yhUdD0s3eLTJzqwUWp3+O6obKmcVoVo0ivYlJX3tBgUL8jvrcGsi2JEylhzFsyGNbI162AcQcIIsQUqY15qxwo3l0PEuPtMrTdKuh2uPlYKwOYzUVoFWsq5v2P1v3kbDPzjFQVz8lrfHgFqYoDEAQMRsGN9KI0fXnVZIEXhHpx8IXkg12Qf3VCqNXd49RqAYp1O4d/wNYn0qXYi2ghez0HcYaUBbcb2RwI+aiLImMbVIobFtOVDN2fyCDj6PcoC5sl4iQ6NXyD5luF1GtcP8oJOK7i4zsoa0wQua62O4yDJoLuE8SQbtQWN62p6X6u9i2wtlglfzvrQB5hNTLYSXdNOvBV2OHWqjPpZBrw/3OboR8nCUvX2cPzkXuFU/qVgQ04C1iv663M91htBCKMCwj1v9cbDHXm5CpW6ZHIgQuc7ZgtPzwo4Q/jYqkJxWGHLtATzblPanU/cx/UDggqGPHkbsLVlXWm8fEJ1oEiFBTFpQ47rBbjB13A4oupMTRS1ta/fmbyPHy9wJwJTCgX0Tgix9AaApSzFzU3rkWbsLtDiJJjNyXKKacZxYOWDWCJkdloXzJiM1ZTSLRWRpnNcZ7UH7F1DVhKLGe+h4Iu6CSHIvBiOkrkvPYWL45er6qPCl3QnT/8Y6kPjZwZo5RbIm5q/CfCSizki3uSTCzDNfnXx2LsauNxL0n9OMqRkmIzLY4t+8AcZ1ZoSBwg7XpPcp7IQSyIZYwePHkMNUS5AZnPYubGTsWypKSTWDFiPO3BUMY8EM7PMK3NEXvLZG7ARMjLUJTi/b5iNiths4d0YO2xpDe9dZlhoKot6kIYUQ9IasNaxFA2vqtkY1TsVqn9MR9DiiuSXCcGhCkuNsz96aIXAVhAwUqHFySAI3Um9FY5qe9kCW9+IA28wDkA5W9VP5TzFIqeW3+XORtRiGic4pnwVzVTHv9i3YTjIlFifqHZBo01wWcqC9p4XIrAxueIcVnn8kDGp6Wy+bdeGSwU+C2uDiONQha0ZSXLKF6eOWrpmII5Ii3bXsGoPGNHlOhjeoNFVSv+CXyHcCSork8zst0M/F+UoztdrQKA0YCM7ojbjbiOdIKdSv8kkeqFTAvH5lWyr2zSGdDA/NbQ2TIk4Q7ML68cDPK8jszhW0avsHx5aRv9bFZQiFsb8Bnux/SpUrKqpqNwCS6gd6J01rPCC2AP4pSExOU8wbA8xclXdLTwsGEDCGllKtBiLRu89N17a6KdfjtKdwLXtgXR985JglhhZlg+zGAAPha8hawZ7hqBnMheyfEWXp4BUzTZVCN6v8rmMZU0ZY71GfQrnlI4GzpQpJZev14LFl8b1ewskHrAu36orWJqlgYEZOG6EgIWIVzYtjXpc/NrHDi5PKt2W7IyXVwUL4WUe7poZcVl0oioLSbeaGM4mNnrBDSOi+GYljrIzLdhEv5Vz2TCtXPIonLdMe/f5v3QNe9/1so3AnQT/SY4rsRypnOKfUea2FiwjWripUEfjBldmY/W8ObG4xPx6EnE34OeHpk0/CKTEeotfNOfohM/iSRP9SNRAxw4bLuxwY1nwOrtq4G8iiHz8cmS4XXkzB8jOoEcoPyC5CS9D8L2+zXcodvMqtvk8k0ZE6VlV0ux4MmYKT4DKWYa6nn4F7RassPJsqpJCtiH4zK01/Z9Ag1jeldX+OjnxLgtELH4HHyGZv14haEfLcb+1TwNxSuQuctBqor0paVLUPHBU2MyhOz2wMWkyFmqt8xs3GL790s9PvyxTqXupeFsaStKeMh4tM/tZ6aaH2tAQEnwpTEbZASaNevVfxaaLMtukN4T5nA4kHkE1d57PWf98w+NtNZcYKCg6ZOFG2UVV3FxL5LLgJM6SQq+g9OGau5dKErowtTAhMeT902+XjmZy5LqGnJKC2DdUGFAC4jRYemwpGx4Ho0XRB9wR5bWjCzRkyZ9zRqAMT/z5tsBZK6uxGRjCnFl1Tp+AkW/4rVxeKNsC9WjHPA0ZRawit0sXK4hVe6VfiXtMNUlwdz1W43dcDuWHdtCNhbxGxPBjlxe8RQMiJbXwtvgo7tUhU5N+WoeqBpB+HrfrXsjOrWXO3DIhiV/6hzMpcxIoNofW52PiO6PfVqmtbaJdU6lsBSS6tfoMekQB7KVCtc/ZA+XqFgRVH182CvvygwxuQ7f7OQV1Vd0/xgWT9ebbFvUGoEtRgOxzDJaHlsBT6hB1MBprbvEm4vg5sEY7eQfJotNpY2JgK8uPw+L1rmtfVkmMHMc3795O7yjrvmJNVx9SK/OdLJBGjqmUxqUNWfqUfaIFkoTLDz4M4vVz8o34etmwAlm+kWSPsjS+Y3/mg4eSIh4SPZn2HC3BPk56cKeXnFH0vi2FWhLFZPUfnXIiD8pxMAYn8SRNBa02h97taZDI8mH8+WClIVAdfgZxTp4+1K8B7qwpTBBmWn0Y2o7jwcZXfCkP6rdVvJCAbdS8DvLvS3JFa2vVX6xKvXIJsLWWLs7PWkWr3Zq4MpIrW/vaKOBkP7CLUrChEBSrF7t2MZ6J6plnGRZ4kq+1fnqh81ilVAFONswKkJqy+HFXh1eR0LQByWyMnlGzUr7UslR2jR9bM0xMbi/cvuWqOtsP0YkddJsmlWUOH3AyVWA+Ruo58bQ+cYO3JblZ1a8qq1MxYkpTTeBFKAECjgPkyz6+5YtVufT8BHEGQ73kN94kSYvBlT2dXtaQ5nq1VRz2AwPNz47odMTHbneJQ7U5oUJwG63EHVUCdEQrQeeMTm7soFR6MnZJdk54LFO36aKvQj1qlRkTpg0eXQ3sgwHTt0cMpNnwu3oDYf9XSy8QiRY0V5XtcQlQ8vd2shvbbda09eKj2VyFJIUozNAJ+eKw/Ire4rWXu56hV3CZiWaTLqQ0LCbhvpm2TY3xN7XXrv5Oo0AXhV0mK9dID3xBFClCmRokA1M6MA0I/xPERgIEoloIJx5Nt8ad6qDNWgSjGabx52Ny7JfPH84Y5mPQfi+m5Zcgu0FQ2sxHPMSOdVAae23h5aq5k/JjsrgLhVja5qxn+0P+jJLIU+A5DZzV3IPjJfGrYjhEEVR8c+EF3ZCDYgzdqn+7msWg2L8Phhg/4lj7ncW60ON91oAuigbXTGCZOI9OLeBefbb0IJbklBoUicEy5R1o7kISpSXtiLHT7czUOQ/Ck7QObbESEFQjLsm57jBYCWWCh6BfK25pL0ZsaxImLYt+/kvO2siScC6B9EnGEgAQoF9JOBgee9TWCY0L/HeoRpAvpSUzWF2qXlAAn36WxwDlQfGYfKQwf48yKffZ4BQCMLUD37JHKsnWZJFU0kggihx1BGgdrr9cyA/dJWVGhR2n2Tb45qGdvoe54wGPzio3fkJ4FkkdH6BwTNqd2WyakQ4g8Cz5x2WddR+LvGJCAsje9LatPmqKuWApLFE6eaZCVCq9g1t1D5kTfzx1r19Gh0Y+nDJhbr8/qlljvP6x8Av/9P+qoevUFHiggKmvjX5ysSWmzi7aOdIIw+UAlsXz/BCP33N2NOAvBXePZfpf2E9w92Uv8B9ZMAQQqHKKjjfyMgINBQIAwMDEdFwwGBTO8TkICAgEAAgQCCgwCCQgCIAAYBIoCgRSA4BIgEGEQCNInAJZdb7XSkMlVGctFm46H6C+/C9voTHhnBTGrWgQKfrvOmtCv3iivEpjaEuL7pFh5HrMyyLlfzvzJJmUvAcCIIqBe5zlWzVy2j3dn0a1FByjZaeOO+UBfMjUtdKTKzhP0oB10du0ghed2TUkGLIhXdeIOio7RSXcQMZAKIVoTBZ+NDh+WrFn24IJjpNQdhI5a0iETUxjoZS8j9kF3WgzC7op3gQlMr+6fjstvig4s0YobLHCkEZG+rjTp88ek59Bmm7aukpY43ncWrupLs5qljoC3uK+FDi1tQyTbzmMil3JZj9j1P2vmSU1ZebLKT7QAXoR6WWTzDejsJdRKo+S6w8TJU/XZKn12YRXtKLy9esrM6c0W0lsByiHBHf0SJglkSL3gFoKwxytsxPmpjhLQku9L/YvGpRVVw+Ildfc5bX5svf55u9IpnkVwDC2r0ryFAsMRf3e89wYUPWAtQt8X3hxKIvnYIECT2qCgZhlKxCC+iLp2Bv3LVi++hx+gjzSu8oePNrfxW41ZWi0d6gRuuSUjiDfoCRURBq8/+Eatg9HXbOMj3cJY+Jw+URagtjQ+iD4sJRgblgEkVhE90LWN5/ANMLnmtvbFaNqQJ4hRaO5qlk/i6iyB39t9IcidCelYhn9iAHDNCNe5dMPePrrfD5W1q0k8lrnkGHfPYKditXEC6Yy6AA60bQ7cRz7s7/AFd6D6K68UIet+DPBXT/sFow9Rv3Gun7pc3wOy4VhjyFAT047HRWU77g8lEzSGP5wtyu8XPKeirp7fW0u4JL0UjpBvoWfp20or4YKwkHaCQA98TDhl8dBSinDJzmLj7m+60wQmKnRlv44uqZZruWhi5mehmf3lZykhJWrl/k84Tae1kpte2rkhqDkOcHV1iPNQpcGbAsDVk1hKZXiSa4l8dcS7ZujhQEYslBRTAGP4p7AIMZpPpPIt+2Or0t56LOaQVFHHCI3FL6lfiq6vGnWS5GYuvNsUAjpMTiss/l+ji/hfvSXERnLHyhLGvgObx/yC2G+dhimyCshwNEg18XtRY5SKIwxNxSbqK+0P47qNVJnOj4LeTHlEpJOP+YA1a781YJvAQjdBLQZno7UtqFaIFEtM5mrQIC5dcxaFNLWqfirc8p9HkSZRSXFnKG2hEpm0g3zYwsukJZxHXYj5OM0aqx7om9v80ld4WlS8THQS6XGoG4QCSpQSdL7LXx8WyipUTY67gw0ioRdbH7sm041eo/ID3tsvsCNpPqkP3eOScxYLCfvcyZvM/P3qgfEti2QXBw8E6sDPXtAwHOEHL848ACDkVeLm1Oz9Gp2Y0LMcd5w5VDwfSAUx81Q8rZfa/iLrwVwpmpnKLwkR+kYJsLxw5YQAuHuS0aiwwdpmos7begh4d2/OnDp0OuCLbfl4UZyaLDNOfF91EdCpAgr0Fq4f4otHZm4kJKPE1LA4w2/kws5d3+2MTz/Wj2fF0xiHRENHZ7swwXLSHij+Cla+hmPLN5WY6imMtmF6853lbzOLG7Rkkoh8jRdCkulQF4gdSoAFJqKCH15dlmHq0N4ra+9E9KlD8Bm2gKD1sIxMlm70kyJVY+eQtYRO5CfqbZURoZqYxIbwcoMHREGldkbVsOaQxImpmWpATT8r+xzrA3jI3VvKa1rmASe5oyknIpXnMcaOjvVJPsipQyosu7g1xcvc+2ZYYhQjgWCck3tjFP1jwvP3L4ctFZ8Ma70LbCj0qY+TagLpiynzjEPCpydzvKF7atLGzMd6GvhJyCpMjPEpQm3Za9ggbipy6rw97bGD/kN43AhYgGdQdIxBeESvf0ygJVbnFvO2xp4HmGTC9w9de+Ri2d4vIq9np8+fSvUFoPL57/TLNbS2HMzliwGOrKGP//GNwe6B7kP57gglE5RE60AGxdi1+rnEM+oSjDFbIFY8pmDFnhWP3XMMx6zAlfqKTtKsGxRTsYmYRekmKWEkT5o/tU4n6cYBa8Cv/GZ6F3ttS0hImwc2l13GDb3ZMMOOosX4ptXkAvCjRlkrplCKIRtN4+zVFfcanfhfpEJEPW+pAXyL6WmOvscpUf0ySbGFWv5UfIfnsyoKJnNUJ0qfgxyp1W1cpCku3uQ115knrM+rAhyeFlU//u4+g+iLKI/Y5hFk4atc1Cn95nMUbW+DJwykWQnJl8C0IQGgUojHVikWipdh+PAnriLGCKd40vH2LiUgO5acMl3oIpxj6S7RjIiPzt6IYMZxqhusjcwd4L8esqmaBf4ZVG7CIFJVxI0q0iZIsRaQg2VLNzM0ipfdLKh2mrAafitzYE/oXNv0Tixvq3AR058lJy/7bn9oINagdsRB4Aynql23/zQ75OnyZajalZXJycD539+wKMtfk7cqsFZQGlSjWuDNyZC2sYkhnnxil/5gXsnYc7SvzKtFwX4g83dcI+I636kUX6ElIuCiTt3oe0PsxQDG1W8wbu31A1hdTPLBTuiQ3TKm+3Nt7KI0MnIUP01zTeAaf809iD4hPXPO1dDleJH2uBmFLUT9WPBlBn1wLLNi7bZRAXtT2n38tsvSUCQwG3Dfx0wub2Sw3IG23jgei+rbV2MhSvYIPjEzl7upe+mNnptsjMdFn6zyTGSjo1f+ZHvMfkjOikS6lqBH0GN+0rB91QQRRvS+aNtBwOHrzZPNIdSW+RiVWmuLS+rQ7lBxhpPhntT10CSaefSJo7mnczLpO5H9UudOh3Au5C51gw9LS1aJjy3ApaCXQw7rLjMmLLMZSfg0Jfb6LarTuQEX0HU9p/4ThwNs+ut2PNWzZtfMksXTrn6MzEQD37jqaJZyAqughCr4bDvImjvuJPAdJVJ5Zp9YgzTJ5E2x7IqwQx7NQg0N/dhVoCxJjUzXFAjQlcquaeCpB3kxddB4akGNP0ANyEIxSLUbOrweQO5gJu6VdSBnNKxc3FGFflv9TTl2QHAUV7QFBGD0RxskxTt4yLgPWju3L+ZzUm+iUhvmuEemFFrvjOEh1aKH8ebS6sNPjHysj8x6oy5iLmXymOeFa+pEriYiL6oyO+6dlLC0pCZCA2oT6GaXMY+RoJcvpRprrBs/XnTJgT6g9NU7PsbZrHSbbkHw0bAzJhZVUpC3O/3ZCIb/BimvBnq4F9xmULsXP1Us1NMIr8KRXWupQD+nPJG/tA30xt9ZOW6PROYOrbCDnKwlVO0B30M1kfGICdU0X9FgtgYO0cALNa1+4jL+DqkqaF4EEKdl50i9NMNyeAa9BuPK8pj63NkAeE3VPG4PoKwY22dUR40bUypZojzlScZr9+L1QMMZC0dkKrUVbLXUqTHZMhjck8vFSfjKG1pSCo5HoI8TzcFHv5tUhKUO+p1zoUKIX5CDxFXS8ruM5MmVtNYYbMp20I2fnO9Ldjbp+gO34ubapSnbFc5aYXhjV4Zv0dB3+tb4K/LG4zHR0SpneTIdqX9OkAfmwlGOz6M5VKTIW4ff5qsVwZ2n0XQSDOQTLv8mRrkuILozrSWUYg1QnKOzP3NJ6mnt2Cgh8pExWxcJU4NVKgfENuQwC1CQ72k7sw9M/HYYMXAc/m5XePiB/NHkRZhjyj5tPd84ixz7lH3PRaSxZsHexToAkULZ+Ivs8HwivxdcSPs3GszeZE26C0BXx0UoXyLX0NxW5KH1mCafFvrrmZjGEqsXbd8QHSCwoHL0llXhBV3XEaw1J/zCX1ADrKoloQr74b2Aq+PAdAKhenVKuQEyEwo2nNRFybZNxCAJQaNgzQYBU2gYi39GvChJX7rFPWNrl3prjoptCAcLBO3Vz1MuTnqunZSKDIuLSQaxdYFvgUlJZJTo6mTTjmLIQnh5R8Mc1DW4wG4BKsYoVybD0Lf8I+zySkxII12kGvST3MI/1qapHj/70BBAO7hDV6NAY/6+SiEu8hOoXwC+5iDNup93hFkujzo4KSIor6/AVEcQ9oGdlnfBoOa9ytwbthtyX2G77d36oSfVjJsyqXI5zAiGNx5u97uP4ddArY+qqIxPiklhb5H9Jnddc5/FPPzKk2FcUt9RbbsEwh+ucZD5VIEqEFN5TZrozZ1USGisoobt08rTo5vAxi8xW85DRP9Zy2892ymwj7xBT+yJi+Um5AwJWpZzdtJjy7o9kcd2+LwmbCPDApTsHJdcIQ12B0TaZ9hE6mNtVYnOZJzu04hr1k8xGaY+I97e+BFps5QmRWTGwxGgMI+True2EQ+u+qk3mvGGOwwdkBcvS7I9NrW/fBQdQ8x6qYlAt6JNI2z0x8TETWuArP4FYXDS6j6Om5Cg5dJhVw53y0oq0CSDzvao3bmddS98yxF9s8mbD8La0Cm9xqYPZu4czj+sCYWSFC61H7V6sJ7dm2fnPrj72lupIaxHv1Djsk4QuH8zDeZwoWjpCp7hl3+fujGEipZmJ+6wfQiOH9KJrKOlj53AHsXTkWSILjoiaAazsGddLVSNHf3mkF3EkPlruaERG0Hr6F9dipAB5MAeEonug/sTco9zTkunsqvhTCRKNf+p1s6G6Nv1e/7xa+TB20TZgVQY0OsyQvqYU1CzOI61B5vCR7bSa966V2uMUdbNJcH1yvn8IzErg0A9pwFEehO57ILjU9Bb1AxpwIXzaInsmh+g23tE5HMAo/4VgYmdGYEeXxvhqH3puHTdaJ1UaXqEUG7edDsscGRixkErPdjBZ+T1KZj18EeYyMkqnJPrnBJ75jhFCarO+wtrJ94q9+5OCBZ/jp9a9yYls8MDGVmymbDjcJP/YvA9kc91xtqzh8i1cYNbtYa5FwqcLLz45OYenIwmZG5s50G7U1/oMuJgA/YgoqqcI8EB4/B7MTlY8iSUka3TmhPMCXq7NSbM+XBiRJcgw/JZUnbi8Uql06z/0b2vNnSa57JEFSPw4lR3Hh93xN6FX+GMeJigXQaTZ/7VB70F7G1CkWAzgpFMUiLs6ffRy+V/5pinpFko+0OoMeN7zFRsFj0RXa49oFLER3KbVWtPSLfplIsX+PAryDPC2776Fv3BJGc8FmsqodLo1O/NZoaRMZzf7bXGCaxkmVnEQ3fd0A8JbUSiNE/VPLqmCgyJZvvKiunndU7bOGdsO8tRDhOEK6kqtj3fXPpPFwKtTbeWfkkPfRsATt3SwhA+8YAsBbj+kdR9ptqqyanYmfjXgHqGo2S4bNdCTgMWLDEycLBagx7op3uRLFZSljW6NcmFLhsVDrxhUjat/LbSuyT/Gs+53aVpqYjhqoDqfr7rQefOH4i6OIGLl7bqcTMnL7xNxY3+zM+usa5r9abVjAtOdKSpeBRiCtEmjCWlyXlnBCe3/MZW05NUzVjxWJd3gjPOwLNRQscPWuVQIgAt+P4In3sjs+Jj5wdTQVO6o7Oc4b79r/0GbCjTzws9p/t21rIArd5JmDSvRG6gurZhF4tBUCo/UjJ+bhzqCl0+jZvokC3mqGSGCAHD8d8VNEIBwrhc+HnIW329cE1FG31PxK8g8KcsXId3Bpv0C7qMvuO/qN9y5wI8979D4+Vl9DQOb+CHkxpjGmkctPewj4z+S+LhH+X3MCBq4zsivmZADFCnL0mawy5W9g8tXB+ON8HrqQ50TbepAMzGvLP5UHIItTFGIaqLKXKxiH3ZBguPJu+E7uUGp/pYof9Z29gYhZqTNuY4M2uuHbC2W21zEWJPhnRqS0wc3rU8V6IkQFYkCGuev2FOpxOVZVESEHtUc1InlHPoHA68HG+hSJbRPCer+iZxRksMvV41TqWtE56zEe4WhCjK1Nix8uYD+l01IOHdZHXLY+aoU7cPrSxwAqFAXFZmj9AzSyRC9CM22i8gaFPPZPQ+0Ug90AYP9axeI+DhxzzQ+8qsXfx3X+KKxLDUAKT8392/oL4a8PAJGGH5X7r6V3meRQirH++GnSgPufKz+IqQXawaTcANVUkE0pSz81/TbqSxk0inyaChcHRfX58Mb3LjCRkn8lDPIWvhDgzovfXZo0jFALF9Do0duG2xMpdXfS+FzTXySHzKcmrww8BSC+7YzhSveFmdeRBWq0ZqU29ARFlfm2CaipxSpocTkl6xZ45umU8y4wyWQeBBkqJzG36sv0t/mnIukKp9wEMbEbDzLdqJBpuPdBOKyXzv7oJ678yg+xp2mQt3g8BuK9ZlerBrzfK83bRrlRmn2MurPQ3WnqzcIYJY/53jilCtjDeyjrYEIwqmNXZoW+tfW+XR14XBYyym2L8FMgP6VwyS9GlJPbxCLysm9SO7a3gR2qnaX9H+6gb/mSzVrQEABU8ThxA==';
const int _largeFrameSize = 192 * 1024;

/// Reference FSE-like table used by the internal copy/bit-reader tests.
FrameHeader _frameHeader(int windowSize) => FrameHeader(
  windowSize: windowSize,
  frameContentSize: -1,
  dictionaryId: 0,
  contentChecksum: false,
  singleSegment: false,
  headerEnd: 12,
);

// ---------------------------------------------------------------------------

void main() {
  group('large multi-block frames', () {
    test('reference level-19 frame round-trips', () {
      final frame = _b64(_largeFrameBase64);
      final expected = _deterministicText(_largeFrameSize);
      expect(const ZstdDecoder().decompress(frame), expected);
    });

    test('reference level-19 frame decodes with every chunk granularity', () {
      final frame = _b64(_largeFrameBase64);
      final expected = _deterministicText(_largeFrameSize);
      for (final chunkSize in <int>[1, 2, 3, 7, 31, 32, 33, 64, 997, 65536]) {
        expect(
          _streamDecode(
            const ZstdDecoder(),
            frame,
            _uniformBoundaries(frame.length, chunkSize),
          ),
          expected,
          reason: 'chunkSize=$chunkSize',
        );
      }
    });

    test('crafted 1 MiB raw multi-block frame', () {
      final blocks = List<Uint8List>.generate(8, (block) {
        return Uint8List.fromList(
          List<int>.generate(128 * 1024, (i) => (i * 7 + block) & 0xFF),
        );
      });
      final frame = _rawBlocksFrame(blocks);
      final expected = Uint8List(1 << 20);
      var at = 0;
      for (final block in blocks) {
        expected.setRange(at, at + block.length, block);
        at += block.length;
      }
      expect(const ZstdDecoder().decompress(frame), expected);
      expect(
        _streamDecode(
          const ZstdDecoder(),
          frame,
          _uniformBoundaries(frame.length, 4093),
        ),
        expected,
      );
    });

    test('crafted 1 MiB RLE multi-block frame with checksum', () {
      final frame = _rleBlocksFrame(8, 128 * 1024, 0x5A, checksum: true);
      final expected = Uint8List(1 << 20)..fillRange(0, 1 << 20, 0x5A);
      expect(const ZstdDecoder().decompress(frame), expected);
      expect(
        _streamDecode(
          const ZstdDecoder(),
          frame,
          _uniformBoundaries(frame.length, 1),
        ),
        expected,
      );
      _expectZstdException(
        () => ZstdDecoder(maxOutputSize: (1 << 20) - 1).decompress(frame),
        code: ZstdErrorCode.outputTooLarge,
      );
    });

    test('large frame truncated at representative offsets throws', () {
      final frame = _b64(_largeFrameBase64);
      final cuts = <int>{
        0,
        1,
        3,
        4,
        5,
        6,
        10,
        12,
        frame.length ~/ 4,
        frame.length ~/ 2,
        frame.length - 5,
        frame.length - 1,
      };
      for (final cut in cuts) {
        _expectZstdException(
          () => const ZstdDecoder().decompress(
            Uint8List.sublistView(frame, 0, cut),
          ),
          code: cut == 0 ? ZstdErrorCode.truncatedInput : null,
        );
      }
    });

    test('large frame bit flips throw ZstdException', () {
      final frame = _b64(_largeFrameBase64);
      final random = Random(99);
      for (var iteration = 0; iteration < 60; iteration++) {
        final mutated = _corruptCopy(
          frame,
          random.nextInt(frame.length),
          1 << random.nextInt(8),
        );
        _expectZstdException(() => const ZstdDecoder().decompress(mutated));
      }
    });
  });

  group('window edge cases', () {
    test('window at exactly maxWindowSize is accepted', () {
      final frame = _fixtureZst('text_16k_l3');
      final expected = _fixtureBin('text_16k_l3');
      expect(
        ZstdDecoder(maxWindowSize: expected.length).decompress(frame),
        expected,
      );
      _expectZstdException(
        () => ZstdDecoder(maxWindowSize: expected.length - 1).decompress(frame),
        code: ZstdErrorCode.windowTooLarge,
      );
    });

    test('window descriptor at maxWindowSize is accepted', () {
      final frame = _fixtureZst('json_4k_nocontentsize');
      final expected = _fixtureBin('json_4k_nocontentsize');
      // This fixture uses a 4 KiB window descriptor.
      expect(ZstdDecoder(maxWindowSize: 4096).decompress(frame), expected);
      _expectZstdException(
        () => ZstdDecoder(maxWindowSize: 4095).decompress(frame),
        code: ZstdErrorCode.windowTooLarge,
      );
    });

    test('dictionary frame respects the window boundary', () {
      final frame = _fixtureZst('structdict');
      final dictionary = _fixtureDict('structdict');
      final expected = _fixtureBin('structdict');
      expect(
        ZstdDecoder(
          dictionary: dictionary,
          maxWindowSize: expected.length,
        ).decompress(frame),
        expected,
      );
      _expectZstdException(
        () => ZstdDecoder(
          dictionary: dictionary,
          maxWindowSize: expected.length - 1,
        ).decompress(frame),
        code: ZstdErrorCode.windowTooLarge,
      );
    });

    test('window descriptor exponent/mantissa matrix', () {
      final payload = Uint8List.fromList(<int>[1, 2, 3, 4]);
      // windowLog = 10 + exponent; default limit is 64 MiB = 2^26.
      for (final exponent in <int>[0, 1, 5, 10, 15, 16]) {
        for (final mantissa in <int>[0, 1, 7]) {
          final windowBase = 1 << (10 + exponent);
          final window = windowBase + (windowBase ~/ 8) * mantissa;
          final frame = _windowRawFrame(
            payload,
            windowDescriptor: (exponent << 3) | mantissa,
          );
          if (window <= zstdDefaultMaxWindowSize) {
            expect(
              const ZstdDecoder().decompress(frame),
              payload,
              reason: 'exponent=$exponent mantissa=$mantissa',
            );
          } else {
            _expectZstdException(
              () => const ZstdDecoder().decompress(frame),
              code: ZstdErrorCode.windowTooLarge,
            );
          }
        }
      }
      for (final exponent in <int>[17, 23, 31]) {
        final frame = _windowRawFrame(payload, windowDescriptor: exponent << 3);
        _expectZstdException(
          () => const ZstdDecoder().decompress(frame),
          code: ZstdErrorCode.windowTooLarge,
        );
      }
    });

    test('implementation limit rejects gigantic windows', () {
      final payload = Uint8List.fromList(<int>[1, 2, 3, 4]);
      final frame = _windowRawFrame(payload, windowDescriptor: (31 << 3) | 7);
      _expectZstdException(
        () => ZstdDecoder(maxWindowSize: 1 << 40).decompress(frame),
        code: ZstdErrorCode.windowTooLarge,
      );
    });

    test('one-byte single-segment frame (window 1)', () {
      final frame = _singleSegmentFrame(<int>[0x7F]);
      expect(const ZstdDecoder().decompress(frame), <int>[0x7F]);
    });

    test('minimum window descriptor with a 1 KiB block', () {
      final payload = Uint8List(1024)..fillRange(0, 1024, 0x33);
      expect(const ZstdDecoder().decompress(_windowRawFrame(payload)), payload);
    });
  });

  group('all chunk splits', () {
    test('every two-chunk split of a small frame', () {
      final frame = _fixtureZst('text_16k_l3');
      final expected = _fixtureBin('text_16k_l3');
      for (var split = 0; split <= frame.length; split++) {
        expect(
          _streamDecode(const ZstdDecoder(), frame, <int>[split, frame.length]),
          expected,
          reason: 'split=$split',
        );
        expect(
          _streamDecode(const ZstdDecoder(), frame, <int>[
            0,
            split,
            frame.length,
          ]),
          expected,
          reason: 'split=$split with empty chunk',
        );
      }
    });

    test('every two-chunk split of a window-descriptor frame', () {
      final frame = _fixtureZst('json_4k_nocontentsize');
      final expected = _fixtureBin('json_4k_nocontentsize');
      for (var split = 0; split <= frame.length; split++) {
        expect(
          _streamDecode(const ZstdDecoder(), frame, <int>[split, frame.length]),
          expected,
          reason: 'split=$split',
        );
      }
    });

    test('random splits on every fixture', () {
      final random = Random(20261020);
      for (final fixture in webFixtures) {
        final frame = _b64(fixture.zstBase64);
        final expected = _b64(fixture.binBase64);
        final dictionary = fixture.dictBase64 == null
            ? null
            : _b64(fixture.dictBase64!);
        for (var iteration = 0; iteration < 3; iteration++) {
          expect(
            _streamDecode(
              ZstdDecoder(dictionary: dictionary),
              frame,
              _randomBoundaries(frame.length, random),
            ),
            expected,
            reason: '${fixture.name} iteration=$iteration',
          );
        }
      }
    });

    test('addSlice ranges and isLast', () {
      final frame = _fixtureZst('multiframe');
      final expected = _fixtureBin('multiframe');
      final sink = _CountingSink();
      final chunked = const ZstdDecoder().startChunkedConversion(sink);
      final random = Random(7);
      var at = 0;
      while (at < frame.length) {
        final next = min(frame.length, at + 1 + random.nextInt(97));
        chunked.addSlice(frame, at, next, next == frame.length);
        at = next;
      }
      expect(sink.closed, isTrue);
      expect(sink.bytes, expected);
    });
  });

  group('concatenated and skippable frames', () {
    test('mixed stream with skippable frames and dictionaries', () {
      final text = _fixtureZst('text_4k_nochecksum');
      final json = _fixtureZst('json_4k_contentsize');
      final dictFrame = _fixtureZst('structdict');
      final dictionary = _fixtureDict('structdict');
      final stream = Uint8List.fromList(<int>[
        ..._skippableFrame(const <int>[1, 2, 3]),
        ...text,
        ..._skippableFrame(const <int>[]),
        ...dictFrame,
        ..._skippableFrame(List<int>.filled(1000, 0x55)),
        ...json,
      ]);
      final expected = Uint8List.fromList(<int>[
        ..._fixtureBin('text_4k_nochecksum'),
        ..._fixtureBin('structdict'),
        ..._fixtureBin('json_4k_contentsize'),
      ]);
      final decoder = ZstdDecoder(dictionary: dictionary);
      expect(decoder.decompress(stream), expected);
      for (final chunkSize in <int>[1, 3, 31, 64, 997]) {
        expect(
          _streamDecode(
            ZstdDecoder(dictionary: dictionary),
            stream,
            _uniformBoundaries(stream.length, chunkSize),
          ),
          expected,
          reason: 'chunkSize=$chunkSize',
        );
      }
    });

    test('many concatenated frames', () {
      final single = _fixtureZst('text_4k_nochecksum');
      final expectedSingle = _fixtureBin('text_4k_nochecksum');
      final builder = BytesBuilder(copy: false);
      const frames = 25;
      for (var i = 0; i < frames; i++) {
        builder.add(single);
        if (i % 6 == 0) builder.add(_skippableFrame(<int>[i]));
      }
      final stream = builder.toBytes();
      final expected = Uint8List(expectedSingle.length * frames);
      for (var i = 0; i < frames; i++) {
        expected.setRange(
          i * expectedSingle.length,
          (i + 1) * expectedSingle.length,
          expectedSingle,
        );
      }
      expect(const ZstdDecoder().decompress(stream), expected);
      expect(
        ZstdDecoder(maxOutputSize: expected.length).decompress(stream),
        expected,
      );
      _expectZstdException(
        () =>
            ZstdDecoder(maxOutputSize: expected.length - 1).decompress(stream),
        code: ZstdErrorCode.outputTooLarge,
      );
      expect(
        _streamDecode(
          const ZstdDecoder(),
          stream,
          _uniformBoundaries(stream.length, 509),
        ),
        expected,
      );
    });

    test('garbage after a valid frame throws', () {
      final frame = _fixtureZst('text_4k_nochecksum');
      for (final garbage in <List<int>>[
        <int>[0],
        <int>[1, 2, 3],
        <int>[0x28, 0xB5, 0x2F, 0xFD],
        <int>[0x50, 0x2A, 0x4D, 0x18],
      ]) {
        final stream = Uint8List.fromList(<int>[...frame, ...garbage]);
        _expectZstdException(() => const ZstdDecoder().decompress(stream));
      }
    });

    test('truncated skippable frames throw', () {
      final frame = _skippableFrame(List<int>.filled(50, 7));
      for (var cut = 0; cut < frame.length; cut++) {
        _expectZstdException(
          () => const ZstdDecoder().decompress(
            Uint8List.sublistView(frame, 0, cut),
          ),
        );
      }
    });
  });

  group('checksum hardening', () {
    test('every checksum byte is verified', () {
      final frame = _fixtureZst('text_4k_checksum');
      final expected = _fixtureBin('text_4k_checksum');
      for (var i = 1; i <= 4; i++) {
        final corrupted = _corruptCopy(frame, frame.length - i, 0x01);
        _expectZstdException(
          () => const ZstdDecoder().decompress(corrupted),
          code: ZstdErrorCode.checksumMismatch,
        );
        expect(
          const ZstdDecoder(verifyChecksum: false).decompress(corrupted),
          expected,
        );
      }
    });

    test('streamed checksum corruption throws', () {
      final frame = _fixtureZst('text_4k_checksum');
      final corrupted = _corruptCopy(frame, frame.length - 1, 0x01);
      expect(
        () => _streamDecode(
          const ZstdDecoder(),
          corrupted,
          _uniformBoundaries(corrupted.length, 37),
        ),
        throwsA(
          isA<ZstdException>().having(
            (error) => error.code,
            'code',
            ZstdErrorCode.checksumMismatch,
          ),
        ),
      );
    });

    test('empty frame with checksum corruption', () {
      final frame = _b64('KLUv/SQAAQAAmenYUQ==');
      expect(const ZstdDecoder().decompress(frame), isEmpty);
      final corrupted = _corruptCopy(frame, frame.length - 1, 0x01);
      _expectZstdException(
        () => const ZstdDecoder().decompress(corrupted),
        code: ZstdErrorCode.checksumMismatch,
      );
      expect(
        _streamDecode(
          const ZstdDecoder(verifyChecksum: false),
          corrupted,
          _uniformBoundaries(corrupted.length, 2),
        ),
        isEmpty,
      );
    });
  });

  group('dictionary hardening', () {
    const dictionaryFixtures = <String>['rawdict', 'structdict'];
    for (final name in dictionaryFixtures) {
      test('$name decodes with every chunk granularity', () {
        final frame = _fixtureZst(name);
        final expected = _fixtureBin(name);
        final dictionary = _fixtureDict(name);
        for (final chunkSize in <int>[1, 2, 3, 7, 64, 1000]) {
          expect(
            _streamDecode(
              ZstdDecoder(dictionary: dictionary),
              frame,
              _uniformBoundaries(frame.length, chunkSize),
            ),
            expected,
            reason: 'chunkSize=$chunkSize',
          );
        }
      });

      test('$name rejects missing, empty and truncated dictionaries', () {
        final frame = _fixtureZst(name);
        _expectZstdException(() => const ZstdDecoder().decompress(frame));
        _expectZstdException(
          () => ZstdDecoder(dictionary: Uint8List(0)).decompress(frame),
        );
        final dictionary = _fixtureDict(name);
        for (final length in <int>[1, 4, 8, 16, 64, dictionary.length ~/ 2]) {
          _expectZstdException(
            () => ZstdDecoder(
              dictionary: Uint8List.sublistView(dictionary, 0, length),
            ).decompress(frame),
          );
        }
      });

      test('$name never crashes on corrupted dictionary bytes', () {
        final frame = _fixtureZst(name);
        final expected = _fixtureBin(name);
        final dictionary = _fixtureDict(name);
        for (var i = 0; i < 16; i++) {
          final corrupted = _corruptCopy(dictionary, i, 0x01);
          try {
            final decoded = ZstdDecoder(dictionary: corrupted)
                .decompress(frame);
            // A corrupted dictionary may still be structurally usable; the
            // contract is only that no non-ZstdException can escape.
            expect(decoded.length, expected.length);
          } on ZstdException catch (_) {
            // expected for most corruptions
          }
        }
      });
    }

    test('structured dictionary id mismatch is reported', () {
      final dictionary = _corruptCopy(_fixtureDict('structdict'), 4, 0x01);
      _expectZstdException(
        () =>
            ZstdDecoder(dictionary: dictionary)
                .decompress(_fixtureZst('structdict')),
        code: ZstdErrorCode.dictionaryMismatch,
      );
    });

    test('dictionary buffers are not modified and instances are reusable', () {
      for (final name in dictionaryFixtures) {
        final dictionary = _fixtureDict(name);
        final before = Uint8List.fromList(dictionary);
        final decoder = ZstdDecoder(dictionary: dictionary);
        final expected = _fixtureBin(name);
        for (var i = 0; i < 3; i++) {
          expect(decoder.decompress(_fixtureZst(name)), expected);
        }
        expect(dictionary, before);
      }
    });

    test('dictionary frames honour maxOutputSize while streaming', () {
      final frame = _fixtureZst('rawdict');
      final expected = _fixtureBin('rawdict');
      final dictionary = _fixtureDict('rawdict');
      expect(
        _streamDecode(
          ZstdDecoder(dictionary: dictionary, maxOutputSize: expected.length),
          frame,
          _uniformBoundaries(frame.length, 123),
        ),
        expected,
      );
      expect(
        () => _streamDecode(
          ZstdDecoder(
            dictionary: dictionary,
            maxOutputSize: expected.length - 1,
          ),
          frame,
          _uniformBoundaries(frame.length, 123),
        ),
        throwsA(
          isA<ZstdException>().having(
            (error) => error.code,
            'code',
            ZstdErrorCode.outputTooLarge,
          ),
        ),
      );
    });
  });

  group('corrupt and truncated input', () {
    test('malformed fixtures throw ZstdException', () {
      for (final fixture in malformedFixtures) {
        _expectZstdException(
          () => const ZstdDecoder().decompress(_b64(fixture.zstBase64)),
        );
      }
    });

    test('random bytes never escape as another error type', () {
      final random = Random(424242);
      for (var iteration = 0; iteration < 1200; iteration++) {
        final length = random.nextInt(300);
        final bytes = Uint8List.fromList(
          List<int>.generate(length, (_) => random.nextInt(256)),
        );
        try {
          const ZstdDecoder().decompress(bytes);
        } on ZstdException catch (_) {
          // expected
        } catch (error) {
          fail('non-ZstdException escaped: $error');
        }
      }
    });

    test('random mutations of valid frames never escape', () {
      final random = Random(31337);
      final frames = <Uint8List>[
        _fixtureZst('text_16k_l3'),
        _fixtureZst('golden_zero_seq_2b'),
        _fixtureZst('multiframe'),
        _b64(_largeFrameBase64),
      ];
      for (var iteration = 0; iteration < 400; iteration++) {
        final base = frames[iteration % frames.length];
        final candidate = Uint8List.fromList(base);
        final mutations = 1 + random.nextInt(4);
        for (var m = 0; m < mutations; m++) {
          candidate[random.nextInt(candidate.length)] ^= 1 << random.nextInt(8);
        }
        if (random.nextBool()) {
          final cut = random.nextInt(candidate.length + 1);
          try {
            const ZstdDecoder().decompress(
              Uint8List.sublistView(candidate, 0, cut),
            );
          } on ZstdException catch (_) {
            // expected
          } catch (error) {
            fail('non-ZstdException escaped: $error');
          }
        } else {
          try {
            const ZstdDecoder().decompress(candidate);
          } on ZstdException catch (_) {
            // expected
          } catch (error) {
            fail('non-ZstdException escaped: $error');
          }
        }
      }
    });

    test('unusual block types and headers throw', () {
      final payload = Uint8List.fromList(<int>[1, 2, 3]);
      // Reserved block type.
      final reserved = BytesBuilder(copy: false)
        ..add(_magic)
        ..add(<int>[0x00, 0x00])
        ..add(_blockHeader(last: true, type: 3, size: 1))
        ..addByte(0);
      _expectZstdException(
        () => const ZstdDecoder().decompress(reserved.toBytes()),
        code: ZstdErrorCode.invalidBlockHeader,
      );
      // Reserved frame-header bit.
      _expectZstdException(
        () => const ZstdDecoder().decompress(
          Uint8List.fromList(<int>[..._magic, 0x08]),
        ),
        code: ZstdErrorCode.reservedField,
      );
      // Content size larger than the actual output.
      final frame = _singleSegmentFrame(payload);
      final header = Uint8List.fromList(frame);
      header[5] = payload.length + 10;
      _expectZstdException(() => const ZstdDecoder().decompress(header));
      // Compressed block claiming more bytes than available.
      final truncatedBlock = BytesBuilder(copy: false)
        ..add(_magic)
        ..add(<int>[0x00, 0x00])
        ..add(_blockHeader(last: true, type: 2, size: 1000))
        ..addByte(0);
      _expectZstdException(
        () => const ZstdDecoder().decompress(truncatedBlock.toBytes()),
        code: ZstdErrorCode.truncatedInput,
      );
    });
  });

  group('output size limits', () {
    test('one-shot boundary for the large frame', () {
      final frame = _b64(_largeFrameBase64);
      final expected = _deterministicText(_largeFrameSize);
      expect(
        ZstdDecoder(maxOutputSize: expected.length).decompress(frame),
        expected,
      );
      _expectZstdException(
        () => ZstdDecoder(maxOutputSize: expected.length - 1).decompress(frame),
        code: ZstdErrorCode.outputTooLarge,
      );
    });

    test('streaming boundary for the large frame', () {
      final frame = _b64(_largeFrameBase64);
      final expected = _deterministicText(_largeFrameSize);
      expect(
        _streamDecode(
          ZstdDecoder(maxOutputSize: expected.length),
          frame,
          _uniformBoundaries(frame.length, 777),
        ),
        expected,
      );
      expect(
        () => _streamDecode(
          ZstdDecoder(maxOutputSize: expected.length - 1),
          frame,
          _uniformBoundaries(frame.length, 777),
        ),
        throwsA(
          isA<ZstdException>().having(
            (error) => error.code,
            'code',
            ZstdErrorCode.outputTooLarge,
          ),
        ),
      );
    });

    test('zero output budget rejects non-empty frames only', () {
      expect(
        const ZstdDecoder(maxOutputSize: 0)
            .decompress(_fixtureZst('golden_empty_block')),
        isEmpty,
      );
      _expectZstdException(
        () =>
            const ZstdDecoder(maxOutputSize: 0)
                .decompress(_fixtureZst('text_4k_nochecksum')),
        code: ZstdErrorCode.outputTooLarge,
      );
      expect(
        _streamDecode(
          const ZstdDecoder(maxOutputSize: 0),
          _b64('KLUv/SQAAQAAmenYUQ=='),
          const <int>[13],
        ),
        isEmpty,
      );
    });

    test('skippable data does not count towards the limit', () {
      final stream = Uint8List.fromList(<int>[
        ..._skippableFrame(List<int>.filled(5000, 0x11)),
        ..._fixtureZst('text_4k_nochecksum'),
        ..._skippableFrame(List<int>.filled(5000, 0x22)),
      ]);
      final expected = _fixtureBin('text_4k_nochecksum');
      expect(
        ZstdDecoder(maxOutputSize: expected.length).decompress(stream),
        expected,
      );
      _expectZstdException(
        () =>
            ZstdDecoder(maxOutputSize: expected.length - 1).decompress(stream),
        code: ZstdErrorCode.outputTooLarge,
      );
    });
  });

  group('internal primitives', () {
    test('backward bit reader matches the reference bit reading', () {
      final random = Random(8080);
      for (var stream = 0; stream < 300; stream++) {
        final length = 8 + random.nextInt(64);
        final data = Uint8List.fromList(
          List<int>.generate(length, (_) => random.nextInt(256)),
        );
        if (data[length - 1] == 0) data[length - 1] = 0x80;
        final reader = BackwardBitReader(data, 0, length);
        var position = reader.bitPosition;
        for (var read = 0; read < 48 && position > -40; read++) {
          final n = read % 17 == 0
              ? 17 + random.nextInt(16)
              : random.nextInt(17);
          final expected = _referenceBackward(data, 0, position, n);
          expect(
            reader.readBits(n),
            expected,
            reason: 'stream=$stream read=$read',
          );
          position -= n;
          expect(reader.bitPosition, position);
        }
      }
    });

    test('forward bit reader matches little-endian bit fields', () {
      final random = Random(5150);
      for (var stream = 0; stream < 200; stream++) {
        final length = 16 + random.nextInt(48);
        final data = Uint8List.fromList(
          List<int>.generate(length, (_) => random.nextInt(256)),
        );
        final reader = ForwardBitReader(data, 0, length);
        var consumed = 0;
        for (var read = 0; read < 24; read++) {
          final n = 1 + random.nextInt(16);
          if (consumed + n + 7 > length * 8) break;
          expect(
            reader.readBits(n),
            readBitsLe(data, 0, consumed, n),
            reason: 'stream=$stream read=$read',
          );
          consumed += n;
        }
      }
    });

    test('contiguous match copy matches a naive reference', () {
      final random = Random(1234);
      final cases = <List<int>>[
        for (final offset in <int>[
          1,
          2,
          3,
          4,
          7,
          8,
          16,
          31,
          32,
          63,
          64,
          191,
          192,
          193,
          500,
          1000,
          1200,
          6000,
          7000,
        ])
          for (final length in <int>[
            1,
            2,
            3,
            7,
            64,
            191,
            192,
            300,
            4096,
            20000,
          ])
            <int>[offset, length],
      ];
      for (final item in cases) {
        final offset = item[0];
        final length = item[1];
        const prefill = 1000;
        final dictionary = Uint8List.fromList(
          List<int>.generate(5000, (i) => (i * 13 + 7) & 0xFF),
        );
        final buffer = Uint8List(prefill + length);
        for (var i = 0; i < prefill; i++) {
          buffer[i] = random.nextInt(256);
        }
        final expected = Uint8List.fromList(buffer);
        final context = FrameContext(
          _frameHeader(1 << 20),
          ParsedDictionary(dictionaryId: 0, content: dictionary),
        )..frameOut = prefill;
        final output = ContiguousBlockOutput(context, buffer, prefill);
        final valid = _applyNaiveMatch(
          expected,
          prefill,
          context.frameOut,
          context.windowSize,
          dictionary,
          offset,
          length,
        );
        if (!valid) {
          _expectZstdException(
            () => output.copyMatch(offset, length),
            code: ZstdErrorCode.invalidSequence,
          );
          continue;
        }
        output.copyMatch(offset, length);
        expect(output.blockOut, length);
        expect(buffer, expected, reason: 'offset=$offset length=$length');
      }
    });

    test('ring match copy matches a naive reference including wrap-around', () {
      final random = Random(4321);
      // offset, length, prefill, requested capacity (power of two).
      final cases = <List<int>>[
        <int>[1, 1, 200, 256],
        <int>[8, 100, 200, 512],
        <int>[8, 192, 200, 512],
        <int>[8, 500, 400, 1024],
        <int>[8, 500, 1000, 1024], // write and read both wrap
        <int>[16, 1000, 1000, 1024],
        <int>[32, 4096, 100, 8192],
        <int>[192, 240, 900, 1024],
        <int>[100, 500, 900, 1024],
        <int>[300, 1000, 300, 2048],
      ];
      for (final item in cases) {
        final offset = item[0];
        final length = item[1];
        final prefill = item[2];
        final capacity = item[3];
        final ring = RingWindow(1 << 16);
        ring.ensure(0, capacity);
        expect(ring.capacity, capacity);
        final prefix = Uint8List(prefill);
        for (var i = 0; i < prefill; i++) {
          prefix[i] = random.nextInt(256);
        }
        ring.writeRaw(prefix, 0, prefill);
        expect(ring.position, prefill);
        final expected = Uint8List(prefill + length);
        expected.setRange(0, prefill, prefix);
        final valid = _applyNaiveMatch(
          expected,
          prefill,
          prefill,
          1 << 16,
          null,
          offset,
          length,
        );
        final blockStart = ring.position;
        if (!valid) {
          _expectZstdException(
            () => ring.copyMatch(offset, length),
            code: ZstdErrorCode.invalidSequence,
          );
          continue;
        }
        ring.copyMatch(offset, length);
        final actual = BytesBuilder(copy: false);
        ring.forEachSegment(blockStart, length, actual.add);
        expect(
          actual.toBytes(),
          Uint8List.sublistView(expected, prefill),
          reason:
              'offset=$offset length=$length prefill=$prefill '
              'capacity=$capacity',
        );
      }
    });

    test('ring history growth keeps the retained window', () {
      final ring = RingWindow(1 << 12);
      final written = Uint8List(1 << 14);
      for (var i = 0; i < written.length; i++) {
        written[i] = (i * 17 + 3) & 0xFF;
      }
      var at = 0;
      while (at < written.length) {
        final block = min(512, written.length - at);
        final history = min(ring.windowSize, at);
        ring.ensure(history, block);
        ring.writeRaw(written, at, block);
        at += block;
      }
      // The last 4 KiB must still be readable through a match copy.
      final history = min(ring.windowSize, written.length);
      ring.ensure(history, 4096);
      final start = ring.position;
      ring.copyMatch(history, 4096);
      final actual = BytesBuilder(copy: false);
      ring.forEachSegment(start, 4096, actual.add);
      expect(
        actual.toBytes(),
        Uint8List.sublistView(
          written,
          written.length - history,
          written.length - history + 4096,
        ),
      );
    });
  });
}

/// Independent reference used by the ring/contiguous copy tests.
///
/// Applies the dictionary-aware LZ expansion in place to [buffer] starting at
/// [start]. Returns false when the offset is invalid.
bool _applyNaiveMatch(
  Uint8List buffer,
  int start,
  int available,
  int windowSize,
  Uint8List? dictionary,
  int offset,
  int length,
) {
  final dictLength = dictionary?.length ?? 0;
  var remaining = length;
  var position = start;
  if (available <= windowSize) {
    if (offset > available + dictLength) return false;
    if (offset > available) {
      final dictCopy = offset - available < remaining
          ? offset - available
          : remaining;
      final dictOffset = dictLength - (offset - available);
      buffer.setRange(position, position + dictCopy, dictionary!, dictOffset);
      position += dictCopy;
      remaining -= dictCopy;
    }
  } else if (offset > windowSize) {
    return false;
  }
  while (remaining > 0) {
    buffer[position] = buffer[position - offset];
    position++;
    remaining--;
  }
  return true;
}

int _referenceBackward(Uint8List data, int start, int bitPosition, int n) {
  final newPosition = bitPosition - n;
  if (newPosition >= 0) {
    return readBitsLe(data, start, newPosition, n);
  }
  if (bitPosition <= 0) return 0;
  return readBitsLe(data, start, 0, bitPosition) * kPow2[-newPosition];
}
