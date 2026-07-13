"""Read-only access to the scheduled admin CSV exports written by
app/main.py's _scheduled_export_loop (opt-in via PANEL_SCHEDULED_EXPORTS_ENABLED)."""

import re
from pathlib import Path

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import FileResponse

from ..auth_deps import _require_admin_auth
from ..services import settings

router = APIRouter()

_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_FILENAME_RE = re.compile(r"^[A-Za-z0-9_.-]+\.csv$")


def _exports_root() -> Path:
    return Path(settings.scheduled_exports_dir)


@router.get("/api/exports")
async def list_exports(request: Request):
    _require_admin_auth(request)
    root = _exports_root()
    if not root.is_dir():
        return {"ok": True, "enabled": settings.scheduled_exports_enabled, "snapshots": []}
    snapshots = []
    for entry in sorted(root.iterdir(), reverse=True):
        if not entry.is_dir() or not _DATE_RE.match(entry.name):
            continue
        files = [
            {"name": file.name, "size_bytes": file.stat().st_size}
            for file in sorted(entry.iterdir())
            if file.is_file() and _FILENAME_RE.match(file.name)
        ]
        if files:
            snapshots.append({"date": entry.name, "files": files})
    return {"ok": True, "enabled": settings.scheduled_exports_enabled, "snapshots": snapshots}


@router.get("/api/exports/{date}/{filename}")
async def download_export(request: Request, date: str, filename: str):
    _require_admin_auth(request)
    if not _DATE_RE.match(date) or not _FILENAME_RE.match(filename):
        raise HTTPException(status_code=400, detail="Invalid export path")
    root = _exports_root().resolve()
    target = (root / date / filename).resolve()
    if root not in target.parents or not target.is_file():
        raise HTTPException(status_code=404, detail="Export file not found")
    return FileResponse(target, media_type="text/csv", filename=f"{date}_{filename}")
