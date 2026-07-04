"""Account/email/webhook verification workflow helpers, shared by the
session, swarm-accounts, and image-gallery admin routers."""

import html
import json
import os
import re
import secrets
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlparse

import aiohttp
from fastapi import Request
from fastapi.responses import HTMLResponse

from .services import action_logger, settings
from .validators import _normalize_public_base_url, _validate_discord_webhook_url

BASE_DIR = Path(__file__).resolve().parent

_SAFE_HOST_RE = re.compile(r"^[A-Za-z0-9.\-:\[\]]+$")


def _external_base_url(request: Request) -> str:
    configured = _normalize_public_base_url(settings.pages_public_url)
    if configured:
        return configured

    forwarded_proto = str(request.headers.get("x-forwarded-proto") or "").split(",", 1)[0].strip().lower()
    forwarded_host = str(request.headers.get("x-forwarded-host") or "").split(",", 1)[0].strip()
    # Only trust forwarded headers that contain safe hostname characters to prevent
    # header-injection attacks producing malicious redirect or verification URLs.
    if forwarded_proto in {"http", "https"} and forwarded_host and _SAFE_HOST_RE.fullmatch(forwarded_host):
        root_path = str(request.scope.get("root_path") or "").rstrip("/")
        return f"{forwarded_proto}://{forwarded_host}{root_path}".rstrip("/")

    base = str(request.base_url).rstrip("/")
    if settings.session_https_only and base.startswith("http://"):
        return "https://" + base[len("http://"):]
    return base


def _verification_url(request: Request, token: str) -> str:
    return f"{_external_base_url(request)}/api/session/verify-email?token={quote(token, safe='')}"


def _image_gallery_verification_url(request: Request, token: str) -> str:
    origin = os.getenv("IMAGE_GALLERY_PUBLIC_BACKEND_URL", "").strip().rstrip("/")
    if not origin:
        config_path = BASE_DIR.parents[1] / "Image Gallery" / "live-config.json"
        try:
            payload = json.loads(config_path.read_text(encoding="utf-8"))
            raw_origin = str(payload.get("gallery_url") or "").strip().rstrip("/")
            # Only accept http/https URLs from config to prevent injection
            parsed_origin = urlparse(raw_origin)
            if parsed_origin.scheme in {"http", "https"} and parsed_origin.netloc:
                origin = raw_origin
        except Exception:
            origin = ""
    if origin:
        return f"{origin}/api/auth/verify-email?token={quote(token, safe='')}"
    return f"{_external_base_url(request)}/api/auth/verify-email?token={quote(token, safe='')}"


def _verification_code() -> str:
    return f"{secrets.randbelow(100_000_000):08d}"


def _verification_token() -> str:
    return secrets.token_urlsafe(32)


def _verification_material() -> tuple[str, str]:
    return _verification_token(), _verification_code()


def _verification_is_complete(account: dict[str, Any] | None) -> bool:
    if not account:
        return False
    return bool(
        account.get("verification_verified")
        or account.get("webhook_verified")
        or account.get("webhook_verified_at")
        or account.get("email_verified")
        or account.get("email_verified_at")
    )


async def _send_verification_webhook_code(
    webhook_url: str,
    code: str,
    *,
    username: str,
    guild_id: str | int,
) -> bool:
    normalized_url = _validate_discord_webhook_url(webhook_url)
    timeout = aiohttp.ClientTimeout(total=10)
    content = (
        f"SwarmPanel verification for `{username}` in guild `{guild_id}`\n"
        f"Code: **{code}**\n"
        "Enter this code in SwarmPanel to verify your account. "
        "If you did not request this, you can ignore this message."
    )
    payload = {
        "content": content[:1900],
        "allowed_mentions": {"parse": []},
        "username": "SwarmPanel Verify",
    }
    try:
        async with aiohttp.ClientSession(timeout=timeout) as session:
            async with session.post(normalized_url, json=payload) as response:
                if response.status >= 400:
                    body = (await response.text())[:300]
                    action_logger.warning("SwarmPanel webhook verification send failed status=%s body=%s", response.status, body)
                    return False
        return True
    except Exception:
        action_logger.exception("SwarmPanel webhook verification send failed for %s", username)
        return False


async def _verify_guild_registration_proof(guild_id: str | int, proof_url: Any) -> dict[str, str]:
    verified_guild_id = str(int(str(guild_id).strip()))
    normalized_url = _validate_discord_webhook_url(proof_url)
    parsed = urlparse(normalized_url)
    parts = [part for part in parsed.path.split("/") if part]
    webhook_id = parts[2]
    webhook_token = parts[3]
    lookup_url = f"https://discord.com/api/v10/webhooks/{quote(webhook_id, safe='')}/{quote(webhook_token, safe='')}"
    timeout = aiohttp.ClientTimeout(total=10)
    try:
        async with aiohttp.ClientSession(timeout=timeout) as session:
            async with session.get(lookup_url) as response:
                if response.status >= 400:
                    raise ValueError("The Discord webhook proof could not be verified. Create a new webhook in that server and try again.")
                payload = await response.json(content_type=None)
    except ValueError:
        raise
    except Exception as exc:
        raise ValueError("The Discord webhook proof could not be verified right now. Try again in a moment.") from exc

    resolved_guild_id = str(payload.get("guild_id") or "").strip()
    if resolved_guild_id != verified_guild_id:
        raise ValueError("The Discord webhook proof belongs to a different guild.")
    channel_id = str(payload.get("channel_id") or "").strip()
    if not channel_id:
        raise ValueError("The Discord webhook proof did not return a channel binding.")
    return {
        "guild_id": resolved_guild_id,
        "channel_id": channel_id,
        "webhook_name": str(payload.get("name") or "Webhook").strip()[:80],
    }


def _verification_page(title: str, message: str, *, ok: bool) -> HTMLResponse:
    color = "#89b4fa" if ok else "#ff6b6b"
    return HTMLResponse(
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
        f"<title>{html.escape(title)}</title>"
        "<style>body{margin:0;min-height:100vh;display:grid;place-items:center;"
        "font-family:Inter,system-ui,sans-serif;background:#10151f;color:#edf4ff}"
        "main{width:min(520px,calc(100vw - 32px));padding:28px;border:1px solid #273244;"
        "background:#151d2b;border-radius:8px}h1{margin:0 0 10px;font-size:1.5rem}"
        "p{color:#aab6c8;line-height:1.5}.badge{display:inline-block;margin-bottom:16px;"
        f"color:{color};font-weight:700}}a{{color:#7dd3fc}}</style></head><body><main>"
        f"<span class=\"badge\">{'Verified' if ok else 'Needs Attention'}</span>"
        f"<h1>{html.escape(title)}</h1><p>{html.escape(message)}</p>"
        f"<p><a href=\"{html.escape(settings.pages_public_url)}\">Return to SwarmPanel</a></p>"
        "</main></body></html>"
    )
