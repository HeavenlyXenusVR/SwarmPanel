"""Saved queues/playlists: guild-scoped CRUD for named track lists that can
be replayed later via the existing /api/bots/control PLAY action."""

from fastapi import APIRouter, HTTPException, Request

from ..auth_deps import _require_api_auth, _require_guild_scope
from ..schemas import SavedQueueCreateRequest, SavedQueueDeleteRequest
from ..security import _safe_error_detail
from ..services import action_logger, db

router = APIRouter()


@router.get("/api/queues")
async def list_saved_queues(request: Request, guild_id: str, bot_key: str | None = None):
    auth = _require_api_auth(request)
    _require_guild_scope(auth, guild_id)
    try:
        queues = await db.list_saved_queues(guild_id, bot_key)
        return {"ok": True, "queues": queues}
    except Exception as exc:
        action_logger.error("Failed to list saved queues guild=%s: %s", guild_id, exc)
        raise HTTPException(status_code=503, detail=_safe_error_detail("Saved queues unavailable", exc))


@router.post("/api/queues")
async def create_saved_queue(request: Request, payload: SavedQueueCreateRequest):
    auth = _require_api_auth(request)
    _require_guild_scope(auth, payload.guild_id)
    try:
        queue = await db.create_saved_queue(
            payload.guild_id,
            payload.bot_key,
            payload.name,
            auth.get("username"),
            [item.model_dump() for item in payload.items],
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    action_logger.info("saved_queue_create guild=%s bot=%s name=%s", payload.guild_id, payload.bot_key, payload.name)
    await db.record_audit_log(
        auth.get("username"), "saved_queue_create", target_type="saved_queue", target_id=queue.get("id"),
        details=f"guild={payload.guild_id} bot={payload.bot_key} name={payload.name}",
    )
    return {"ok": True, "queue": queue}


@router.post("/api/queues/{queue_id}/delete")
async def delete_saved_queue(request: Request, queue_id: int, payload: SavedQueueDeleteRequest):
    auth = _require_api_auth(request)
    _require_guild_scope(auth, payload.guild_id)
    await db.delete_saved_queue(queue_id, payload.guild_id)
    action_logger.info("saved_queue_delete id=%s guild=%s", queue_id, payload.guild_id)
    await db.record_audit_log(auth.get("username"), "saved_queue_delete", target_type="saved_queue", target_id=queue_id)
    return {"ok": True}
