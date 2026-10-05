#!/usr/bin/env sh
# Stage a Linux player bundle and tar it.
#
# Ships the launcher and the recompiler. Does not ship a disc, the boot
# executable, generated game C, or the compiled game. Those are derived from
# copyrighted game data and are built on the player's machine.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=$(python3 -c 'import sys; sys.path.insert(0, "launcher"); from crash2launcher.version import VERSION; print(VERSION)')
NAME="Crash2Recomp-linux-x86_64-${VERSION}"
STAGE="$ROOT/dist/$NAME"
ARCHIVE="$ROOT/dist/${NAME}.tar.gz"
WIN_BUNDLE=${WIN_BUNDLE:-"$HOME/.local/share/Steam/steamapps/compatdata/2601953472/pfx/drive_c/CrashBandicoot2CortexStrikesBack-Crash2Recomp"}
PATCHED=${PATCHED_FRAMEWORK:-"$WIN_BUNDLE/game/psxrecomp"}
LAUNCHER="$ROOT/launcher/dist/Crash2Launcher"
CLI="$ROOT/_build/psxrecomp-cli"

if [ ! -x "$LAUNCHER/Crash2Launcher" ]; then
  echo "error: launcher bundle missing at $LAUNCHER" >&2
  echo "Build it with: python3 -m PyInstaller crash2launcher.spec --noconfirm" >&2
  exit 1
fi
if [ ! -x "$CLI/psxrecomp" ] || [ ! -x "$CLI/libexec/psxrecomp-game" ]; then
  echo "error: Linux CLI missing. Run sh _build/bootstrap_linux.sh first." >&2
  exit 1
fi
if [ ! -f "$PATCHED/runtime/runtime.cmake" ]; then
  echo "error: patched framework missing at $PATCHED" >&2
  exit 1
fi
if [ ! -f "$PATCHED/runtime/src/crash2_60fps.h" ]; then
  echo "error: $PATCHED is not the Crash 2 patched tree (no crash2_60fps.h)" >&2
  exit 1
fi

rm -rf "$STAGE"
mkdir -p "$STAGE/recompiler/libexec" "$STAGE/recompiler/tools" "$STAGE/data" "$STAGE/LICENSES"

echo "== launcher =="
cp -a "$LAUNCHER" "$STAGE/Crash2Launcher"

echo "== recompiler binaries =="
cp -a "$CLI/psxrecomp" "$STAGE/recompiler/psxrecomp"
cp -a "$CLI/libexec/." "$STAGE/recompiler/libexec/"
if [ -d "$CLI/share" ]; then
  cp -a "$CLI/share" "$STAGE/recompiler/share"
fi
if [ -f "$ROOT/_build/psxrecomp-upstream/psxrecomp_cli.py" ]; then
  cp -a "$ROOT/_build/psxrecomp-upstream/psxrecomp_cli.py" "$STAGE/recompiler/psxrecomp_cli.py"
fi
cp -a "$WIN_BUNDLE/recompiler/tools/compile_overlays.py" "$STAGE/recompiler/tools/"
if [ -f "$WIN_BUNDLE/recompiler/tools/overlay_xref.py" ]; then
  cp -a "$WIN_BUNDLE/recompiler/tools/overlay_xref.py" "$STAGE/recompiler/tools/"
fi

echo "== patched framework (no game data) =="
mkdir -p "$STAGE/recompiler/framework"
# OpenBIOS generated C is MIT and required to link the runtime. Game C is not.
tar -C "$PATCHED" \
  --exclude='.git' \
  --exclude='build' \
  --exclude='build-*' \
  --exclude='__pycache__' \
  --exclude='*.o' \
  --exclude='*.a' \
  --exclude='SCUS_*' \
  --exclude='*_full_*.c' \
  -cf - . | tar -C "$STAGE/recompiler/framework" -xf -

if [ -d "$WIN_BUNDLE/LICENSES" ]; then
  cp -a "$WIN_BUNDLE/LICENSES/." "$STAGE/LICENSES/"
fi

HASH=$("$STAGE/recompiler/libexec/psxrecomp-game" --codegen-hash 2>/dev/null | head -n 1 || true)
python3 - <<PY
import json
from datetime import datetime
from pathlib import Path
Path("$STAGE/bundle.json").write_text(json.dumps({
    "version": "$VERSION",
    "platform": "linux-x86_64",
    "built": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    "codegen_hash": "${HASH:-unknown}",
}, indent=2) + "\n")
Path("$STAGE/version.txt").write_text("$VERSION\n")
Path("$STAGE/data/PUT YOUR DISC HERE.txt").write_text(
    "Put the .cue and its .bin here, or anywhere else, and choose that file\\n"
    "in the launcher. This folder is only a reminder. Nothing here is the game.\\n"
)
PY

cat > "$STAGE/START_HERE.txt" <<EOF
Crash Bandicoot 2 Recompiled ${VERSION}  —  Linux x86_64

WORK IN PROGRESS. The game is playable from start to finish, with some minor
sound and graphical issues still to fix.

This package contains NO GAME DATA. You supply a disc image you already own
(.cue with its .bin, or a .chd, serial SCUS-94154), and the game is built on
this machine from it. The compiled game is not in this download.

Nothing to install beyond a C toolchain. The recompiler is included.


  1. Unpack this folder somewhere with a plain ASCII path.
  2. Run  ./Crash2Launcher/Crash2Launcher
  3. Setup -> choose your disc -> Build the game
  4. Play

The first build takes several minutes and only happens once. It needs about
3 GB of free space while it runs.


WHAT THIS MACHINE NEEDS

Fedora:
  sudo dnf install gcc gcc-c++ cmake ninja-build python3 \\
    mesa-libGL-devel libX11-devel libXext-devel libXcursor-devel \\
    libXrandr-devel libXi-devel libXScrnSaver-devel libXtst-devel alsa-lib-devel
    pipewire-devel pulseaudio-libs-devel \\
    wayland-devel libxkbcommon-devel

Debian / Ubuntu:
  sudo apt install build-essential cmake ninja-build python3 \\
    libgl1-mesa-dev libx11-dev libxext-dev libxcursor-dev libxrandr-dev \\
    libxi-dev libxtst-dev libasound2-dev libpipewire-0.3-dev libpulse-dev libwayland-dev libxkbcommon-dev

Sound needs the audio packages present BEFORE the game is built: SDL3 is
compiled during the build, and without them it gets no real audio driver and
the game is silent. pipewire-devel is the native Fedora one. If the game was
already built without them, delete the game/build folder and build again.
Direct3D 12 is Windows-only; this build uses OpenGL.


Licences are in LICENSES/. The recompiler and runtime are PolyForm
Noncommercial 1.0.0 — free to use and share, never to sell. OpenBIOS is MIT.
Qt/PySide6 is LGPL v3 and ships as replaceable files under Crash2Launcher/.

Unofficial fan project. Not affiliated with or endorsed by Activision, Naughty
Dog or Sony Interactive Entertainment.
EOF

echo "== audit =="
STAGE_PATH="$STAGE" python3 - <<'PY'
import os
import sys
from pathlib import Path
stage = Path(os.environ["STAGE_PATH"])
bad = []
for path in stage.rglob("*"):
    if not path.is_file():
        continue
    name = path.name
    rel = path.relative_to(stage).as_posix()
    low = name.lower()
    if low.endswith((".cue", ".chd", ".iso", ".mcd", ".mcr", ".sav")):
        bad.append(rel)
    if low.endswith(".bin") and name != "openbios.bin":
        bad.append(rel)
    if name.startswith(("SCUS_", "SCES_", "SLUS_", "SLES_")):
        bad.append(rel)
    if name.endswith("_Recompiled") or name.endswith("_Recompiled.exe"):
        bad.append(rel)
    if "/generated/" in f"/{rel}" and "OpenBIOS" not in name and name.endswith(".c"):
        bad.append(rel)
if bad:
    print("REFUSING package; copyrighted or game-derived files:")
    for item in bad:
        print(" ", item)
    sys.exit(1)
needed = [
    "bundle.json",
    "Crash2Launcher/Crash2Launcher",
    "Crash2Launcher/_internal/play-reference.png",
    "recompiler/psxrecomp",
    "recompiler/libexec/psxrecomp-game",
    "recompiler/framework/bios/openbios.bin",
    "recompiler/framework/runtime/runtime.cmake",
    "recompiler/framework/runtime/src/crash2_60fps.h",
    "recompiler/tools/compile_overlays.py",
]
missing = [item for item in needed if not (stage / item).exists()]
if missing:
    print("REFUSING package; missing:")
    for item in missing:
        print(" ", item)
    sys.exit(1)
print("audit ok")
PY

echo "== archive =="
tar -C "$ROOT/dist" -czf "$ARCHIVE" "$NAME"
echo "staged : $STAGE"
echo "archive: $ARCHIVE"
ls -lh "$ARCHIVE"
"$STAGE/Crash2Launcher/Crash2Launcher" --paths
