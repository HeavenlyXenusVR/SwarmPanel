"""Admin CRUD over registered SwarmPanel accounts (distinct from the
Image Gallery's own separate user table)."""

from typing import Any

from fastapi import APIRouter, HTTPException, Request

from ..auth_deps import _require_admin_auth
from ..schemas import (
    SwarmAccountBulkDeleteRequest,
    SwarmAccountBulkVerifyRequest,
    SwarmAccountDeleteRequest,
    SwarmAccountFlagRequest,
    SwarmAccountPasswordResetRequest,
    SwarmAccountUpdateRequest,
)
from ..security import _bounded_query_limit
from ..services import action_logger, db
from ..verification import (
    _send_verification_webhook_code,
    _verification_code,
    _verification_is_complete,
)

router = APIRouter()

MAX_BULK_IDS = 200


async def _run_bulk_op(ids: list[int], run_one) -> dict[str, Any]:
    """Loop the existing single-item db call over ``ids``, collecting a
    per-id success/failure summary instead of reimplementing the operation."""
    unique_ids = list(dict.fromkeys(int(item) for item in ids))[:MAX_BULK_IDS]
    succeeded: list[int] = []
    failed: list[dict[str, Any]] = []
    for item_id in unique_ids:
        try:
            await run_one(item_id)
            succeeded.append(item_id)
        except Exception as exc:
            failed.append({"id": item_id, "error": str(exc)[:240]})
    return {"succeeded": succeeded, "failed": failed}


@router.get("/api/swarm-accounts/admin")
async def api_swarm_accounts_admin(request: Request, query: str = "", limit: int = 100):
    _require_admin_auth(request)
    limit = _bounded_query_limit(limit, default=100)
    query = " ".join(str(query or "").split())[:120]
    try:
        return {"ok": True, "data": await db.get_account_admin_data(query=query, limit=limit)}
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        request_id = getattr(request.state, "request_id", "unknown")
        action_logger.exception("Failed to fetch SwarmPanel account admin data request_id=%s", request_id)
        raise HTTPException(
            status_code=503,
            detail=f"SwarmPanel account database unavailable. Reference: {request_id}",
        ) from exc


@router.post("/api/swarm-accounts/update")
async def api_swarm_accounts_update(request: Request, payload: SwarmAccountUpdateRequest):
    _require_admin_auth(request)
    updates = payload.model_dump(exclude={"account_id"}, exclude_unset=True)
    try:
        account = await db.update_account_admin(payload.account_id, updates)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    if not account:
        raise HTTPException(status_code=404, detail="SwarmPanel account not found")
    action_logger.warning("swarm_account_update account_id=%s fields=%s", payload.account_id, sorted(updates))
    return {"ok": True, "account": account}


@router.post("/api/swarm-accounts/email-verified")
async def api_swarm_accounts_email_verified(request: Request, payload: SwarmAccountFlagRequest):
    _require_admin_auth(request)
    account = await db.set_account_webhook_verified_admin(payload.account_id, payload.verified)
    if not account:
        raise HTTPException(status_code=404, detail="SwarmPanel account not found")
    action_logger.warning("swarm_account_verification_override account_id=%s verified=%s", payload.account_id, payload.verified)
    return {"ok": True, "account": account}


@router.post("/api/swarm-accounts/reset-password")
async def api_swarm_accounts_reset_password(request: Request, payload: SwarmAccountPasswordResetRequest):
    auth = _require_admin_auth(request)
    try:
        account = await db.reset_account_password_admin(payload.account_id, payload.new_password)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    if not account:
        raise HTTPException(status_code=404, detail="SwarmPanel account not found")
    action_logger.warning("swarm_account_reset_password account_id=%s", payload.account_id)
    await db.record_audit_log(auth.get("username"), "swarm_account_reset_password", target_type="account", target_id=payload.account_id)
    return {"ok": True, "account": account}


@router.post("/api/swarm-accounts/resend-verification")
async def api_swarm_accounts_resend_verification(request: Request, payload: SwarmAccountDeleteRequest):
    _require_admin_auth(request)
    account = await db.get_account_admin(payload.account_id)
    if not account:
        raise HTTPException(status_code=404, detail="SwarmPanel account not found")
    if not account.get("verification_webhook_url"):
        raise HTTPException(status_code=400, detail="This SwarmPanel account does not have a Discord verification webhook configured.")
    if _verification_is_complete(account):
        return {"ok": True, "verification_sent": False, "already_verified": True}
    verification_code = _verification_code()
    account = await db.issue_account_webhook_verification_code_by_id(payload.account_id, verification_code)
    verification_sent = bool(
        account and await _send_verification_webhook_code(
            account["verification_webhook_url"],
            verification_code,
            username=account["username"],
            guild_id=account["guild_id"],
        )
    )
    action_logger.warning("swarm_account_resend_verification account_id=%s sent=%s", payload.account_id, verification_sent)
    return {"ok": verification_sent, "verification_sent": verification_sent, "already_verified": False}


@router.post("/api/swarm-accounts/delete")
async def api_swarm_accounts_delete(request: Request, payload: SwarmAccountDeleteRequest):
    auth = _require_admin_auth(request)
    try:
        await db.delete_account_admin(payload.account_id)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    action_logger.warning("swarm_account_delete account_id=%s", payload.account_id)
    await db.record_audit_log(auth.get("username"), "swarm_account_delete", target_type="account", target_id=payload.account_id)
    return {"ok": True}


@router.post("/api/swarm-accounts/bulk-delete")
async def api_swarm_accounts_bulk_delete(request: Request, payload: SwarmAccountBulkDeleteRequest):
    auth = _require_admin_auth(request)
    result = await _run_bulk_op(payload.ids, db.delete_account_admin)
    action_logger.warning("swarm_account_bulk_delete ids=%s succeeded=%s failed=%s", payload.ids, len(result["succeeded"]), len(result["failed"]))
    await db.record_audit_log(
        auth.get("username"), "swarm_account_bulk_delete", target_type="account",
        details=f"succeeded_ids={result['succeeded']} failed={result['failed']}",
    )
    return {"ok": True, **result}


@router.post("/api/swarm-accounts/bulk-verify")
async def api_swarm_accounts_bulk_verify(request: Request, payload: SwarmAccountBulkVerifyRequest):
    auth = _require_admin_auth(request)

    async def _verify_one(account_id: int) -> None:
        account = await db.set_account_webhook_verified_admin(account_id, payload.verified)
        if not account:
            raise ValueError("Account not found")

    result = await _run_bulk_op(payload.ids, _verify_one)
    action_logger.warning("swarm_account_bulk_verify ids=%s verified=%s succeeded=%s failed=%s", payload.ids, payload.verified, len(result["succeeded"]), len(result["failed"]))
    await db.record_audit_log(
        auth.get("username"), "swarm_account_bulk_verify", target_type="account",
        details=f"verified={payload.verified} succeeded_ids={result['succeeded']} failed={result['failed']}",
    )
    return {"ok": True, **result}
