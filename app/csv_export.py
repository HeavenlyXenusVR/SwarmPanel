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


def _safe_filename(name: str) -> str:
    cleaned = _UNSAFE_FILENAME_RE.sub("_", str(name or "export")).strip("_") or "export"
    return cleaned[:120]


def rows_to_csv_response(rows: list[dict[str, Any]], filename: str) -> StreamingResponse:
    buffer = io.StringIO()
    fieldnames: list[str] = []
    for row in rows:
        for key in row.keys():
            if key not in fieldnames:
                fieldnames.append(key)
    writer = csv.DictWriter(buffer, fieldnames=fieldnames, extrasaction="ignore")
    writer.writeheader()
    for row in rows:
        writer.writerow({key: ("" if value is None else str(value)) for key, value in row.items()})
    buffer.seek(0)
    safe_name = _safe_filename(filename)
    return StreamingResponse(
        iter([buffer.getvalue()]),
        media_type="text/csv",
        headers={"Content-Disposition": f'attachment; filename="{safe_name}.csv"'},
    )
