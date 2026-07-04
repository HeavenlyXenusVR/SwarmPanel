"""SQL identifier validation — its own leaf module (not a PanelDatabase method)
because diagnostics.py imports it directly, and it previously had to reach
into database.py's private internals to do so."""

import re

IDENTIFIER_RE = re.compile(r"^[A-Za-z0-9_]+$")


def _validate_identifier(value: str, field_name: str) -> str:
    value = (value or "").strip()
    if not IDENTIFIER_RE.fullmatch(value):
        raise ValueError(f"Invalid {field_name}: {value!r}")
    return value
