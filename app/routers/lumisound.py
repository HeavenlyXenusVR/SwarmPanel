"""Admin dashboard data and moderation actions for the Lumisound iOS
companion app: delete uploads, suspend/reinstate users, resolve bug
reports — mirrors the Image Gallery admin router's patterns."""

from fastapi import APIRouter, HTTPException, Request

from ..auth_deps import _require_admin_or_moderator_auth
from ..schemas import (
    LumisoundBugReportStatusRequest,
    LumisoundUploadDeleteRequest,
    LumisoundUserActiveRequest,
)
from ..security import _bounded_query_limit, _safe_error_detail
from ..services import action_logger, db

router = APIRouter()


@router.get("/api/lumisound/admin")
async def lumisound_admin(request: Request, limit: int = 50):
    _require_admin_or_moderator_auth(request)
    limit = _bounded_query_limit(limit, default=50)
    try:
        return {"ok": True, "data": await db.get_lumisound_admin_data(limit)}
    except Exception as exc:
        action_logger.error("Failed to fetch Lumisound admin data: %s", exc)
        raise HTTPException(status_code=503, detail=_safe_error_detail("Lumisound database unavailable", exc))


@router.post("/api/lumisound/uploads/delete")
async def lumisound_delete_upload(request: Request, payload: LumisoundUploadDeleteRequest):
    auth = _require_admin_or_moderator_auth(request)
    await db.delete_lumisound_upload(payload.upload_id)
    action_logger.warning("lumisound_delete_upload upload_id=%s", payload.upload_id)
    await db.record_audit_log(auth.get("username"), "lumisound_delete_upload", target_type="lumisound_upload", target_id=payload.upload_id)
    return {"ok": True}


@router.post("/api/lumisound/users/active")
async def lumisound_set_user_active(request: Request, payload: LumisoundUserActiveRequest):
    auth = _require_admin_or_moderator_auth(request)
    user = await db.set_lumisound_user_active(payload.user_id, payload.active)
    if not user:
        raise HTTPException(status_code=404, detail="Lumisound user not found")
    action_logger.warning("lumisound_set_user_active user_id=%s active=%s", payload.user_id, payload.active)
    await db.record_audit_log(
        auth.get("username"), "lumisound_user_active" if payload.active else "lumisound_user_suspend",
        target_type="lumisound_user", target_id=payload.user_id,
    )
    return {"ok": True, "user": user}


@router.post("/api/lumisound/bug-reports/status")
async def lumisound_update_bug_report_status(request: Request, payload: LumisoundBugReportStatusRequest):
    auth = _require_admin_or_moderator_auth(request)
    try:
        await db.update_lumisound_bug_report_status(payload.report_id, payload.status)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    action_logger.warning("lumisound_bug_report_status report_id=%s status=%s", payload.report_id, payload.status)
    await db.record_audit_log(auth.get("username"), "lumisound_bug_report_status", target_type="lumisound_bug_report", target_id=payload.report_id, details=payload.status)
    return {"ok": True}
