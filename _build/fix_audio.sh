#!/usr/bin/env sh
# Give the game real audio on Linux.
#
# WHY: SDL3 is compiled from source when the game is built. If the audio
# development headers are not installed at that moment, SDL3 compiles with
# only the "disk" and "dummy" audio drivers, and the game is silent. This
# installs the headers and rebuilds the game runtime.
#
# Fedora needs:     alsa-lib-devel pipewire-devel pulseaudio-libs-devel
# Debian/Ubuntu:   libasound2-dev libpipewire-0.3-dev libpulse-dev
#
# Run:  sh _build/fix_audio.sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROJ=$ROOT/_build/Crash2Recomp
BUILD=$PROJ/build-clang

echo "== 1/3  Installing audio development packages =="
if command -v dnf >/dev/null 2>&1; then
  sudo dnf install -y alsa-lib-devel pipewire-devel pulseaudio-libs-devel \
    libXext-devel libXcursor-devel libXrandr-devel libXi-devel \
    libXScrnSaver-devel libXtst-devel libXfixes-devel
elif command -v apt >/dev/null 2>&1; then
  sudo apt install -y libasound2-dev libpipewire-0.3-dev libpulse-dev \
    libxext-dev libxcursor-dev libxrandr-dev libxi-dev libxtst-dev libxss-dev libxfixes-dev
else
  echo "error: neither dnf nor apt found. Install the audio dev headers for" >&2
  echo "your distribution, then rerun this script's rebuild steps." >&2
  exit 1
fi

echo "== 2/3  Reconfiguring (SDL3 rebuilds with real audio drivers) =="
rm -rf "$BUILD"
cmake -S "$PROJ" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DPSX_RECOMP_UI=OFF -DPSX_DEBUG_TOOLS=OFF

echo "== 3/3  Building (~10 min) =="
cmake --build "$BUILD" --config Release --parallel

echo
echo "== Audio backends now linked into the game =="
ldd "$BUILD/Crash_Bandicoot_2_Recompiled" | grep -E "asound|pipewire|pulse" || \
  echo "warning: no audio library linked - the game may still be silent"

echo
echo "Done. Start the launcher and play."
