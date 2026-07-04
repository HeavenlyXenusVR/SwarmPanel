"""The /ws live dashboard feed: connection lifecycle, auth handshake, and the
periodic per-scope dashboard broadcast loop.

Self-contained on purpose — dashboard_broadcast_task's `global` and
active_connections are used exclusively within this bucket."""

import asyncio
import json
import os
from datetime import datetime, timezone
from typing import Any

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from ..auth import SESSION_ADMIN_MODE_KEY, SESSION_AUTH_KEY, SESSION_GUILD_ID_KEY, SESSION_ROLE_KEY, SESSION_SITE_OWNER_KEY, SESSION_USERNAME_KEY, verify_api_token
from ..dashboard import _build_dashboard_payload, _dashboard_scope_cache_key
from ..security import _ensure_allowed_websocket_origin
from ..services import action_logger, active_connections, settings

router = APIRouter()

dashboard_broadcast_task: asyncio.Task[Any] | None = None
WS_SEND_TIMEOUT_SECONDS = max(2.0, float(os.getenv("SWARM_WS_SEND_TIMEOUT_SECONDS", "6") or "6"))
WS_DASHBOARD_BUILD_TIMEOUT_SECONDS = max(5.0, float(os.getenv("SWARM_WS_DASHBOARD_BUILD_TIMEOUT_SECONDS", "25") or "25"))
WS_RECEIVE_TIMEOUT_SECONDS = max(20.0, float(os.getenv("SWARM_WS_RECEIVE_TIMEOUT_SECONDS", "45") or "45"))
WS_MAX_INBOUND_CHARS = max(16, int(os.getenv("SWARM_WS_MAX_INBOUND_CHARS", "512") or "512"))


def _remove_connection(connection: dict[str, Any]) -> None:
    try:
        active_connections.remove(connection)
    except ValueError:
        pass


@router.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    if not _ensure_allowed_websocket_origin(websocket):
        await websocket.close(code=4403)
        return

    # Try session auth first (cookie is sent with the upgrade request automatically).
    auth = None
    try:
        session = websocket.session
        if bool(session.get(SESSION_AUTH_KEY)):
            role = session.get(SESSION_ROLE_KEY) or "admin"
            guild_id = session.get(SESSION_GUILD_ID_KEY)
            admin_mode = session.get(SESSION_ADMIN_MODE_KEY)
            if admin_mode is None:
                admin_mode = str(role).lower() == "admin" and not guild_id
            auth = {
                "mode": "session",
                "username": session.get(SESSION_USERNAME_KEY),
                "role": role,
                "site_owner": bool(session.get(SESSION_SITE_OWNER_KEY)),
                "admin_mode": bool(admin_mode),
            }
            if guild_id:
                auth["guild_id"] = str(guild_id)
    except Exception:
        auth = None

    # Accept the connection so the client can send an auth frame (token auth path).
    # Reject before accept if origin check already failed (handled above).
    await websocket.accept()

    # If session auth didn't work, wait for an auth frame containing the API token.
    # This keeps the token out of server access logs (no longer in the URL query string).
    if not auth:
        try:
            raw = await asyncio.wait_for(websocket.receive_text(), timeout=10.0)
            msg = json.loads(raw)
            if msg.get("type") == "auth":
                token = str(msg.get("token") or "")
                auth = verify_api_token(token, settings.session_secret, settings.api_token_ttl_seconds)
        except WebSocketDisconnect:
            # Client gave up / navigated away before sending the auth frame — the
            # socket is already gone, so don't attempt to close it below (that
            # raises a RuntimeError in uvicorn for an already-closed connection).
            return
        except (asyncio.TimeoutError, json.JSONDecodeError, Exception):
            auth = None

    if not auth:
        try:
            await websocket.close(code=4401)
        except Exception:
            pass
        return

    connection = {"websocket": websocket, "auth": auth, "last_dashboard_digest": None}
    active_connections.append(connection)
    _ensure_dashboard_broadcast_loop()
    try:
        while True:
            try:
                message = await asyncio.wait_for(websocket.receive_text(), timeout=WS_RECEIVE_TIMEOUT_SECONDS)
            except asyncio.TimeoutError:
                # No message received within the window — send a ping to keep the
                # Cloudflare/proxy tunnel alive (idle timeout is ~100 s; we ping at 45 s).
                try:
                    await websocket.send_text(json.dumps({"type": "ping", "timestamp": datetime.now(timezone.utc).isoformat()}))
                except Exception:
                    break
                continue
            if len(str(message or "")) > WS_MAX_INBOUND_CHARS:
                await websocket.close(code=4409)
                break
            # Handle pong replies from the client — no action needed, receipt resets
            # the receive timeout so the connection stays classified as alive.
            try:
                msg = json.loads(message)
                if msg.get("type") == "pong":
                    continue
            except (json.JSONDecodeError, Exception):
                pass
    except WebSocketDisconnect:
        pass
    except Exception:
        pass
    finally:
        _remove_connection(connection)


def _json_default(obj: Any) -> Any:
    if isinstance(obj, datetime):
        return obj.isoformat()
    raise TypeError(f"Object of type {type(obj).__name__} is not JSON serializable")


def _ensure_dashboard_broadcast_loop() -> None:
    global dashboard_broadcast_task
    if dashboard_broadcast_task and not dashboard_broadcast_task.done():
        return
    dashboard_broadcast_task = asyncio.create_task(_dashboard_broadcast_loop())


async def _dashboard_broadcast_loop() -> None:
    global dashboard_broadcast_task
    interval_seconds = max(1.0, float(os.getenv("SWARM_WS_DASHBOARD_INTERVAL_SECONDS", "2") or "2"))
    try:
        while active_connections:
            payload_cache: dict[str, tuple[str, dict[str, Any], str]] = {}
            dead_connections: list[dict[str, Any]] = []
            for connection in list(active_connections):
                websocket = connection.get("websocket")
                auth = connection.get("auth") or {}
                scope_key = _dashboard_scope_cache_key(auth)
                if scope_key not in payload_cache:
                    try:
                        snapshot = await asyncio.wait_for(
                            _build_dashboard_payload(auth, enrich_discord=False),
                            timeout=WS_DASHBOARD_BUILD_TIMEOUT_SECONDS,
                        )
                        payload = {"type": "dashboard_snapshot", "data": snapshot}
                    except Exception as exc:
                        payload = {
                            "type": "dashboard_snapshot_error",
                            "error": str(exc),
                            "generated_at": datetime.now(timezone.utc).isoformat(),
                        }
                    # Use a single compact serialization for both the digest and the wire message.
                    # Using separate serializations caused false-positive "changed" detections.
                    serialized = json.dumps(payload, sort_keys=True, separators=(",", ":"), default=_json_default)
                    payload_cache[scope_key] = (serialized, payload, serialized)
                digest, _payload, serialized = payload_cache[scope_key]
                if connection.get("last_dashboard_digest") == digest:
                    continue
                try:
                    await asyncio.wait_for(websocket.send_text(serialized), timeout=WS_SEND_TIMEOUT_SECONDS)
                    connection["last_dashboard_digest"] = digest
                except Exception:
                    dead_connections.append(connection)
            for connection in dead_connections:
                _remove_connection(connection)
            await asyncio.sleep(interval_seconds)
    except asyncio.CancelledError:
        raise
    except Exception:
        action_logger.exception("Dashboard broadcast loop crashed; it will restart on the next websocket connection.")
    finally:
        dashboard_broadcast_task = None
