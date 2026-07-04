"""Liveness/readiness probes, the aggregate dashboard snapshot, deep
diagnostics, and Telegram bridge status."""

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import JSONResponse

from .. import services as _services_module
from ..auth_deps import _require_admin_auth, _require_api_auth
from ..dashboard import _build_dashboard_payload
from ..services import action_logger, db, diagnostics_service, settings

router = APIRouter()


@router.get("/healthz", include_in_schema=False)
async def public_healthz():
    """Lightweight unauthenticated liveness probe for container/load-balancer checks."""
    db_ok = await db.ping()
    if db_ok:
        return {"ok": True, "db": "ok"}
    return JSONResponse(status_code=503, content={"ok": False, "db": "unavailable"})


@router.get("/api/health")
async def api_health(request: Request):
    _require_api_auth(request)
    db_ok = await db.ping()
    return {
        "ok": db_ok,
        "db": "ok" if db_ok else "unavailable",
        "request_id": getattr(request.state, "request_id", ""),
        "api_max_rows": settings.api_max_rows,
        "bot_control_source_max_chars": settings.bot_control_source_max_chars,
    }


@router.get("/api/dashboard")
async def dashboard_data(request: Request):
    auth = _require_api_auth(request)
    return await _build_dashboard_payload(auth, enrich_discord=True)


@router.get("/api/system-diagnostics")
async def system_diagnostics(request: Request, force: bool = False):
    _require_admin_auth(request)
    try:
        return await diagnostics_service.get_snapshot(force=force)
    except Exception as exc:
        request_id = getattr(request.state, "request_id", "unknown")
        action_logger.exception("Failed collecting diagnostics request_id=%s", request_id)
        raise HTTPException(
            status_code=503,
            detail=f"Diagnostics unavailable. Reference: {request_id}",
        ) from exc


@router.get("/api/telegram/status")
async def telegram_status(request: Request):
    _require_admin_auth(request)
    status = _services_module.telegram_service.snapshot() if _services_module.telegram_service else {
        "enabled": bool(settings.telegram_bot_token),
        "running": False,
        "bot_username": "",
        "allowed_chat_count": len(settings.telegram_allowed_chat_ids),
        "allowed_username_count": len(settings.telegram_allowed_usernames),
        "last_error": "",
        "last_update_at": 0.0,
    }
    return {"telegram": status}
