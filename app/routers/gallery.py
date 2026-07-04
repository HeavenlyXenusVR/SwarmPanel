"""Image Gallery admin: user/comment/media/report management, table browsing."""

from fastapi import APIRouter, HTTPException, Request

from ..auth_deps import _require_image_gallery_owner_auth
from ..emailer import send_image_gallery_verification_email
from ..schemas import (
    GalleryCommentDeleteRequest,
    GalleryMediaDeleteRequest,
    GalleryMediaUpdateRequest,
    GalleryPasswordResetRequest,
    GalleryReportStatusRequest,
    GalleryUserDeleteRequest,
    GalleryUserFlagRequest,
    GalleryUserUpdateRequest,
)
from ..security import _bounded_query_limit, _safe_error_detail
from ..services import action_logger, db, settings
from ..verification import _image_gallery_verification_url, _verification_code

router = APIRouter()


@router.get("/api/image-gallery/admin")
async def image_gallery_admin(request: Request, limit: int = 50):
    _require_image_gallery_owner_auth(request)
    limit = _bounded_query_limit(limit, default=50)
    try:
        return {"ok": True, "data": await db.get_image_gallery_admin_data(limit)}
    except Exception as exc:
        action_logger.error("Failed to fetch image gallery admin data: %s", exc)
        raise HTTPException(status_code=503, detail=_safe_error_detail("Image Gallery database unavailable", exc))


@router.get("/api/image-gallery/tables")
async def image_gallery_tables(request: Request):
    _require_image_gallery_owner_auth(request)
    try:
        schema = settings.image_gallery_schema
        return {"ok": True, "schema": schema, "tables": await db.list_tables(schema)}
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        action_logger.error("Failed to fetch image gallery tables: %s", exc)
        raise HTTPException(status_code=503, detail=_safe_error_detail("Image Gallery database unavailable", exc))


@router.get("/api/image-gallery/table-data")
async def image_gallery_table_data(request: Request, table_name: str, limit: int = 100):
    _require_image_gallery_owner_auth(request)
    limit = _bounded_query_limit(limit, default=100)
    try:
        data = await db.get_table_data(settings.image_gallery_schema, table_name, limit)
        return {"ok": True, "data": data, "rows": data.get("rows", []), "count": data.get("count", 0)}
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        action_logger.error("Failed to fetch image gallery table data table=%s: %s", table_name, exc)
        raise HTTPException(status_code=503, detail=_safe_error_detail("Image Gallery database unavailable", exc))


@router.post("/api/image-gallery/users/delete")
async def image_gallery_delete_user(request: Request, payload: GalleryUserDeleteRequest):
    _require_image_gallery_owner_auth(request)
    await db.delete_image_gallery_user(payload.user_id)
    action_logger.warning("image_gallery_delete_user user_id=%s", payload.user_id)
    return {"ok": True}


@router.post("/api/image-gallery/comments/delete")
async def image_gallery_delete_comment(request: Request, payload: GalleryCommentDeleteRequest):
    _require_image_gallery_owner_auth(request)
    await db.delete_image_gallery_comment(payload.comment_id)
    action_logger.warning("image_gallery_delete_comment comment_id=%s", payload.comment_id)
    return {"ok": True}


@router.post("/api/image-gallery/users/reset-password")
async def image_gallery_reset_password(request: Request, payload: GalleryPasswordResetRequest):
    _require_image_gallery_owner_auth(request)
    try:
        await db.reset_image_gallery_user_password(payload.user_id, payload.new_password)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    action_logger.warning("image_gallery_reset_password user_id=%s", payload.user_id)
    return {"ok": True}


@router.post("/api/image-gallery/users/update")
async def image_gallery_update_user(request: Request, payload: GalleryUserUpdateRequest):
    _require_image_gallery_owner_auth(request)
    updates = payload.model_dump(exclude={"user_id"}, exclude_unset=True)
    try:
        user = await db.update_image_gallery_user(payload.user_id, updates)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    action_logger.warning("image_gallery_update_user user_id=%s fields=%s", payload.user_id, sorted(updates))
    return {"ok": True, "user": user}


@router.post("/api/image-gallery/users/email-verified")
async def image_gallery_set_email_verified(request: Request, payload: GalleryUserFlagRequest):
    _require_image_gallery_owner_auth(request)
    user = await db.set_image_gallery_email_verified(payload.user_id, payload.verified)
    action_logger.warning("image_gallery_email_verified user_id=%s verified=%s", payload.user_id, payload.verified)
    return {"ok": True, "user": user}


@router.post("/api/image-gallery/users/age-verified")
async def image_gallery_set_age_verified(request: Request, payload: GalleryUserFlagRequest):
    _require_image_gallery_owner_auth(request)
    user = await db.set_image_gallery_age_verified(payload.user_id, payload.verified)
    action_logger.warning("image_gallery_age_verified user_id=%s verified=%s", payload.user_id, payload.verified)
    return {"ok": True, "user": user}


@router.post("/api/image-gallery/users/resend-verification")
async def image_gallery_resend_verification(request: Request, payload: GalleryUserDeleteRequest):
    _require_image_gallery_owner_auth(request)
    user = await db.get_image_gallery_user_admin(payload.user_id)
    if not user:
        raise HTTPException(status_code=404, detail="Image Gallery user not found")
    if not user.get("email"):
        raise HTTPException(status_code=400, detail="This Image Gallery user does not have an email address.")
    if user.get("email_verified_at"):
        return {"ok": True, "email_verification_sent": False, "already_verified": True}
    email_token = _verification_code()
    user = await db.issue_image_gallery_email_verification_token(payload.user_id, email_token)
    verification_sent = bool(user and await send_image_gallery_verification_email(settings, user["email"], _image_gallery_verification_url(request, email_token), email_token))
    action_logger.warning("image_gallery_resend_verification user_id=%s sent=%s", payload.user_id, verification_sent)
    return {"ok": verification_sent, "email_verification_sent": verification_sent, "already_verified": False}


@router.post("/api/image-gallery/media/update")
async def image_gallery_update_media(request: Request, payload: GalleryMediaUpdateRequest):
    _require_image_gallery_owner_auth(request)
    updates = payload.model_dump(exclude={"media_id"}, exclude_unset=True)
    try:
        media = await db.update_image_gallery_media(payload.media_id, updates)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    action_logger.warning("image_gallery_update_media media_id=%s fields=%s", payload.media_id, sorted(updates))
    return {"ok": True, "media": media}


@router.post("/api/image-gallery/media/delete")
async def image_gallery_delete_media(request: Request, payload: GalleryMediaDeleteRequest):
    _require_image_gallery_owner_auth(request)
    await db.delete_image_gallery_media(payload.media_id)
    action_logger.warning("image_gallery_delete_media media_id=%s", payload.media_id)
    return {"ok": True}


@router.post("/api/image-gallery/reports/status")
async def image_gallery_update_report_status(request: Request, payload: GalleryReportStatusRequest):
    _require_image_gallery_owner_auth(request)
    try:
        await db.update_image_gallery_report_status(payload.report_id, payload.status)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    action_logger.warning("image_gallery_report_status report_id=%s status=%s", payload.report_id, payload.status)
    return {"ok": True}
