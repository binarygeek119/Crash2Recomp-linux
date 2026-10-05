#!/usr/bin/env sh
# Build the generated project with the host clang/gcc toolchain.
#
# BUILDS BOTH TREES BY DEFAULT:
#   build-clang       PSX_DEBUG_TOOLS=OFF  - what the launcher runs
#   build-debugtools  PSX_DEBUG_TOOLS=ON   - TCP debug server
#
# Usage: sh _build/build_clang.sh [release|debugtools|both]

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROJECT=${PROJECT:-$ROOT/_build/Crash2Recomp}
ONLY=${1:-both}

if [ ! -f "$PROJECT/psxrecomp/runtime/runtime.cmake" ]; then
  echo "error: PSXRecomp runtime is missing: $PROJECT/psxrecomp/runtime/runtime.cmake" >&2
  echo "Run _build/bootstrap_linux.sh first, then generate the project from your disc." >&2
  exit 1
fi

if [ ! -d "$PROJECT/generated" ]; then
  echo "error: no generated C at $PROJECT/generated" >&2
  echo "Open the launcher, choose your disc on Setup, and press Build the game." >&2
  exit 1
fi

GENERATOR=""
if command -v ninja >/dev/null 2>&1; then
  GENERATOR="-G Ninja"
fi

build_tree() {
  dir=$1
  debug_tools=$2
  label=$3
  printf '\n=== CONFIGURE [%s]  (PSX_DEBUG_TOOLS=%s) ===\n\n' "$label" "$debug_tools"
  # shellcheck disable=SC2086
  cmake -S "$PROJECT" -B "$dir" $GENERATOR \
    -DCMAKE_BUILD_TYPE=Release \
    -DPSX_RECOMP_UI=OFF \
    -DPSX_DEBUG_TOOLS="$debug_tools"
  printf '\n=== BUILD [%s] ===\n\n' "$label"
  cmake --build "$dir" --config Release --parallel
  printf 'ARTIFACT [%s]:\n' "$label"
  find "$dir" -maxdepth 1 -type f \( -name '*Recompiled' -o -name 'psx-runtime' \) -printf '  %f  (%k KB)\n' || true
}

failed=0
if [ "$ONLY" = release ] || [ "$ONLY" = both ]; then
  if ! build_tree "$PROJECT/build-clang" OFF release; then
    failed=$?
  fi
fi
if [ "$ONLY" = debugtools ] || [ "$ONLY" = both ]; then
  if ! build_tree "$PROJECT/build-debugtools" ON debugtools; then
    failed=$?
  fi
fi

echo
echo "=== BUILD EXIT: $failed ==="
exit "$failed"
