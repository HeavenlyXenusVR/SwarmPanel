"""Base filesystem paths shared by main.py (static mount, telegram recipient
store) and the pages router (React app shell lookup)."""

from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
REACT_SHELL_PATH = BASE_DIR / "static" / "react" / "index.html"


def _app_shell_path() -> Path:
    return REACT_SHELL_PATH if REACT_SHELL_PATH.exists() else BASE_DIR.parent / "index.html"
