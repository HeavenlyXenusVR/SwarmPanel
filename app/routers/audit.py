"""Admin audit log: read-only view over swarm_audit_log, backing the
panel's Audit Log admin page."""

from fastapi import APIRouter, HTTPException, Request

from ..auth_deps import _require_admin_or_moderator_auth
from ..security import _bounded_query_limit, _safe_error_detail
from ..services import action_logger, db

router = APIRouter()


@router.get("/api/audit-log")
async def api_audit_log(request: Request, limit: int = 100, offset: int = 0, action: str = ""):
    _require_admin_or_moderator_auth(request)
    limit = _bounded_query_limit(limit, default=100, max_limit=500)
    offset = max(0, int(offset or 0))
    action_filter = str(action or "").strip()[:80] or None
    try:
        return {"ok": True, "data": await db.list_audit_log(limit=limit, offset=offset, action_filter=action_filter)}
    except Exception as exc:
        action_logger.error("Failed to fetch audit log: %s", exc)
        raise HTTPException(status_code=503, detail=_safe_error_detail("Audit log unavailable", exc))
