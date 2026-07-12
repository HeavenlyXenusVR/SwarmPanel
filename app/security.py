"""CORS/CSP/origin/security-header/rate-limit helpers shared by every route
and by main.py's global HTTP middleware."""

import re
import secrets
from datetime import datetime, timezone
from typing import Any
from urllib.parse import urlparse

from fastapi import HTTPException, Request, Response, WebSocket

from .auth import SESSION_AUTH_KEY, safe_session
from .services import action_logger, settings

APP_SHELL_PATHS = {
    "/",
    "/login",
    "/dashboard",
    "/controls",
    "/invites",
    "/users",
    "/friends",
    "/messages",
    "/profile",
    "/appearance",
    "/diagnostics",
    "/accounts",
    "/databases",
    "/gallery-admin",
    "/intel",
    "/audit-log",
}

PERSONAL_API_PREFIXES = (
    "/api/session",
    "/api/users",
    "/api/swarm-accounts",
    "/api/bots",
    "/api/dashboard",
    "/api/music-intelligence",
    "/api/database",
    "/api/databases",
    "/api/image-gallery",
    "/api/events",
    "/api/stability",
    "/api/system-diagnostics",
    "/api/telegram",
)

REQUEST_ID_RE = re.compile(r"[^A-Za-z0-9_.:-]+")

AUTH_RATE_BUCKETS: dict[str, list[float]] = {}
AUTH_RATE_BUCKETS_MAX = 2000  # prevent unbounded memory growth under load


def _client_ip(request: Request) -> str:
    forwarded = request.headers.get("x-forwarded-for", "").split(",")[0].strip()
    return forwarded or (request.client.host if request.client else "unknown")


def _rate_limit_auth(key: str, *, limit: int, window_seconds: int) -> None:
    now = datetime.now(timezone.utc).timestamp()
    bucket = [t for t in AUTH_RATE_BUCKETS.get(key, []) if now - t < window_seconds]
    if len(bucket) >= limit:
        raise HTTPException(status_code=429, detail="Too many authentication attempts. Try again later.")
    bucket.append(now)
    AUTH_RATE_BUCKETS[key] = bucket
    # Prune stale buckets to prevent unbounded memory growth under high load
    if len(AUTH_RATE_BUCKETS) > AUTH_RATE_BUCKETS_MAX:
        stale = [k for k, v in AUTH_RATE_BUCKETS.items() if all(now - t >= window_seconds for t in v)]
        for k in stale:
            AUTH_RATE_BUCKETS.pop(k, None)
        # If still over limit after pruning expired entries, drop oldest half
        if len(AUTH_RATE_BUCKETS) > AUTH_RATE_BUCKETS_MAX:
            overflow = sorted(AUTH_RATE_BUCKETS.items(), key=lambda item: max(item[1]) if item[1] else 0)
            for k, _ in overflow[: len(overflow) // 2]:
                AUTH_RATE_BUCKETS.pop(k, None)


def _bounded_query_limit(value: Any, *, default: int = 50, max_limit: int | None = None) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        parsed = default
    ceiling = max(1, int(max_limit or settings.api_max_rows))
    return max(1, min(parsed, ceiling))


def _request_id_for(request: Request) -> str:
    incoming = request.headers.get("x-request-id") or request.headers.get("x-correlation-id")
    cleaned = REQUEST_ID_RE.sub("", str(incoming or ""))[:80]
    return cleaned or secrets.token_hex(12)


def _safe_error_detail(prefix: str, exc: Exception) -> str:
    request_id = secrets.token_hex(6)
    action_logger.warning("%s request_id=%s error=%s", prefix, request_id, exc, exc_info=True)
    return f"{prefix}. Check SwarmPanel logs with request id {request_id}."


def _set_no_store_headers(response: Response) -> None:
    response.headers["Cache-Control"] = "no-store"
    response.headers["Pragma"] = "no-cache"
    response.headers["Expires"] = "0"


def _should_no_store(path: str) -> bool:
    return path in APP_SHELL_PATHS or any(path.startswith(prefix) for prefix in PERSONAL_API_PREFIXES)


def _normalize_origin(value: str | None) -> str:
    raw = str(value or "").strip()
    if not raw:
        return ""
    try:
        parsed = urlparse(raw)
    except Exception:
        return ""
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        return ""
    return f"{parsed.scheme}://{parsed.netloc}".rstrip("/")


def _allowed_browser_origins() -> set[str]:
    origins = {
        _normalize_origin(settings.pages_public_url),
        "http://127.0.0.1:8002",
        "http://localhost:8002",
        "http://127.0.0.1:8788",
        "http://localhost:8788",
    }
    origins.update(_normalize_origin(origin) for origin in settings.cors_allowed_origins)
    return {origin for origin in origins if origin}


def _trusted_hosts() -> list[str]:
    if settings.trusted_hosts:
        return list(dict.fromkeys(settings.trusted_hosts))
    hosts = {
        "localhost",
        "127.0.0.1",
        "host.docker.internal",
        "*.trycloudflare.com",
        "*.pinggy-free.link",
        "*.serveousercontent.com",
        "*.lhr.life",
        "*.ngrok-free.dev",
        "*.ngrok.io",
    }
    for origin in _allowed_browser_origins():
        try:
            parsed = urlparse(origin)
        except Exception:
            continue
        if parsed.hostname:
            hosts.add(parsed.hostname)
    return sorted(hosts)


def _request_origin(request: Request) -> str:
    origin = _normalize_origin(request.headers.get("origin"))
    if origin:
        return origin
    return _normalize_origin(request.headers.get("referer"))


def _has_bearer_auth(request: Request) -> bool:
    return str(request.headers.get("authorization") or "").strip().lower().startswith("bearer ")


def _has_session_cookie(request: Request) -> bool:
    return "session" in request.cookies or bool(safe_session(request).get(SESSION_AUTH_KEY))


def _ensure_allowed_browser_origin(request: Request) -> None:
    origin = _request_origin(request)
    if not origin:
        # Allow CLI/internal calls and bearer-token API calls without browser Origin/Referer.
        # Authenticated cookie requests must prove they came from the panel origin.
        if _has_session_cookie(request) and not _has_bearer_auth(request):
            raise HTTPException(status_code=403, detail="Missing trusted browser origin.")
        return
    current = _normalize_origin(str(request.base_url))
    if origin == current or origin in _allowed_browser_origins():
        return
    regex = settings.cors_allow_origin_regex
    if regex:
        try:
            if re.fullmatch(regex, origin):
                return
        except re.error:
            pass
    raise HTTPException(status_code=403, detail="Blocked cross-origin request.")


def _csp_connect_sources(request: Request) -> str:
    sources = ["'self'"]
    for origin in _allowed_browser_origins():
        if origin not in sources:
            sources.append(origin)
    current = _normalize_origin(str(request.base_url))
    if current and current not in sources:
        sources.append(current)
    return " ".join(sources)


def _ensure_allowed_websocket_origin(websocket: WebSocket) -> bool:
    origin = _normalize_origin(websocket.headers.get("origin"))
    if not origin:
        return True
    current = _normalize_origin(str(websocket.base_url))
    if origin == current or origin in _allowed_browser_origins():
        return True
    # Mirror the HTTP path's regex fallback (_ensure_allowed_browser_origin) — without
    # this, REST calls through a rotating Cloudflare/ngrok tunnel succeed (regex match)
    # while every /ws upgrade is rejected with 4403, looking like constant WS drops.
    regex = settings.cors_allow_origin_regex
    if regex:
        try:
            if re.fullmatch(regex, origin):
                return True
        except re.error:
            pass
    return False


def _security_headers(request: Request, response: Response) -> None:
    connect_sources = _csp_connect_sources(request)
    csp = "; ".join([
        "default-src 'self'",
        "base-uri 'self'",
        "object-src 'none'",
        "frame-ancestors 'none'",
        "form-action 'self'",
        "img-src 'self' data: blob: https:",
        "media-src 'self' blob: data: https:",
        "font-src 'self' data: https://fonts.gstatic.com",
        "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
        "script-src 'self'",
        f"connect-src {connect_sources}",
    ])
    response.headers.setdefault("Content-Security-Policy", csp)
    response.headers.setdefault("Referrer-Policy", "strict-origin-when-cross-origin")
    response.headers.setdefault("X-Frame-Options", "DENY")
    response.headers.setdefault("X-Content-Type-Options", "nosniff")
    response.headers.setdefault("X-Permitted-Cross-Domain-Policies", "none")
    response.headers.setdefault("Origin-Agent-Cluster", "?1")
    response.headers.setdefault(
        "Cross-Origin-Resource-Policy",
        "cross-origin" if request.url.path.startswith("/api/") else "same-origin",
    )
    response.headers.setdefault("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=(), usb=()")
    response.headers.setdefault("Cross-Origin-Opener-Policy", "same-origin")
    if getattr(request.state, "request_id", None):
        response.headers.setdefault("X-Request-ID", request.state.request_id)
    if request.url.scheme == "https":
        response.headers.setdefault("Strict-Transport-Security", "max-age=31536000; includeSubDomains")
    if request.url.path.startswith("/static/react/assets/"):
        response.headers.setdefault("Cache-Control", "public, max-age=31536000, immutable")
    elif request.url.path.startswith("/static/"):
        response.headers.setdefault("Cache-Control", "public, max-age=86400")
    if _should_no_store(request.url.path):
        _set_no_store_headers(response)


def _wants_json(request: Request) -> bool:
    accept = request.headers.get("accept", "")
    return "application/json" in accept and "text/html" not in accept
