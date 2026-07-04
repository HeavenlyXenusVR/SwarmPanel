"""Admin dashboard data for the Lumisound iOS companion app."""

from fastapi import APIRouter, HTTPException, Request

from ..auth_deps import _require_admin_auth
from ..security import _bounded_query_limit, _safe_error_detail
from ..services import action_logger, db

router = APIRouter()


@router.get("/api/lumisound/admin")
async def lumisound_admin(request: Request, limit: int = 50):
    _require_admin_auth(request)
    limit = _bounded_query_limit(limit, default=50)
    try:
        return {"ok": True, "data": await db.get_lumisound_admin_data(limit)}
    except Exception as exc:
        action_logger.error("Failed to fetch Lumisound admin data: %s", exc)
        raise HTTPException(status_code=503, detail=_safe_error_detail("Lumisound database unavailable", exc))
