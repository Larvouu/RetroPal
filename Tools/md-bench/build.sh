#!/bin/bash
# Build the md-bench host harness against the Mega Drive core exactly as the
# app ships it: Vendor/blastem-ios/build.sh in HOST mode (the same pinned
# source, the generated C interpreters, the stubs, the md_retro_* renaming and
# the one-object prelink), wrapped in a shared object md-bench can load.
#
# Usage: Tools/md-bench/build.sh <out-dir>
#   then: <out-dir>/md-bench bench <out-dir>/libmd-core-host.so <rom> [--play]
#   (modes and options at the top of md-bench.c)
#
# Environment:
#   MD_HOST_CC   the core's compiler (default cc; clang is the phone's family)
#
# Needs a C compiler, make, python3, binutils (ld, objcopy) and libdl.

set -euo pipefail

OUT="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CC_BIN="${MD_HOST_CC:-cc}"

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

HOST=1 MD_HOST_CC="$CC_BIN" "$ROOT/Vendor/blastem-ios/build.sh"
LIB="$ROOT/Vendor/blastem-ios/lib/libmd-core-host.a"

# The archive holds one prelinked object exporting only md_retro_*; a shared
# object of it is what the harness dlopens. --no-undefined proves the core is
# complete (the stubs included) on this machine's linker too.
"$CC_BIN" -shared -o "$OUT/libmd-core-host.so" \
    -Wl,--whole-archive "$LIB" -Wl,--no-whole-archive \
    -Wl,--no-undefined -lm -lpthread

"$CC_BIN" -O2 -Wall -I "$ROOT/Vendor/blastem" -o "$OUT/md-bench" "$HERE/md-bench.c" -ldl

echo "Built $OUT/md-bench and $OUT/libmd-core-host.so"
