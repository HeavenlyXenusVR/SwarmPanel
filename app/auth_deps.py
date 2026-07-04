"""Authentication, permission-check, session, and presence-tracking helpers
shared across every router domain. These are the pure auth-primitive pieces
of what was previously a much larger, entangled block in main.py — request
handling business logic that's specific to one domain (dashboard-snapshot
building, profile-update cleaning, social-permission checks) stays with its
router instead of living here."""

import asyncio
import base64
import os
from typing import Any

from fastapi import HTTPException, Request

from .auth import (
    SESSION_ADMIN_MODE_KEY,
    SESSION_AUTH_KEY,
    SESSION_GUILD_ID_KEY,
    SESSION_ROLE_KEY,
    SESSION_SITE_OWNER_KEY,
    SESSION_USERNAME_KEY,
    get_api_auth,
    is_authenticated,
    require_api_auth,
    verify_credentials,
)
from .services import action_logger, db, settings
from .verification import _verification_is_complete

OWNER_SCOPE_SENTINEL = "__site_owner_only__"
PRESENCE_TOUCH_INTERVAL_SECONDS = max(15, int(os.getenv("SWARM_PANEL_PRESENCE_TOUCH_INTERVAL_SECONDS", "30") or "30"))


def _get_api_auth(request: Request) -> dict[str, Any] | None:
    return get_api_auth(
        request,
        secret_key=settings.session_secret,
        max_age_seconds=settings.api_token_ttl_seconds,
    )


def _require_api_auth(request: Request) -> dict[str, Any]:
    return require_api_auth(
        request,
        secret_key=settings.session_secret,
        max_age_seconds=settings.api_token_ttl_seconds,
    )


def _is_site_owner_auth(auth: dict[str, Any] | None) -> bool:
    return bool(auth and auth.get("site_owner"))


def _is_admin_auth(auth: dict[str, Any] | None) -> bool:
    if not auth:
        return False
    if not _is_site_owner_auth(auth):
        return False
    if auth.get("admin_mode") is not None:
        return bool(auth.get("admin_mode"))
    return str(auth.get("role") or "admin").lower() == "admin" and not auth.get("guild_id")


def _normalize_owner_email(value: Any) -> str:
    return str(value or "").strip().lower()


def _is_site_owner_email(email: Any) -> bool:
    normalized = _normalize_owner_email(email)
    return bool(normalized and normalized == settings.site_owner_email)


def _owner_email_requires_verification() -> bool:
    return str(os.getenv("SWARM_PANEL_OWNER_EMAIL_REQUIRES_VERIFICATION", "1") or "").strip().lower() in {"1", "true", "yes", "on"}


def _is_site_owner_account(account: dict[str, Any] | None) -> bool:
    if not account:
        return False
    if not _is_site_owner_email(account.get("email")):
        return False
    if _owner_email_requires_verification():
        return _verification_is_complete(account)
    return True


def _is_image_gallery_owner_auth(auth: dict[str, Any] | None) -> bool:
    return _is_admin_auth(auth) and _is_site_owner_auth(auth)


def _scoped_guild_id(auth: dict[str, Any] | None) -> str | None:
    if auth and not _is_site_owner_auth(auth) and not auth.get("guild_id"):
        return OWNER_SCOPE_SENTINEL
    if _is_admin_auth(auth):
        return None
    guild_id = auth.get("guild_id") if auth else None
    return str(guild_id) if guild_id not in (None, "") else None


def _account_guild_id(auth: dict[str, Any] | None) -> str | None:
    guild_id = auth.get("guild_id") if auth else None
    return str(guild_id) if guild_id not in (None, "") else None


def _public_scoped_guild_id(auth: dict[str, Any] | None) -> str | None:
    scoped = _scoped_guild_id(auth)
    return None if scoped == OWNER_SCOPE_SENTINEL else scoped


async def _account_id_for_auth(auth: dict[str, Any]) -> int:
    username = str(auth.get("username") or "").strip()
    guild_id = _account_guild_id(auth)
    if not username or not guild_id:
        raise HTTPException(status_code=403, detail="Guild account access required")
    profile = await db.get_account_profile(username, guild_id)
    if not profile:
        raise HTTPException(status_code=404, detail="Account profile not found")
    return int(profile["id"])


def _client_id_from_token(token: str) -> str | None:
    token_head = str(token or "").split(".", 1)[0].strip()
    if not token_head:
        return None
    try:
        return base64.urlsafe_b64decode(token_head + ("=" * (-len(token_head) % 4))).decode().strip()
    except Exception:
        return None


def _require_admin_auth(request: Request) -> dict[str, Any]:
    auth = _require_api_auth(request)
    if not _is_admin_auth(auth):
        raise HTTPException(status_code=403, detail="Admin access required")
    return auth


def _require_image_gallery_owner_auth(request: Request) -> dict[str, Any]:
    auth = _require_api_auth(request)
    if not _is_image_gallery_owner_auth(auth):
        raise HTTPException(status_code=403, detail="Image Gallery owner access required")
    return auth


def _require_guild_scope(auth: dict[str, Any], guild_id: str | int | None) -> None:
    scoped = _scoped_guild_id(auth)
    if scoped and str(guild_id) != scoped:
        raise HTTPException(status_code=403, detail="This account can only control its registered guild")


def _set_admin_session(request: Request, username: str) -> None:
    request.session.clear()
    request.session[SESSION_AUTH_KEY] = True
    request.session[SESSION_USERNAME_KEY] = username
    request.session[SESSION_ROLE_KEY] = "admin"
    request.session[SESSION_SITE_OWNER_KEY] = True
    request.session[SESSION_ADMIN_MODE_KEY] = True
    request.session.pop(SESSION_GUILD_ID_KEY, None)


def _set_account_session(
    request: Request,
    username: str,
    guild_id: str | int,
    *,
    admin_mode: bool = False,
    site_owner: bool = False,
) -> None:
    request.session.clear()
    request.session[SESSION_AUTH_KEY] = True
    request.session[SESSION_USERNAME_KEY] = username
    request.session[SESSION_ROLE_KEY] = "account"
    request.session[SESSION_GUILD_ID_KEY] = str(guild_id)
    request.session[SESSION_SITE_OWNER_KEY] = bool(site_owner)
    request.session[SESSION_ADMIN_MODE_KEY] = bool(site_owner and admin_mode)


def _sync_account_session_owner_state(request: Request, profile: dict[str, Any] | None) -> None:
    if not is_authenticated(request) or not profile:
        return
    username = profile.get("username") or request.session.get(SESSION_USERNAME_KEY)
    guild_id = profile.get("guild_id") or request.session.get(SESSION_GUILD_ID_KEY)
    if not username or guild_id in (None, ""):
        return
    _set_account_session(
        request,
        str(username),
        str(guild_id),
        admin_mode=bool(request.session.get(SESSION_ADMIN_MODE_KEY)),
        site_owner=_is_site_owner_account(profile),
    )


async def _resolve_account_guild_id(auth: dict[str, Any] | None, username: str | None = None) -> str | None:
    linked_guild_id = _account_guild_id(auth)
    if linked_guild_id:
        return linked_guild_id
    lookup_username = str(username or (auth or {}).get("username") or "").strip()
    if not lookup_username:
        return None
    try:
        return await db.get_account_guild_id_for_username(lookup_username)
    except Exception as exc:
        action_logger.warning("Failed to resolve account guild for %s: %s", lookup_username, exc)
        return None


async def _hydrate_site_owner_auth(request: Request, auth: dict[str, Any] | None) -> dict[str, Any] | None:
    if not auth or auth.get("site_owner"):
        return auth
    username = str(auth.get("username") or "").strip()
    linked_guild_id = await _resolve_account_guild_id(auth, username)
    if not username or not linked_guild_id:
        return auth
    try:
        profile = await db.get_account_profile(username, linked_guild_id)
    except Exception as exc:
        action_logger.warning("Failed to hydrate owner auth for %s: %s", username, exc)
        return auth
    if not _is_site_owner_account(profile):
        return auth
    hydrated = {**auth, "guild_id": str(linked_guild_id), "site_owner": True}
    if is_authenticated(request):
        _set_account_session(
            request,
            username,
            linked_guild_id,
            admin_mode=bool(auth.get("admin_mode")),
            site_owner=True,
        )
    return hydrated


async def _authenticate_login(username: str, password: str = "", guild_id: str | int | None = None) -> dict[str, Any] | None:
    if verify_credentials(username, password, settings.admin_username, settings.admin_password):
        return {"username": username, "role": "admin", "guild_id": None, "site_owner": True, "admin_mode": True}

    account_secret = password if password not in (None, "") else guild_id
    if account_secret in (None, ""):
        return None
    try:
        account = await db.authenticate_account_login(username, str(account_secret))
    except ValueError:
        return None
    if not account:
        return None
    site_owner = _is_site_owner_account(account)
    return {
        "username": account["username"],
        "role": "account",
        "guild_id": account["guild_id"],
        "site_owner": site_owner,
        "admin_mode": site_owner,
    }


def _should_touch_presence(request: Request) -> bool:
    path = request.url.path
    if request.method.upper() not in {"GET", "HEAD", "POST", "PATCH", "PUT", "DELETE"}:
        return False
    if not path.startswith("/api/"):
        return False
    if path == "/api/session/logout":
        return False
    return True


async def _touch_request_presence(request: Request) -> None:
    if not _should_touch_presence(request):
        return
    auth = await _hydrate_site_owner_auth(request, _get_api_auth(request))
    if not auth:
        return
    username = str(auth.get("username") or "").strip()
    linked_guild_id = await _resolve_account_guild_id(auth, username)
    if not username or not linked_guild_id:
        return
    try:
        await db.touch_account_seen(
            username,
            linked_guild_id,
            min_interval_seconds=PRESENCE_TOUCH_INTERVAL_SECONDS,
        )
    except Exception:
        action_logger.debug(
            "SwarmPanel account presence refresh failed for %s on %s.",
            username,
            request.url.path,
            exc_info=True,
        )


def _background_task(task: asyncio.Task[Any], *, label: str) -> asyncio.Task[Any]:
    def _consume_result(done: asyncio.Task[Any]) -> None:
        try:
            done.result()
        except asyncio.CancelledError:
            return
        except Exception:
            action_logger.debug("Detached background task failed: %s", label, exc_info=True)

    task.add_done_callback(_consume_result)
    return task


def _schedule_presence_touch(request: Request) -> None:
    _background_task(asyncio.create_task(_touch_request_presence(request)), label="presence-touch")
