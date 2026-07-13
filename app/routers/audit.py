"""Admin audit log: read-only view over swarm_audit_log, backing the
panel's Audit Log admin page. Also hosts revert for the narrow set of
update-type actions that record a structured before/after snapshot."""

import json

from fastapi import APIRouter, HTTPException, Request

from ..auth_deps import _require_admin_auth, _require_admin_or_moderator_auth
from ..security import _bounded_query_limit, _safe_error_detail
from ..services import action_logger, db

router = APIRouter()

# Deliberately narrow: only update-type actions with a recorded before-state
# are safe to revert through the same update method used for normal edits.
# Deletes/bulk actions are not revertible here — reconstructing a deleted
# row (password hashes, etc.) is out of scope. Each entry's fields set must
# match its update method's own allowed-fields set (alerts.py/accounts.py)
# so a diff that also captured a derived column (e.g. email_verified_at
# resetting when email changes) doesn't get rejected on revert.
_ALERT_RULE_REVERT_FIELDS = {"rule_type", "threshold_minutes", "enabled"}
_SWARM_ACCOUNT_REVERT_FIELDS = {"username", "guild_id", "email", "display_name", "public_profile", "server_name"}


def _filtered(before: dict, fields: set[str]) -> dict:
    return {key: value for key, value in before.items() if key in fields}


REVERTIBLE_ACTIONS = {
    "alert_rule_update": lambda target_id, before: db.update_alert_rule(
        int(target_id), _filtered(before, _ALERT_RULE_REVERT_FIELDS),
    ),
    "swarm_account_update": lambda target_id, before: db.update_account_admin(
        int(target_id), _filtered(before, _SWARM_ACCOUNT_REVERT_FIELDS),
    ),
}


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


@router.post("/api/audit-log/{entry_id}/revert")
async def api_revert_audit_log_entry(request: Request, entry_id: int):
    auth = _require_admin_auth(request)
    entry = await db.get_audit_log_entry(entry_id)
    if not entry:
        raise HTTPException(status_code=404, detail="Audit log entry not found")
    action = str(entry.get("action") or "")
    revert_fn = REVERTIBLE_ACTIONS.get(action)
    if not revert_fn:
        raise HTTPException(status_code=400, detail=f"Action '{action}' cannot be reverted.")
    try:
        before = (json.loads(entry.get("details") or "{}") or {}).get("before")
    except (TypeError, ValueError):
        before = None
    if not before:
        raise HTTPException(status_code=400, detail="This entry has no recorded before-state to revert to.")
    target_id = entry.get("target_id")
    try:
        result = await revert_fn(target_id, before)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    if not result:
        raise HTTPException(status_code=404, detail="Revert target no longer exists.")
    action_logger.warning("audit_log_revert entry_id=%s action=%s target_id=%s", entry_id, action, target_id)
    await db.record_audit_log(
        auth.get("username"), f"{action}_revert", target_type=entry.get("target_type"), target_id=target_id,
        details=f"reverted_from_entry={entry_id}",
    )
    return {"ok": True, "result": result}
