"""Login/register/logout (both the HTML-form and JSON-API flavors) and the
rest of the /api/session/* account-session lifecycle."""

import re
from urllib.parse import quote

from fastapi import APIRouter, Form, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse

from ..auth import is_authenticated, issue_api_token
from ..auth_deps import (
    _account_guild_id,
    _authenticate_login,
    _get_api_auth,
    _hydrate_site_owner_auth,
    _is_admin_auth,
    _is_image_gallery_owner_auth,
    _is_moderator_auth,
    _is_site_owner_account,
    _is_site_owner_auth,
    _require_api_auth,
    _resolve_account_guild_id,
    _set_account_session,
    _set_admin_session,
    _sync_account_session_owner_state,
)
from ..paths import _app_shell_path
from ..schemas import (
    SessionAdminModeRequest,
    SessionEmailCodeRequest,
    SessionEmailUpdateRequest,
    SessionLoginRequest,
    SessionPasswordUpdateRequest,
    SessionRegisterRequest,
    SessionVerificationWebhookRequest,
)
from ..security import _client_ip, _rate_limit_auth, _wants_json
from ..services import action_logger, db, settings
from ..verification import (
    _send_verification_webhook_code,
    _verification_code,
    _verification_is_complete,
    _verification_page,
    _verify_guild_registration_proof,
)

router = APIRouter()


def _redirect_login() -> RedirectResponse:
    return RedirectResponse(url="/login", status_code=303)


async def _ensure_registerable_guild(guild_id: str | int) -> str:
    try:
        guild_id_text = str(int(str(guild_id).strip()))
    except (TypeError, ValueError):
        raise ValueError("Guild ID must be a Discord server ID number.") from None
    return guild_id_text


@router.get("/login")
async def login_page() -> FileResponse:
    return FileResponse(_app_shell_path())


@router.post("/login")
async def login_submit(
    request: Request,
    username: str = Form(...),
    password: str = Form(""),
    guild_id: str = Form(""),
):
    ip = _client_ip(request)
    _rate_limit_auth(
        f"login-form:{ip}:{str(username or '').strip().lower()[:80]}",
        limit=settings.login_form_rate_limit_per_15m,
        window_seconds=900,
    )
    auth = await _authenticate_login(username, password, guild_id)
    if auth:
        if auth["role"] == "admin":
            _set_admin_session(request, auth["username"])
        else:
            _set_account_session(
                request,
                auth["username"],
                auth["guild_id"],
                admin_mode=bool(auth.get("admin_mode")),
                site_owner=bool(auth.get("site_owner")),
                moderator=bool(auth.get("moderator")),
            )
        return RedirectResponse(url="/", status_code=303)
    return RedirectResponse(url="/login?error=invalid-login", status_code=303)


@router.post("/register")
async def register_submit(
    request: Request,
    username: str = Form(...),
    guild_id: str = Form(...),
    password: str = Form(...),
    email: str = Form(""),
    verification_webhook_url: str = Form(""),
    registration_proof_url: str = Form(""),
):
    ip = _client_ip(request)
    _rate_limit_auth(f"register-form:{ip}", limit=settings.register_form_rate_limit_per_hour, window_seconds=3600)
    verification_code = _verification_code()
    try:
        proof_url = verification_webhook_url or registration_proof_url
        registerable_guild_id = await _ensure_registerable_guild(guild_id)
        proof = await _verify_guild_registration_proof(registerable_guild_id, proof_url)
        account = await db.register_account_login(
            username,
            registerable_guild_id,
            password,
            email,
            verification_webhook_url=proof_url,
            verification_webhook_channel_id=proof.get("channel_id"),
            verification_webhook_name=proof.get("webhook_name"),
            webhook_verification_code=verification_code,
        )
    except ValueError as exc:
        return RedirectResponse(url=f"/login?mode=register&error={quote(str(exc)[:220])}", status_code=303)
    except Exception as exc:
        action_logger.warning("SwarmPanel registration failed for %s: %s", username, exc)
        return RedirectResponse(url="/login?mode=register&error=registration-failed", status_code=303)

    if proof_url:
        await _send_verification_webhook_code(
            proof_url,
            verification_code,
            username=account["username"],
            guild_id=account["guild_id"],
        )
    site_owner = _is_site_owner_account(account)
    _set_account_session(request, account["username"], account["guild_id"], admin_mode=site_owner, site_owner=site_owner)
    try:
        await db.touch_account_seen(account["username"], account["guild_id"], min_interval_seconds=0)
    except Exception:
        action_logger.debug("SwarmPanel account presence touch failed after form register.", exc_info=True)
    return RedirectResponse(url="/", status_code=303)


@router.post("/logout")
async def logout(request: Request):
    request.session.clear()
    return _redirect_login()


@router.get("/api/session")
async def api_session_status(request: Request):
    auth = await _hydrate_site_owner_auth(request, _get_api_auth(request))
    if not auth:
        return {"authenticated": False, "pages_public_url": settings.pages_public_url}

    username = auth.get("username") or settings.admin_username
    role = auth.get("role") or "admin"
    guild_id = auth.get("guild_id")
    site_owner = _is_site_owner_auth(auth)
    admin_mode = _is_admin_auth(auth)
    moderator = _is_moderator_auth(auth)
    account_guild_id = await _resolve_account_guild_id(auth, username)
    return {
        "authenticated": True,
        "mode": auth.get("mode") or "token",
        "username": username,
        "role": role,
        "guild_id": str(guild_id or account_guild_id) if (guild_id or account_guild_id) else None,
        "account_guild_id": account_guild_id,
        "site_owner": site_owner,
        "admin_mode": admin_mode,
        "moderator": moderator,
        "image_gallery_owner": _is_image_gallery_owner_auth(auth),
        "token": issue_api_token(
            settings.session_secret,
            username,
            role=role,
            guild_id=account_guild_id or guild_id,
            admin_mode=admin_mode,
            site_owner=site_owner,
            moderator=moderator,
        ),
        "pages_public_url": settings.pages_public_url,
        "expires_in": settings.api_token_ttl_seconds,
    }


@router.post("/api/session/login")
async def api_session_login(request: Request, payload: SessionLoginRequest):
    ip = _client_ip(request)
    _rate_limit_auth(f"login-api:{ip}:{str(payload.username or '').strip().lower()[:80]}", limit=15, window_seconds=900)
    try:
        auth = await _authenticate_login(payload.username, payload.password, payload.guild_id)
    except Exception as exc:
        action_logger.exception("API session login failed for %s", payload.username)
        return JSONResponse(
            {"detail": "Login backend error. Check SwarmPanel database/schema logs."},
            status_code=503,
        )
    if not auth:
        raise HTTPException(status_code=401, detail="Invalid username or password")

    if auth["role"] == "admin":
        _set_admin_session(request, auth["username"])
    else:
        _set_account_session(
            request,
            auth["username"],
            auth["guild_id"],
            admin_mode=bool(auth.get("admin_mode")),
            site_owner=bool(auth.get("site_owner")),
            moderator=bool(auth.get("moderator")),
        )
    linked_guild_id = auth.get("guild_id") or (await _resolve_account_guild_id(auth, auth["username"]) if auth["role"] == "admin" else None)
    site_owner = bool(auth.get("site_owner"))
    moderator = bool(auth.get("moderator"))
    token = issue_api_token(
        settings.session_secret,
        auth["username"],
        role=auth["role"],
        guild_id=linked_guild_id,
        admin_mode=_is_admin_auth(auth),
        site_owner=site_owner,
        moderator=moderator,
    )
    return {
        "ok": True,
        "token": token,
        "username": auth["username"],
        "role": auth["role"],
        "guild_id": linked_guild_id,
        "account_guild_id": linked_guild_id,
        "site_owner": site_owner,
        "admin_mode": _is_admin_auth(auth),
        "moderator": moderator,
        "image_gallery_owner": _is_image_gallery_owner_auth(auth),
        "pages_public_url": settings.pages_public_url,
        "expires_in": settings.api_token_ttl_seconds,
    }


@router.post("/api/session/register")
async def api_session_register(request: Request, payload: SessionRegisterRequest):
    ip = _client_ip(request)
    _rate_limit_auth(f"register-api:{ip}", limit=10, window_seconds=3600)
    verification_code = _verification_code()
    try:
        proof_url = payload.verification_webhook_url or payload.registration_proof_url
        registerable_guild_id = await _ensure_registerable_guild(payload.guild_id)
        proof = await _verify_guild_registration_proof(registerable_guild_id, proof_url)
        account = await db.register_account_login(
            payload.username,
            registerable_guild_id,
            payload.password,
            payload.email,
            verification_webhook_url=proof_url,
            verification_webhook_channel_id=proof.get("channel_id"),
            verification_webhook_name=proof.get("webhook_name"),
            webhook_verification_code=verification_code,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))

    verification_sent = bool(proof_url) and await _send_verification_webhook_code(
        proof_url,
        verification_code,
        username=account["username"],
        guild_id=account["guild_id"],
    )

    site_owner = _is_site_owner_account(account)
    _set_account_session(request, account["username"], account["guild_id"], admin_mode=site_owner, site_owner=site_owner)
    try:
        await db.touch_account_seen(account["username"], account["guild_id"], min_interval_seconds=0)
    except Exception:
        action_logger.debug("SwarmPanel account presence touch failed after register.", exc_info=True)
    token = issue_api_token(
        settings.session_secret,
        account["username"],
        role="account",
        guild_id=account["guild_id"],
        admin_mode=site_owner,
        site_owner=site_owner,
    )
    return {
        "ok": True,
        "token": token,
        "username": account["username"],
        "role": "account",
        "guild_id": account["guild_id"],
        "account_guild_id": account["guild_id"],
        "site_owner": site_owner,
        "admin_mode": site_owner,
        "image_gallery_owner": site_owner,
        "verification_sent": verification_sent,
        "pages_public_url": settings.pages_public_url,
        "expires_in": settings.api_token_ttl_seconds,
    }


@router.post("/api/session/admin-mode")
async def api_session_admin_mode(request: Request, payload: SessionAdminModeRequest):
    auth = await _hydrate_site_owner_auth(request, _require_api_auth(request))
    if not _is_site_owner_auth(auth):
        raise HTTPException(status_code=403, detail="Admin mode is locked to the verified owner account.")
    username = str(auth.get("username") or settings.admin_username)
    linked_guild_id = await _resolve_account_guild_id(auth, username)
    if not linked_guild_id:
        raise HTTPException(status_code=400, detail="This owner account is not linked to a registered guild.")
    admin_mode = bool(payload.enabled)
    if is_authenticated(request):
        _set_account_session(request, username, linked_guild_id, admin_mode=admin_mode, site_owner=True)

    next_auth = {
        "username": username,
        "role": auth.get("role") or ("account" if linked_guild_id else "admin"),
        "guild_id": linked_guild_id,
        "site_owner": True,
        "admin_mode": admin_mode,
    }
    return {
        "ok": True,
        "username": username,
        "role": next_auth["role"],
        "guild_id": linked_guild_id,
        "account_guild_id": linked_guild_id,
        "site_owner": True,
        "admin_mode": admin_mode,
        "image_gallery_owner": _is_image_gallery_owner_auth(next_auth),
        "token": issue_api_token(
            settings.session_secret,
            username,
            role=next_auth["role"],
            guild_id=linked_guild_id,
            admin_mode=admin_mode,
            site_owner=True,
        ),
        "pages_public_url": settings.pages_public_url,
        "expires_in": settings.api_token_ttl_seconds,
    }


@router.get("/api/session/verify-email", name="api_verify_session_email")
async def api_verify_session_email(request: Request, token: str):
    token = str(token or "").strip()[:200]
    if not token:
        raise HTTPException(status_code=400, detail="Missing verification token.")
    _rate_limit_auth(f"session-email-link:{_client_ip(request)}", limit=30, window_seconds=3600)
    account = await db.verify_account_email_by_token(token, settings.email_verification_ttl_seconds)
    if not account:
        if _wants_json(request):
            raise HTTPException(status_code=400, detail="Invalid or expired verification link.")
        return _verification_page("Verification Link Expired", "That SwarmPanel verification link is invalid or has already been used. Sign in and resend verification from your profile.", ok=False)
    if _wants_json(request):
        return {"ok": True, "account": account}
    return _verification_page("Email Verified", f"{account.get('username')} is now verified for SwarmPanel.", ok=True)


@router.post("/api/session/resend-verification")
async def api_resend_session_verification(request: Request):
    auth = await _hydrate_site_owner_auth(request, _require_api_auth(request))
    _rate_limit_auth(f"session-verification-resend:{str(auth.get('username') or '').lower()}", limit=8, window_seconds=3600)
    scoped_guild_id = _account_guild_id(auth)
    username = str(auth.get("username") or "")
    if not scoped_guild_id or not username:
        raise HTTPException(status_code=403, detail="Guild account access required")
    profile = await db.get_account_profile(username, scoped_guild_id)
    if not profile:
        raise HTTPException(status_code=404, detail="Account profile not found")
    if not profile.get("verification_webhook_url"):
        raise HTTPException(status_code=400, detail="Set a Discord verification webhook before requesting a code.")
    if _verification_is_complete(profile):
        return {"ok": True, "verification_sent": False, "already_verified": True}
    verification_code = _verification_code()
    profile = await db.issue_account_webhook_verification_code(username, scoped_guild_id, verification_code)
    verification_sent = bool(
        profile and await _send_verification_webhook_code(
            profile["verification_webhook_url"],
            verification_code,
            username=username,
            guild_id=scoped_guild_id,
        )
    )
    return {"ok": verification_sent, "verification_sent": verification_sent, "already_verified": False}


@router.post("/api/session/email")
async def api_update_session_email(request: Request, payload: SessionEmailUpdateRequest):
    auth = await _hydrate_site_owner_auth(request, _require_api_auth(request))
    _rate_limit_auth(f"session-email-update:{str(auth.get('username') or '').lower()}", limit=8, window_seconds=3600)
    scoped_guild_id = _account_guild_id(auth)
    username = str(auth.get("username") or "")
    if not scoped_guild_id or not username:
        raise HTTPException(status_code=403, detail="Guild account access required")
    try:
        profile = await db.update_account_email(username, scoped_guild_id, payload.email)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    _sync_account_session_owner_state(request, profile)
    return {"ok": True, "profile": profile}

@router.post("/api/session/verification-webhook")
async def api_update_session_verification_webhook(request: Request, payload: SessionVerificationWebhookRequest):
    auth = await _hydrate_site_owner_auth(request, _require_api_auth(request))
    _rate_limit_auth(f"session-verification-webhook:{str(auth.get('username') or '').lower()}", limit=8, window_seconds=3600)
    scoped_guild_id = _account_guild_id(auth)
    username = str(auth.get("username") or "")
    if not scoped_guild_id or not username:
        raise HTTPException(status_code=403, detail="Guild account access required")
    webhook_url = str(payload.verification_webhook_url or "").strip()
    profile = await db.get_account_profile(username, scoped_guild_id)
    if not profile:
        raise HTTPException(status_code=404, detail="Account profile not found")
    if not webhook_url:
        profile = await db.update_account_verification_webhook(username, scoped_guild_id, None, None, None)
        _sync_account_session_owner_state(request, profile)
        return {"ok": True, "profile": profile, "verification_sent": False}
    try:
        proof = await _verify_guild_registration_proof(scoped_guild_id, webhook_url)
        profile = await db.update_account_verification_webhook(
            username,
            scoped_guild_id,
            webhook_url,
            proof.get("channel_id"),
            proof.get("webhook_name"),
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    verification_code = _verification_code()
    profile = await db.issue_account_webhook_verification_code(username, scoped_guild_id, verification_code)
    verification_sent = bool(
        profile and await _send_verification_webhook_code(
            webhook_url,
            verification_code,
            username=username,
            guild_id=scoped_guild_id,
        )
    )
    _sync_account_session_owner_state(request, profile)
    return {"ok": True, "profile": profile, "verification_sent": verification_sent}


@router.post("/api/session/verification/verify")
@router.post("/api/session/email/verify")
async def api_verify_session_email_code(request: Request, payload: SessionEmailCodeRequest):
    auth = await _hydrate_site_owner_auth(request, _require_api_auth(request))
    _rate_limit_auth(f"session-verification-verify:{str(auth.get('username') or '').lower()}", limit=20, window_seconds=3600)
    scoped_guild_id = _account_guild_id(auth)
    username = str(auth.get("username") or "")
    if not scoped_guild_id or not username:
        raise HTTPException(status_code=403, detail="Guild account access required")
    code = re.sub(r"\D+", "", str(payload.code or ""))[:16]
    if not code:
        raise HTTPException(status_code=400, detail="Enter the verification code from your Discord webhook message.")
    profile = await db.verify_account_webhook_code(username, scoped_guild_id, code, settings.email_verification_ttl_seconds)
    if not profile:
        raise HTTPException(status_code=400, detail="Invalid verification code.")
    _sync_account_session_owner_state(request, profile)
    return {"ok": True, "profile": profile}


@router.post("/api/session/password")
async def api_update_session_password(request: Request, payload: SessionPasswordUpdateRequest):
    auth = await _hydrate_site_owner_auth(request, _require_api_auth(request))
    scoped_guild_id = _account_guild_id(auth)
    username = str(auth.get("username") or "")
    if not scoped_guild_id or not username:
        raise HTTPException(status_code=403, detail="Guild account access required")
    _rate_limit_auth(f"password-change:{username}", limit=3, window_seconds=600)
    try:
        profile = await db.update_account_password(username, scoped_guild_id, payload.current_password, payload.new_password)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    if not profile:
        raise HTTPException(status_code=404, detail="Account profile not found")
    return {"ok": True, "profile": profile}


@router.post("/api/session/logout")
async def api_session_logout(request: Request):
    request.session.clear()
    return {"ok": True}
