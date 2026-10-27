#!/usr/bin/env bash
# Rewrite broken .egg-link / editable paths to be relative to the Hue install root.
# Usage: fix-egg-links.sh <hue_install_root>
set -euo pipefail

HUE_ROOT="$(cd "${1:?}" && pwd)"
PYTHON_VER="${PYTHON_VER:-python3.11}"

"${PYTHON_VER}" - "$HUE_ROOT" <<'PY'
import os, sys
from pathlib import Path

hue_root = Path(sys.argv[1]).resolve()
prefixes = (
    "/opt/hue/",
    "/opt/hue-install/",
    str(hue_root) + "/",
)

def to_hue_abs(raw: str, link_file: Path) -> Path:
    raw = raw.strip()
    if not raw:
        return Path(raw)
    if raw.startswith("/"):
        abs_path = Path(raw)
    else:
        abs_path = (link_file.parent / raw).resolve()
    text = str(abs_path)
    for prefix in ("/opt/hue/", "/opt/hue-install/"):
        if text == prefix.rstrip("/") or text.startswith(prefix):
            rel = text[len(prefix):] if text.startswith(prefix) else ""
            return (hue_root / rel).resolve()
    # Relative path that still embeds opt/hue
    if "/opt/hue/" in text:
        return (hue_root / text.split("/opt/hue/", 1)[1]).resolve()
    return abs_path

changed = 0
for link in hue_root.glob("build/env/**/*.egg-link"):
    lines = link.read_text().splitlines()
    if not lines:
        continue
    target = to_hue_abs(lines[0], link)
    try:
        new_first = os.path.relpath(target, start=link.parent)
    except ValueError:
        continue
    if new_first != lines[0].strip():
        lines[0] = new_first
        link.write_text("\n".join(lines) + "\n")
        print(f"fixed egg-link {link} -> {new_first}")
        changed += 1

for pth in hue_root.glob("build/env/**/*.pth"):
    original = pth.read_text()
    lines = original.splitlines()
    out = []
    dirty = False
    for line in lines:
        s = line.strip()
        if not s or s.startswith("#") or s.startswith("import "):
            out.append(line)
            continue
        if "/opt/hue" in s:
            target = to_hue_abs(s, pth)
            try:
                new = os.path.relpath(target, start=pth.parent)
            except ValueError:
                out.append(line)
                continue
            out.append(new)
            if new != s:
                dirty = True
                print(f"fixed pth {pth}: {s} -> {new}")
        else:
            out.append(line)
    if dirty:
        pth.write_text("\n".join(out) + ("\n" if original.endswith("\n") else ""))
        changed += 1

print(f"fix-egg-links: {changed} files updated")
PY
