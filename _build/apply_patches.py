#!/usr/bin/env python3
"""Apply tuning/patches to the vendored psxrecomp tree.

The recorded patches mix three path styles:

* ``_build/Crash2Recomp/psxrecomp/<file>``
* ``_build/psxrecomp-src/<file>``
* git-style ``a/<file>`` / ``b/<file>`` relative to the psxrecomp root

This rewrites every hunk onto ``_build/psxrecomp-src`` (a clone, or a symlink
to ``_build/Crash2Recomp/psxrecomp``) and applies it in-process so we do not
need GNU patch.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SRC = ROOT / "_build" / "psxrecomp-src"
PATCH_DIR = ROOT / "tuning" / "patches"

HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
BACKUP_SUFFIXES = (".orig", ".sm", ".wh")
TREE_PREFIXES = (
    "_build/Crash2Recomp/psxrecomp/",
    "_build/psxrecomp-src/",
)


class ApplyError(RuntimeError):
    pass


def _strip_backup(path: str) -> str:
    for suffix in BACKUP_SUFFIXES:
        if path.endswith(suffix):
            return path[: -len(suffix)]
    return path


def normalize_path(path: str) -> str:
    path = path.strip().strip('"')
    if path == "/dev/null":
        return path
    if path.startswith("a/") or path.startswith("b/"):
        path = path[2:]
    for prefix in TREE_PREFIXES:
        if path.startswith(prefix):
            path = path[len(prefix):]
            break
    return _strip_backup(path)


def _parse_files(text: str) -> list[dict]:
    files: list[dict] = []
    current: dict | None = None
    hunk: dict | None = None
    for raw in text.splitlines(keepends=True):
        if raw.startswith("--- "):
            if current is not None:
                files.append(current)
            current = {
                "old": raw[4:].split("\t")[0].strip(),
                "new": None,
                "hunks": [],
            }
            hunk = None
            continue
        if current is None:
            continue
        if current["new"] is None and raw.startswith("+++ "):
            current["new"] = raw[4:].split("\t")[0].strip()
            continue
        match = HUNK_RE.match(raw)
        if match:
            hunk = {
                "old_start": int(match.group(1)),
                "lines": [],
            }
            current["hunks"].append(hunk)
            continue
        if hunk is not None:
            hunk["lines"].append(raw)
    if current is not None:
        files.append(current)
    return files


def _blocks(hunk_lines: list[str]) -> tuple[list[str], list[str]]:
    old: list[str] = []
    new: list[str] = []
    for raw in hunk_lines:
        if raw.startswith("\\"):
            continue
        body = raw[1:] if raw[:1] in " +-" else raw
        body = body.rstrip("\n\r")
        tag = raw[:1] if raw else " "
        if tag == "+":
            new.append(body)
        elif tag == "-":
            old.append(body)
        else:
            old.append(body)
            new.append(body)
    return old, new


def _change_span(hunk_lines: list[str]) -> tuple[int | None, int | None]:
    first = last = None
    for index, raw in enumerate(hunk_lines):
        if raw[:1] in "+-":
            if first is None:
                first = index
            last = index
    return first, last


def _block_variants(hunk_lines: list[str]) -> list[tuple[list[str], list[str]]]:
    """Full hunk, then with trailing (and if needed leading) context stripped.

    GNU patch fuzz: files drift after the edited lines more often than at the
    unique lines being changed. Dropping unmatched tail context is enough for
    most of this port's patches.
    """
    variants = [_blocks(hunk_lines)]
    first, last = _change_span(hunk_lines)
    if first is None or last is None:
        return variants
    trimmed = hunk_lines[: last + 1]
    if trimmed != hunk_lines:
        variants.append(_blocks(trimmed))
    # Keep a little leading context so a one-line insertion still anchors.
    lead = max(0, first - 3)
    core = hunk_lines[lead: last + 1]
    if core not in (hunk_lines, trimmed):
        variants.append(_blocks(core))
    return variants


def _find_block(lines: list[str], block: list[str], hint: int) -> int | None:
    if not block:
        return max(0, min(hint, len(lines)))
    start = max(0, hint)
    candidates = list(range(start, len(lines) - len(block) + 1))
    candidates += list(range(0, start))
    for index in candidates:
        if lines[index:index + len(block)] == block:
            return index
    return None


def _apply_hunks(lines: list[str], hunks: list[dict], label: str) -> tuple[list[str], str]:
    """Return (new_lines, status) where status is 'applied' or 'already'."""
    if not hunks:
        return lines, "already"

    already = True
    for hunk in hunks:
        variants = _block_variants(hunk["lines"])
        hint = max(0, hunk["old_start"] - 1)
        if any(_find_block(lines, new, hint) is not None for _, new in variants):
            if any(
                old and _find_block(lines, old, hint) is not None and old != new
                for old, new in variants
            ):
                already = False
                break
            continue
        already = False
        break
    if already:
        return lines, "already"

    out: list[str] = []
    pos = 0
    for hunk in hunks:
        hint = max(0, hunk["old_start"] - 1)
        found = None
        old: list[str] = []
        new: list[str] = []
        for old, new in _block_variants(hunk["lines"]):
            found = _find_block(lines, old, hint)
            if found is not None:
                break
        if found is None:
            if any(
                _find_block(lines, new, hint) is not None
                for _, new in _block_variants(hunk["lines"])
            ):
                continue
            raise ApplyError(
                f"{label}: hunk at {hunk['old_start']} did not match")
        if found < pos:
            # Overlapping hunk after a previous edit; search in the output.
            found_out = _find_block(out, old, found)
            if found_out is None:
                raise ApplyError(
                    f"{label}: hunk at {hunk['old_start']} overlapped")
            out[found_out:found_out + len(old)] = new
            continue
        out.extend(lines[pos:found])
        out.extend(new)
        pos = found + len(old)
    out.extend(lines[pos:])
    return out, "applied"


def _write_text(path: Path, lines: list[str], newline: str, had_newline: bool) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    body = newline.join(lines)
    if had_newline:
        body += newline
    path.write_text(body, encoding="utf-8")


def apply_patch(patch_path: Path, src: Path) -> str:
    text = patch_path.read_text(encoding="utf-8", errors="replace")
    files = _parse_files(text)
    if not files:
        raise ApplyError(f"{patch_path.name}: no unified diff")

    statuses: list[str] = []
    for info in files:
        new_rel = normalize_path(info["new"] or "")
        old_rel = normalize_path(info["old"])
        if not new_rel:
            raise ApplyError(f"{patch_path.name}: missing +++ path")

        creating = old_rel == "/dev/null"
        dest = src / new_rel
        if creating:
            _, new = _blocks([line for hunk in info["hunks"] for line in hunk["lines"]])
            if dest.is_file():
                existing = dest.read_text(encoding="utf-8", errors="replace").splitlines()
                if existing == new:
                    statuses.append("already")
                    continue
            _write_text(dest, new, "\n", True)
            statuses.append("applied")
            continue

        source = src / old_rel
        if not source.is_file():
            source = dest
        if not source.is_file():
            raise ApplyError(
                f"{patch_path.name}: missing {old_rel} (looked in {src})")

        original = source.read_bytes()
        newline = "\r\n" if b"\r\n" in original else "\n"
        text_in = original.decode("utf-8", errors="replace")
        had_newline = text_in.endswith("\n")
        lines = text_in.splitlines()
        updated, status = _apply_hunks(lines, info["hunks"], f"{patch_path.name}:{new_rel}")
        statuses.append(status)
        if status == "applied":
            _write_text(dest, updated, newline, had_newline)
    if all(s == "already" for s in statuses):
        return "already"
    return "applied"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--src", type=Path, default=DEFAULT_SRC,
        help="psxrecomp tree to patch (default: _build/psxrecomp-src)")
    parser.add_argument(
        "--continue-on-error", action="store_true",
        help="keep going after a failed patch and report all failures")
    args = parser.parse_args()
    src = args.src.resolve()
    if not (src / "runtime").is_dir():
        print(f"error: no psxrecomp runtime at {src}", file=sys.stderr)
        return 1

    patches = sorted(PATCH_DIR.glob("*.patch"))
    if not patches:
        print(f"error: no patches in {PATCH_DIR}", file=sys.stderr)
        return 1

    failed: list[str] = []
    applied = already = 0
    for patch in patches:
        try:
            status = apply_patch(patch, src)
        except ApplyError as exc:
            print(f"FAIL  {patch.name}: {exc}")
            failed.append(patch.name)
            if not args.continue_on_error:
                return 1
            continue
        if status == "already":
            print(f"skip  {patch.name} (already applied)")
            already += 1
        else:
            print(f"ok    {patch.name}")
            applied += 1

    print(f"\n{applied} applied, {already} already present, {len(failed)} failed")
    if failed:
        print("failed:", ", ".join(failed), file=sys.stderr)
        return 1
    stamp = src / ".crash2-patches-applied"
    stamp.write_text(
        "\n".join(p.name for p in patches) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
