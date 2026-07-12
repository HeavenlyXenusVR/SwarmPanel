"""Page-serving HTML routes (React app shell) and favicon."""

from fastapi import APIRouter
from fastapi.responses import FileResponse

from ..paths import BASE_DIR, _app_shell_path

router = APIRouter()


@router.get("/")
@router.get("/dashboard")
@router.get("/controls")
@router.get("/invites")
@router.get("/users")
@router.get("/friends")
@router.get("/messages")
@router.get("/profile")
@router.get("/appearance")
@router.get("/diagnostics")
@router.get("/accounts")
@router.get("/databases")
@router.get("/gallery-admin")
@router.get("/lumisound-admin")
@router.get("/intel")
@router.get("/audit-log")
async def index() -> FileResponse:
    return FileResponse(_app_shell_path())


@router.get("/favicon.ico", include_in_schema=False)
async def favicon() -> FileResponse:
    return FileResponse(
        BASE_DIR / "static" / "favicon.ico",
        media_type="image/vnd.microsoft.icon",
        headers={"Cache-Control": "public, max-age=604800"},
    )
