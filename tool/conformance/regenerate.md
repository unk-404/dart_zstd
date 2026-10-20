# Regenerating the conformance corpus

`test/conformance/` is generated from the **official** zstd `decodecorpus`
tool. The committed frames, expected plaintext and `manifest.json` can be
rebuilt from any zstd source checkout (1.6.0 or newer) with a C toolchain.

No Rust, no network access, and no prebuilt binaries are required. The only
Dart usage is the dependency-free manifest builder
[`build_manifest.dart`](build_manifest.dart).

## Prerequisites

- A zstd source checkout containing `tests/decodecorpus.c`
  (<https://github.com/facebook/zstd>)
- `bash`, `make`, a C compiler (the script builds `decodecorpus` and the
  `zstd` CLI inside the checkout)
- Dart SDK (for `build_manifest.dart`; no package dependencies needed)

On Windows, run the script from WSL or Git Bash. `ZSTD_SRC` accepts a native
path in that environment, and the manifest builder can be run separately from
PowerShell/CMD if the Dart SDK is only installed on Windows (see below).

## Regenerate everything

```bash
cd /path/to/dart_zstd

ZSTD_SRC=/path/to/zstd \
  ./tool/conformance/regenerate.sh
```

Optional environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `ZSTD_SRC` | *(required)* | zstd source checkout |
| `OUT` | `test/conformance` | output directory (must contain no unrelated files; `zst/`, `bin/`, `frames.tsv`, `skipped.tsv`, `manifest.json` are replaced) |
| `JOBS` | `4` | parallelism for `make` |
| `DART_BIN` | `dart` | Dart executable used for the manifest builder |

The script:

1. builds `decodecorpus` (`make -C "$ZSTD_SRC/tests" decodecorpus`) and the
   reference `zstd` CLI (`make -C "$ZSTD_SRC" zstd`) if they are missing;
2. generates every frame with its own seed:
   `decodecorpus -n1 -s<seed> -p<tmp> -o<tmp> <options>`;
3. runs `zstd -t` on each frame and **drops** generator outputs that reference
   zstd rejects (see "Known generator quirk"), recording them in
   `skipped.tsv`;
4. applies the `large` group's plaintext-size filter (see below) and records
   filtered seeds in `skipped.tsv` as well;
5. writes `frames.tsv` (group, index, seed, sizes, options) and calls
   `build_manifest.dart`, which adds SHA-256 digests and writes
   `manifest.json`.

Expected output (zstd 1.6.0-dev, 2026-10-20):

```
  block-128k          50 frames  zst=  317144  bin=  840047
  block-compressed    25 frames  zst=  122886  bin=  295599
  block-raw           25 frames  zst=  213383  bin=  212725
  block-rle           25 frames  zst=    762  bin=  298861
  content-size        50 frames  zst=  172564  bin=  390117
  default            100 frames  zst=  441362  bin= 1005223
  large                3 frames  zst=  483598  bin= 1149597
  TOTAL              278 frames  zst= 1751699  bin= 4192169
```

## Exact groups, counts and seeds

The commands below are what `regenerate.sh` executes; each group runs one
`decodecorpus` process per frame with a consecutive seed.

| Group | Frames | Base seed | Options |
|---|---|---|---|
| `default` | 100 | 20261020 | `--max-content-size-log=16` |
| `content-size` | 50 | 20262100 | `--content-size --max-content-size-log=16` |
| `block-128k` | 50 | 20262200 | `--max-block-size-log=17 --max-content-size-log=17` |
| `block-raw` | 25 | 20262300 | `--block-type=0 --max-content-size-log=16` |
| `block-rle` | 25 | 20262400 | `--content-size --block-type=1 --max-content-size-log=16` |
| `block-compressed` | 25 | 20262500 | `--block-type=2 --max-content-size-log=16` |
| `large` | 3 | 20262600 | `--content-size --max-content-size-log=20`, plaintext >= 250000 bytes |

Because rejected frames are skipped and the loop advances the seed, the
committed `block-compressed` frames use seeds 20262501-20262526 (not
20262500-20262524). The `large` group scans seeds from 20262600 and keeps only
frames with at least 250,000 plaintext bytes; the committed seeds are
20262600, 20262615 and 20262617. `manifest.json` is authoritative for the
per-frame seed.

## Known generator quirk

`decodecorpus --block-type=2` forces a compressed block even when the frame
content size is zero. For zero-length content it emits blocks that the
reference decoder rejects with `Zstd Error (36): Src size is incorrect`.
Those outputs are not valid conformance vectors. The script detects them with
`zstd -t` and skips them; with the seeds above that is exactly
`block-compressed` seeds 20262500 and 20262507.

Do not "fix" such a frame by hand: either skip it, or change the seed, so the
corpus only contains frames the reference implementation accepts.

## Large-group size filter

`decodecorpus` draws content sizes from a log-uniform distribution, so most
`--max-content-size-log=20` seeds produce small frames. To make the `large`
group meaningful, `generate_group` accepts a `min-bin-bytes` argument and
keeps scanning seeds until it has the requested number of frames at or above
that size. Skipped candidates are recorded in `skipped.tsv` with their
measured plaintext size, and appear under `"skipped"` in `manifest.json`.

## Reproduce a single frame

From `manifest.json`:

```bash
decodecorpus -n1 -s<seed> -p<tmpdir> -o<tmpdir> <options>
# -> <tmpdir>/z000000.zst and <tmpdir>/z000000
mv <tmpdir>/z000000.zst test/conformance/zst/<group>-<nnn>.zst
mv <tmpdir>/z000000     test/conformance/bin/<group>-<nnn>.bin
```

Verify decoder compatibility with the reference implementation:

```bash
zstd -t test/conformance/zst/<group>-<nnn>.zst
```

## Running only the manifest builder

If Dart is not available inside the shell that ran the generation (for example
when using WSL with a Windows-only Dart SDK), run generation with the builder
stubbed and then build the manifest from Windows:

```bash
# in the shell that has the zstd checkout:
DART_BIN=/bin/true ZSTD_SRC=/path/to/zstd ./tool/conformance/regenerate.sh
```

```powershell
# from the repository root on Windows:
dart run tool\conformance\build_manifest.dart `
  C:\path\to\corpus `
  --zstd-version=1.6.0 --zstd-version-number=10600
```

The manifest builder only uses `dart:io`, `dart:convert` and `dart:typed_data`;
it implements SHA-256 locally so no package dependency is needed.

## Verifying the committed corpus

```bash
dart test test/conformance_test.dart
```

The test checks the manifest against the files (existence, sizes, per-group
counts), decodes all 278 frames with `ZstdDecoder(maxWindowSize: 1 << 30)`,
byte-compares them with `bin/`, and exercises malformed/edge-case frames.
