#!/usr/bin/env python3
"""Create a SwarmPanel source zip without secrets, runtime files, caches, or build deps."""
from __future__ import annotations

import fnmatch
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUT = ROOT.parent / "SwarmPanel-clean.zip"

EXCLUDE_DIRS = {
    ".git",
    ".venv",
    "venv",
    "node_modules",
    "__pycache__",
    ".pytest_cache",
    ".runtime",
    ".bin",
    ".aria_patch_backups",
}
EXCLUDE_PREFIXES = (
    "scripts.bak",
    "backups",
)
EXCLUDE_NAMES = {
    ".env",
    "env.zip",
    "live-config.json",
    "swarm_panel.log",
}
EXCLUDE_PATTERNS = (
    ".env.*",
    "*.pyc",
    "*.pyo",
    "*.log",
    "*.pid",
    "*.bak",
    "*.bak.*",
    "*.backup",
    "*.backup-*",
    "*.backup.*",
    "index.html.backup-*",
    "*.tmp",
)


def should_exclude(path: Path) -> bool:
    rel = path.relative_to(ROOT)
    parts = rel.parts
    if any(part in EXCLUDE_DIRS for part in parts):
        return True
    if any(parts and parts[0].startswith(prefix) for prefix in EXCLUDE_PREFIXES):
        return True
    name = path.name
    if name in EXCLUDE_NAMES:
        return True
    if name == ".env.example":
        return False
    return any(fnmatch.fnmatch(name, pattern) for pattern in EXCLUDE_PATTERNS)


def main() -> int:
    out = Path(sys.argv[1]).expanduser() if len(sys.argv) > 1 else DEFAULT_OUT
    if out.is_dir():
        out = out / "SwarmPanel-clean.zip"
    out.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for path in sorted(ROOT.rglob("*")):
            if path == out or should_exclude(path):
                continue
            if path.is_dir():
                continue
            arcname = Path("SwarmPanel") / path.relative_to(ROOT)
            zf.write(path, arcname.as_posix())
    print(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
