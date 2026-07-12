"""Small shared helper for streaming admin table data out as CSV.
Used by the Databases generic table browser and the Image Gallery admin
media/user exports — kept as one leaf module rather than duplicated
per-router since both just need "list of dicts -> CSV download"."""

import csv
import io
import re
from typing import Any

from fastapi.responses import StreamingResponse

_UNSAFE_FILENAME_RE = re.compile(r"[^A-Za-z0-9_.-]+")
# Column-name substrings that must never leave this process in a CSV, regardless of
# which table/query produced the rows — this is the last line of defense for any
# caller (including the generic cross-schema Databases browser), not just the
# call sites that remember to filter columns themselves.
_SENSITIVE_COLUMN_MARKERS = ("password", "secret", "token", "api_key")
# Excel/Sheets treat a leading =, +, -, or @ as the start of a formula. Prefixing
# with an apostrophe forces those clients to render the value as plain text.
_FORMULA_LEAD_CHARS = ("=", "+", "-", "@")


def _safe_filename(name: str) -> str:
    cleaned = _UNSAFE_FILENAME_RE.sub("_", str(name or "export")).strip("_") or "export"
    return cleaned[:120]


def _is_sensitive_column(key: str) -> bool:
    lowered = str(key or "").lower()
    return any(marker in lowered for marker in _SENSITIVE_COLUMN_MARKERS)


def _csv_cell(value: Any) -> str:
    text = "" if value is None else str(value)
    if text and text[0] in _FORMULA_LEAD_CHARS:
        return f"'{text}"
    return text


def rows_to_csv_response(rows: list[dict[str, Any]], filename: str) -> StreamingResponse:
    buffer = io.StringIO()
    fieldnames: list[str] = []
    for row in rows:
        for key in row.keys():
            if key not in fieldnames and not _is_sensitive_column(key):
                fieldnames.append(key)
    writer = csv.DictWriter(buffer, fieldnames=fieldnames, extrasaction="ignore")
    writer.writeheader()
    for row in rows:
        writer.writerow({key: _csv_cell(value) for key, value in row.items() if not _is_sensitive_column(key)})
    buffer.seek(0)
    safe_name = _safe_filename(filename)
    return StreamingResponse(
        iter([buffer.getvalue()]),
        media_type="text/csv",
        headers={"Content-Disposition": f'attachment; filename="{safe_name}.csv"'},
    )
