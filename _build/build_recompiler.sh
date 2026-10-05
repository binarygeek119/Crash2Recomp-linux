#!/usr/bin/env sh
# Rebuild psxrecomp-game and the psxrecomp CLI from the patched tree.
#
# The prebuilt CLI (when one exists) was built from unpatched emitter sources.
# Overlay compilation needs the recompiler's codegen hash to match the runtime
# headers this port patches, so both binaries are produced from the same tree.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SRC=${SRC:-$ROOT/_build/Crash2Recomp/psxrecomp/recompiler}
if [ ! -f "$SRC/CMakeLists.txt" ]; then
  SRC=$ROOT/_build/psxrecomp-src/recompiler
fi
if [ ! -f "$SRC/CMakeLists.txt" ]; then
  echo "error: recompiler sources not found. Run _build/bootstrap_linux.sh first." >&2
  exit 1
fi

DIR=$ROOT/_build/build-recompiler
CLI_DIR=$ROOT/_build/build-cli
GENERATOR=""
if command -v ninja >/dev/null 2>&1; then
  GENERATOR="-G Ninja"
fi

build_target() {
  build_dir=$1
  chd=$2
  target=$3
  # shellcheck disable=SC2086
  cmake -S "$SRC" -B "$build_dir" $GENERATOR \
    -DCMAKE_BUILD_TYPE=Release \
    -DPSXRECOMP_ENABLE_CHD="$chd" \
    -DBUILD_TESTING=OFF
  cmake --build "$build_dir" --target "$target" --parallel
  exe=$(find "$build_dir" -type f -name "$target" | head -n 1)
  if [ -z "$exe" ]; then
    echo "error: $target was not produced in $build_dir" >&2
    exit 1
  fi
  echo "built: $exe"
}

build_target "$DIR" OFF psxrecomp-game
built=$(find "$DIR" -type f -name psxrecomp-game | head -n 1)
if [ -n "$built" ]; then
  echo "codegen hash: $($built --codegen-hash | head -n 1)"
fi
build_target "$CLI_DIR" ON psxrecomp
