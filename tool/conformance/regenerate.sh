#!/usr/bin/env bash
# Regenerate the zstd_neo conformance corpus with the official zstd
# `decodecorpus` generator (see https://github.com/facebook/zstd).
#
# Usage:
#   ZSTD_SRC=/path/to/zstd ./tool/conformance/regenerate.sh
#   ZSTD_SRC=/path/to/zstd OUT=/tmp/conformance ./tool/conformance/regenerate.sh
#
# ZSTD_SRC must point at a zstd source checkout (zstd 1.6.0 or newer) that
# contains tests/decodecorpus.c. Everything is built inside that checkout.
#
# Requirements: bash, make, a C compiler, and the Dart SDK (for the manifest
# builder). No Rust, no network access, no prebuilt binaries.
#
# Output (under OUT, default: test/conformance):
#   zst/<group>-<nnn>.zst   frames produced by decodecorpus
#   bin/<group>-<nnn>.bin   exact plaintext for each frame
#   frames.tsv              group/index/seed/size/options for every frame
#   skipped.tsv             generator outputs not committed (rejected or filtered)
#   manifest.json           provenance + per-frame metadata (sha256, sizes)
#
# Every frame is generated with `-n1 -s<seed>` so it can be reproduced on its
# own. Frames that the reference `zstd -t` rejects are dropped: decodecorpus
# with --block-type=2 can emit invalid blocks for zero-length content, and a
# conformance corpus must only contain frames that conform. The large group
# additionally filters by plaintext size (see generate_group).
set -euo pipefail

ZSTD_SRC=${ZSTD_SRC:-}
OUT=${OUT:-test/conformance}
JOBS=${JOBS:-4}
# Dart is only used for the dependency-free manifest builder.
DART_BIN=${DART_BIN:-dart}

if [[ -z $ZSTD_SRC || ! -f $ZSTD_SRC/tests/decodecorpus.c ]]; then
  echo "error: set ZSTD_SRC to a zstd source checkout containing tests/decodecorpus.c" >&2
  exit 2
fi

ZSTD_SRC=$(cd "$ZSTD_SRC" && pwd)
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if ! command -v "$DART_BIN" >/dev/null 2>&1 && [[ ! -x $DART_BIN ]]; then
  echo "error: $DART_BIN not found; set DART_BIN to a Dart SDK executable" >&2
  exit 2
fi

DC=$ZSTD_SRC/tests/decodecorpus
if [[ ! -x $DC ]]; then
  echo "building decodecorpus in $ZSTD_SRC/tests ..."
  make -C "$ZSTD_SRC/tests" decodecorpus -j"$JOBS"
fi

ZSTD_BIN=$ZSTD_SRC/programs/zstd
if [[ ! -x $ZSTD_BIN ]]; then
  echo "building zstd CLI in $ZSTD_SRC (used to validate generated frames) ..."
  make -C "$ZSTD_SRC" zstd -j"$JOBS"
fi

ZSTD_VERSION=$(awk '/^#define ZSTD_VERSION_MAJOR/{m=$3} /^#define ZSTD_VERSION_MINOR/{n=$3} /^#define ZSTD_VERSION_RELEASE/{r=$3} END{printf "%s.%s.%s", m, n, r}' "$ZSTD_SRC/lib/zstd.h")
ZSTD_VERSION_NUMBER=$(awk '/^#define ZSTD_VERSION_NUMBER/{print $3}' "$ZSTD_SRC/lib/zstd.h")

rm -rf "$OUT/zst" "$OUT/bin" "$OUT/frames.tsv" "$OUT/skipped.tsv" "$OUT/manifest.json"
mkdir -p "$OUT/zst" "$OUT/bin"
: > "$OUT/frames.tsv"
: > "$OUT/skipped.tsv"

# generate_group <group> <count> <base-seed> <min-bin-bytes> <options>...
# min-bin-bytes > 0 scans consecutive seeds and keeps only frames whose
# plaintext is at least that large (used to make the "large" group large).
generate_group() {
  local group=$1 count=$2 seed0=$3 minbin=$4
  shift 4
  local -a opts=("$@")
  local i=0 attempt=0 seed name tmp binSize
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT

  while (( i < count )); do
    if (( attempt > count * 20 + 64 )); then
      echo "error: too many rejected frames in group $group" >&2
      exit 1
    fi
    seed=$((seed0 + attempt))
    attempt=$((attempt + 1))

    rm -f "$tmp/z000000" "$tmp/z000000.zst"
    "$DC" -n1 -s"$seed" -p"$tmp" -o"$tmp" "${opts[@]}" >/dev/null 2>&1
    if [[ ! -f $tmp/z000000.zst ]]; then
      echo "error: decodecorpus produced no frame for group=$group seed=$seed" >&2
      exit 1
    fi

    name=$(printf '%s-%03d' "$group" "$i")
    mv "$tmp/z000000.zst" "$OUT/zst/$name.zst"
    mv "$tmp/z000000" "$OUT/bin/$name.bin"
    binSize=$(wc -c < "$OUT/bin/$name.bin")

    if (( minbin > 0 && binSize < minbin )); then
      printf '%s\t%d\t%s\n' "$group" "$seed" "plaintext ${binSize}B below min-bin-bytes=${minbin}" >> "$OUT/skipped.tsv"
      rm -f "$OUT/zst/$name.zst" "$OUT/bin/$name.bin"
      continue
    fi

    if ! "$ZSTD_BIN" -t -q "$OUT/zst/$name.zst" 2>/dev/null; then
      printf '%s\t%d\t%s\n' "$group" "$seed" "reference zstd -t rejected generator output" >> "$OUT/skipped.tsv"
      rm -f "$OUT/zst/$name.zst" "$OUT/bin/$name.bin"
      continue
    fi

    printf '%s\t%d\t%d\t%d\t%d\t%s\n' \
      "$group" "$i" "$seed" \
      "$(wc -c < "$OUT/zst/$name.zst")" \
      "$binSize" \
      "${opts[*]}" >> "$OUT/frames.tsv"
    i=$((i + 1))
  done
  rm -rf "$tmp"
  trap - EXIT
}

# Group counts were chosen to keep the committed corpus around 6 MB while
# covering every block type and both small and multi-block frames. The large
# group requires at least 250000 plaintext bytes per frame so it actually
# exercises long matches and many blocks.
generate_group default          100 20261020 0 --max-content-size-log=16
generate_group content-size      50 20262100 0 --content-size --max-content-size-log=16
generate_group block-128k        50 20262200 0 --max-block-size-log=17 --max-content-size-log=17
generate_group block-raw         25 20262300 0 --block-type=0 --max-content-size-log=16
generate_group block-rle         25 20262400 0 --content-size --block-type=1 --max-content-size-log=16
generate_group block-compressed  25 20262500 0 --block-type=2 --max-content-size-log=16
generate_group large              3 20262600 250000 --content-size --max-content-size-log=20

"$DART_BIN" "$SCRIPT_DIR/build_manifest.dart" "$OUT" \
  --zstd-version="$ZSTD_VERSION" \
  --zstd-version-number="$ZSTD_VERSION_NUMBER"

echo
echo "corpus written to $OUT"
sum_bytes() {
  find "$1" -type f -exec wc -c {} + | awk '$NF != "total" {s += $1} END {print s+0}'
}
awk -F'\t' '{n[$1]++; z[$1]+=$4; b[$1]+=$5} END {for (g in n) printf "  %-18s %3d frames  zst=%8d  bin=%8d\n", g, n[g], z[g], b[g]}' "$OUT/frames.tsv" | sort
printf '  %-18s %3d frames  zst=%8d  bin=%8d\n' TOTAL \
  "$(awk -F'\t' 'END{print NR}' "$OUT/frames.tsv")" \
  "$(sum_bytes "$OUT/zst")" \
  "$(sum_bytes "$OUT/bin")"
