"""Fleet stability/metrics snapshots and the combined live event feed."""

from typing import Any

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import JSONResponse

from datetime import datetime, timezone

from ..auth_deps import _require_admin_auth, _require_api_auth
from ..security import _bounded_query_limit, _safe_error_detail
from ..services import action_logger, db, push_feed_event, recent_feed_events

router = APIRouter()


@router.get("/api/stability")
async def stability_data(request: Request):
    _require_api_auth(request)
    try:
        return await db.get_stability_snapshot()
    except Exception as exc:
        action_logger.exception("Failed to build stability snapshot")
        raise HTTPException(status_code=500, detail=_safe_error_detail("Stability snapshot unavailable", exc))

@router.get("/api/metrics")
async def metrics_data(request: Request):
    _require_admin_auth(request)
    try:
        return await db.get_metrics_snapshot()
    except Exception as exc:
        await push_feed_event("error", "Metrics Snapshot Failed", str(exc), source="api")
        return JSONResponse(
            status_code=503,
            content={
                "generated_at": datetime.now(timezone.utc).isoformat(),
                "db_error": str(exc),
                "totals": {},
                "bots": [],
            },
        )


@router.get("/api/metrics/history")
async def metrics_history(request: Request, metric: str = "queued_tracks", hours: int = 24):
    _require_admin_auth(request)
    safe_hours = max(1, min(int(hours or 24), 24 * 30))
    try:
        return {"ok": True, "metric": metric, "hours": safe_hours, "points": await db.get_metrics_history(metric, safe_hours)}
    except Exception as exc:
        action_logger.error("Failed to fetch metrics history metric=%s: %s", metric, exc)
        raise HTTPException(status_code=503, detail=_safe_error_detail("Metrics history unavailable", exc))


@router.get("/api/events")
async def list_events(request: Request, limit: int = 50):
    _require_admin_auth(request)
    bounded_limit = _bounded_query_limit(limit, default=50, max_limit=100)
    events = list(recent_feed_events)
    try:
        bot_error_events = await db.get_recent_bot_error_events(limit=bounded_limit)
    except Exception:
        bot_error_events = []
    try:
        aria_medic_events = await db.get_recent_aria_medic_events(limit=max(5, bounded_limit // 2))
    except Exception:
        aria_medic_events = []

    combined = events + bot_error_events + aria_medic_events
    deduped: list[dict[str, Any]] = []
    seen: set[tuple[str, str, str, str, str]] = set()
    for event in sorted(combined, key=lambda item: item.get("timestamp") or ""):
        key = (
            str(event.get("timestamp") or ""),
            str(event.get("source") or ""),
            str(event.get("title") or ""),
            str(event.get("description") or ""),
            str(event.get("type") or "feed_event"),
        )
        if key in seen:
            continue
        seen.add(key)
        deduped.append(event)
    return {"events": deduped[-bounded_limit:]}
