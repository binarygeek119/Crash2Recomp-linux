#!/usr/bin/env sh
# Fetch psxrecomp, apply this port's runtime patches, and build the Linux CLI.
#
# After this succeeds the launcher can translate a disc you own:
#   python3 launcher/main.py
#
# Environment:
#   PSXRECOMP_REPO  clone URL (default: RetroPortingToolKit/psxrecomp)
#   PSXRECOMP_REF   git ref to check out (default: 7edfe486, 2026-08-29)
#   BUILD_TYPE      Release (default) or Debug

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SRC=$ROOT/_build/psxrecomp-src
VENDORED=$ROOT/_build/Crash2Recomp/psxrecomp
CLI_STAGE=$ROOT/_build/psxrecomp-cli
CLI_BUILD=$ROOT/_build/build-cli
CLI_DIST=$ROOT/_build/cli-dist
RECOMPILER_STAGE=$ROOT/_build/build-recompiler
REPO=${PSXRECOMP_REPO:-https://github.com/RetroPortingToolKit/psxrecomp.git}
# Tree the earliest Crash 2 patches were recorded against (2026-08-29).
REF=${PSXRECOMP_REF:-7edfe486}
BUILD_TYPE=${BUILD_TYPE:-Release}

need_cmd() {
  if command -v "$1" >/dev/null 2>&1; then
    printf '  [ok]      %s\n' "$1"
  else
    printf '  [missing] %s\n' "$1"
    missing="$missing $1"
  fi
}

missing=""
printf '%s\n' '== Checking host tools =='
need_cmd cmake
need_cmd python3
need_cmd git
if command -v ninja >/dev/null 2>&1; then
  printf '%s\n' '  [ok]      ninja'
else
  printf '%s\n' '  [warn]    ninja not found; CMake will use its default generator'
fi
if command -v g++ >/dev/null 2>&1 || command -v clang++ >/dev/null 2>&1 || command -v c++ >/dev/null 2>&1; then
  printf '%s\n' '  [ok]      C++ compiler'
else
  printf '%s\n' '  [missing] C++ compiler'
  missing="$missing c++"
fi
if [ -n "$missing" ]; then
  cat <<EOF

Missing prerequisites:$missing

Fedora:
  sudo dnf install gcc gcc-c++ cmake ninja-build python3 git

Debian/Ubuntu:
  sudo apt install build-essential cmake ninja-build python3 git
EOF
  exit 1
fi

printf '\n%s\n' '== Fetching psxrecomp =='
mkdir -p "$ROOT/_build/Crash2Recomp"
if [ ! -f "$VENDORED/runtime/runtime.cmake" ] && [ ! -f "$SRC/runtime/runtime.cmake" ]; then
  git clone --recurse-submodules "$REPO" "$VENDORED"
fi
TREE=""
if [ -d "$VENDORED/.git" ] || [ -f "$VENDORED/.git" ]; then
  TREE=$VENDORED
elif [ -d "$SRC/.git" ] || [ -f "$SRC/.git" ]; then
  TREE=$SRC
fi
if [ -n "$TREE" ] && [ -n "$REF" ]; then
  printf '%s\n' "  checking out $REF"
  git -C "$TREE" fetch --recurse-submodules origin 2>/dev/null || true
  git -C "$TREE" checkout --force "$REF"
  git -C "$TREE" reset --hard "$REF"
  git -C "$TREE" clean -fd
  git -C "$TREE" submodule update --init --recursive
fi

if [ ! -e "$SRC" ]; then
  ln -sfn Crash2Recomp/psxrecomp "$SRC"
elif [ -d "$SRC" ] && [ ! -f "$SRC/runtime/runtime.cmake" ] && [ -f "$VENDORED/runtime/runtime.cmake" ]; then
  ln -sfn Crash2Recomp/psxrecomp "$SRC"
fi

# Prefer the real tree when both exist.
if [ -f "$VENDORED/runtime/runtime.cmake" ]; then
  PATCH_TREE=$VENDORED
elif [ -f "$SRC/runtime/runtime.cmake" ]; then
  PATCH_TREE=$SRC
else
  echo "error: psxrecomp runtime.cmake not found after clone" >&2
  exit 1
fi

printf '\n%s\n' "== Applying port patches to $PATCH_TREE =="
if ! python3 "$ROOT/_build/apply_patches.py" --src "$PATCH_TREE" --continue-on-error; then
  echo "warning: some patches did not apply; the CLI will still build." >&2
  echo "Crash 2 extras (native 60 FPS, pause menu, widescreen helpers) may be missing." >&2
fi

printf '\n%s\n' '== Building CLI / recompiler =='
python3 "$PATCH_TREE/tools/build_cli.py" release \
  --build-dir "$CLI_BUILD" \
  --dist-dir "$CLI_DIST"

STAGE=""
for cand in "$CLI_DIST"/psxrecomp-cli-linux-*; do
  if [ -d "$cand" ]; then
    STAGE=$cand
    break
  fi
done
if [ -z "$STAGE" ]; then
  echo "error: CLI package was not produced under $CLI_DIST" >&2
  exit 1
fi

rm -rf "$CLI_STAGE"
mv "$STAGE" "$CLI_STAGE"
mkdir -p "$RECOMPILER_STAGE"
if [ -f "$CLI_STAGE/libexec/psxrecomp-game" ]; then
  cp -f "$CLI_STAGE/libexec/psxrecomp-game" "$RECOMPILER_STAGE/psxrecomp-game"
fi

printf '\n%s\n' '== Bootstrap complete =='
printf '  CLI        : %s\n' "$CLI_STAGE/psxrecomp"
printf '  recompiler : %s\n' "$RECOMPILER_STAGE/psxrecomp-game"
printf '  BIOS       : %s\n' "$CLI_STAGE/framework/bios/openbios.bin"
cat <<EOF

Next:
  python3 launcher/main.py
  # Setup -> choose your SCUS-94154 disc -> Build the game

To compile an already-generated project later:
  sh $ROOT/_build/build_clang.sh
EOF
