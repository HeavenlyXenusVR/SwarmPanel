"""CRUD for configurable alert rules, evaluated periodically by the
Telegram health-watch loop (see app/telegram_bridge.py)."""

from fastapi import APIRouter, HTTPException, Request

from ..auth_deps import _require_admin_auth, _require_admin_or_moderator_auth
from ..db.audit import _diff_details
from ..schemas import AlertRuleCreateRequest, AlertRuleUpdateRequest
from ..security import _safe_error_detail
from ..services import action_logger, db

router = APIRouter()


@router.get("/api/alert-rules")
async def list_alert_rules(request: Request):
    _require_admin_or_moderator_auth(request)
    try:
        return {"ok": True, "rules": await db.list_alert_rules()}
    except Exception as exc:
        action_logger.error("Failed to list alert rules: %s", exc)
        raise HTTPException(status_code=503, detail=_safe_error_detail("Alert rules unavailable", exc))


@router.post("/api/alert-rules")
async def create_alert_rule(request: Request, payload: AlertRuleCreateRequest):
    auth = _require_admin_auth(request)
    try:
        rule = await db.create_alert_rule(
            payload.rule_type, payload.threshold_minutes, payload.enabled,
            escalation_minutes=payload.escalation_minutes, escalate_email=payload.escalate_email,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    action_logger.warning("alert_rule_create rule_type=%s threshold=%s", payload.rule_type, payload.threshold_minutes)
    await db.record_audit_log(auth.get("username"), "alert_rule_create", target_type="alert_rule", target_id=rule.get("id"))
    return {"ok": True, "rule": rule}


@router.post("/api/alert-rules/{rule_id}/update")
async def update_alert_rule(request: Request, rule_id: int, payload: AlertRuleUpdateRequest):
    auth = _require_admin_auth(request)
    updates = payload.model_dump(exclude_unset=True)
    before = await db.get_alert_rule(rule_id)
    try:
        rule = await db.update_alert_rule(rule_id, updates)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    if not rule:
        raise HTTPException(status_code=404, detail="Alert rule not found")
    action_logger.warning("alert_rule_update rule_id=%s fields=%s", rule_id, sorted(updates))
    details = _diff_details(before or {}, rule) if before else str(sorted(updates))
    await db.record_audit_log(auth.get("username"), "alert_rule_update", target_type="alert_rule", target_id=rule_id, details=details or None)
    return {"ok": True, "rule": rule}


@router.post("/api/alert-rules/{rule_id}/delete")
async def delete_alert_rule(request: Request, rule_id: int):
    auth = _require_admin_auth(request)
    await db.delete_alert_rule(rule_id)
    action_logger.warning("alert_rule_delete rule_id=%s", rule_id)
    await db.record_audit_log(auth.get("username"), "alert_rule_delete", target_type="alert_rule", target_id=rule_id)
    return {"ok": True}
