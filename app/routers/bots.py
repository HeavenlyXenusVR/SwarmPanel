"""Bot roster/invites, per-bot Discord inventory, live control-state
snapshots, music intelligence, and the bot control-action endpoint."""

import asyncio
import re
from datetime import datetime, timezone
from typing import Any

from fastapi import APIRouter, HTTPException, Request

from ..auth_deps import (
    _client_id_from_token,
    _is_admin_auth,
    _public_scoped_guild_id,
    _require_admin_auth,
    _require_api_auth,
    _require_guild_scope,
    _scoped_guild_id,
)
from ..bots import (
    ARIA_BOT,
    BOT_ACCENTS,
    BOT_CAPABILITY_SUMMARIES,
    BOT_INDEX,
    MUSIC_BOTS,
    invite_url_for_bot,
    permission_value,
    permissions_for_bot,
)
from ..dashboard import (
    DISCORD_IDENTITY_LOOKUP_TIMEOUT_SECONDS,
    _require_bot_guild_access,
    _visible_music_bots_for_auth,
)
from ..schemas import BotControlRequest
from ..security import _bounded_query_limit, _safe_error_detail
from ..services import action_logger, db, discord_service, push_feed_event, settings
from ..validators import _validate_discord_webhook_url

router = APIRouter()

VOICE_CHANNEL_TYPES = {2, 13}
TEXT_CHANNEL_TYPES = {0, 5}
VALID_ACTIONS = {"PAUSE", "RESUME", "SKIP", "STOP", "CLEAR", "SHUFFLE", "LOOP", "PLAY", "RESTART", "FILTER", "LEAVE", "SET_HOME", "RECOVER", "SMART_RECOMMEND", "SEEK"}
CONTROL_PAYLOAD_KEYS = {
    "source_url",
    "query",
    "voice_channel_id",
    "text_channel_id",
    "mode",
    "filter",
    "filter_mode",
    "loop_mode",
    "force",
    "vc_id",
    "webhook_url",
    "position_seconds",
}


def _coerce_control_int(value: Any, field_name: str) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        raise ValueError(f"Invalid {field_name}: {value!r}") from None


def _normalize_control_action(value: str) -> str:
    action = str(value or "").strip().upper()
    if action not in VALID_ACTIONS:
        raise ValueError(f"Unsupported action: {value}")
    return action


def _normalize_control_payload(value: Any) -> Any | None:
    if value is None or not isinstance(value, dict):
        return value
    unexpected = sorted(str(key) for key in value if str(key) not in CONTROL_PAYLOAD_KEYS)
    if unexpected:
        raise ValueError(f"Unsupported control payload field(s): {', '.join(unexpected)}")
    normalized = dict(value)
    for key, field_value in list(normalized.items()):
        if "webhook" in str(key).lower() and field_value:
            normalized[key] = _validate_discord_webhook_url(field_value)
    return normalized


def _normalize_control_source(value: Any) -> str:
    source = re.sub(r"\s+", " ", str(value or "").strip())
    if not source:
        raise ValueError("Missing source_url for PLAY action")
    if len(source) > settings.bot_control_source_max_chars:
        raise ValueError(f"PLAY source must be {settings.bot_control_source_max_chars} characters or fewer")
    return source


async def _normalize_bot_control_request(req: "BotControlRequest") -> tuple[str, str, Any | None]:
    action = _normalize_control_action(req.action)

    if action == "RESTART":
        return action, "0", _normalize_control_payload(req.payload)

    guild_id = _coerce_control_int(req.guild_id, "guild_id")
    normalized_payload = _normalize_control_payload(req.payload)

    if action not in {"PLAY", "SET_HOME", "SMART_RECOMMEND"}:
        return action, str(guild_id), normalized_payload

    bot = BOT_INDEX.get(req.bot_key)
    if not bot:
        raise ValueError("Unknown bot key")

    token = settings.bot_tokens.get(req.bot_key, "").strip()
    if not token:
        raise ValueError(f"Missing Discord token for {bot.display_name}; cannot validate the selected guild/channel route.")

    if not isinstance(normalized_payload, dict):
        expected = "source_url and voice_channel_id" if action == "PLAY" else "voice_channel_id"
        raise ValueError(f"{action} payload must be an object with {expected}")

    try:
        guild = await discord_service.fetch_guild(token, guild_id)
        channels = await discord_service.fetch_guild_channels(token, guild_id)
    except Exception as exc:
        raise ValueError(f"{bot.display_name} cannot validate guild {guild_id} via Discord: {exc}") from exc

    channel_map = {int(channel["id"]): channel for channel in channels}
    voice_channel_id = _coerce_control_int(normalized_payload.get("voice_channel_id"), "voice_channel_id")
    voice_channel = channel_map.get(voice_channel_id)
    if not voice_channel or int(voice_channel.get("type", -1)) not in VOICE_CHANNEL_TYPES:
        guild_name = guild.get("name") or f"Guild {guild_id}"
        raise ValueError(
            f"Voice channel {voice_channel_id} is not a voice/stage channel visible to {bot.display_name} in {guild_name}."
        )

    normalized_payload = dict(normalized_payload)
    normalized_payload["voice_channel_id"] = voice_channel_id

    if action == "SMART_RECOMMEND":
        text_channel_raw = normalized_payload.get("text_channel_id")
        text_channel_id = 0
        if text_channel_raw not in (None, "", 0, "0"):
            text_channel_id = _coerce_control_int(text_channel_raw, "text_channel_id")
            text_channel = channel_map.get(text_channel_id)
            if not text_channel or int(text_channel.get("type", -1)) not in TEXT_CHANNEL_TYPES:
                guild_name = guild.get("name") or f"Guild {guild_id}"
                raise ValueError(
                    f"Text channel {text_channel_id} is not a text/announcement channel visible to {bot.display_name} in {guild_name}."
                )
        normalized_payload = {
            "voice_channel_id": voice_channel_id,
            "text_channel_id": text_channel_id,
        }

    if action == "PLAY":
        source_url = _normalize_control_source(normalized_payload.get("source_url") or normalized_payload.get("query"))

        text_channel_raw = normalized_payload.get("text_channel_id")
        text_channel_id = 0
        if text_channel_raw not in (None, "", 0, "0"):
            text_channel_id = _coerce_control_int(text_channel_raw, "text_channel_id")
            text_channel = channel_map.get(text_channel_id)
            if not text_channel or int(text_channel.get("type", -1)) not in TEXT_CHANNEL_TYPES:
                guild_name = guild.get("name") or f"Guild {guild_id}"
                raise ValueError(
                    f"Text channel {text_channel_id} is not a text/announcement channel visible to {bot.display_name} in {guild_name}."
                )

        normalized_payload = {
            "source_url": source_url,
            "voice_channel_id": voice_channel_id,
            "text_channel_id": text_channel_id,
        }

    return action, str(guild_id), normalized_payload


@router.get("/api/bots")
async def list_bots(request: Request):
    auth = _require_api_auth(request)
    scoped_guild_id = _public_scoped_guild_id(auth)
    # The invite roster advertises every bot available to add to a server, so it
    # must not be filtered down to bots already registered in the user's guild.
    visible_bots = [*MUSIC_BOTS, ARIA_BOT]
    visible_keys = {bot.key for bot in await _visible_music_bots_for_auth(auth)}
    if _is_admin_auth(auth):
        visible_keys.add(ARIA_BOT.key)

    async def invite_payload(bot) -> dict[str, Any]:
        token = settings.bot_tokens.get(bot.key, "")
        client_id = _client_id_from_token(token)
        identity: dict[str, Any] = {}
        if token:
            try:
                identity = await asyncio.wait_for(
                    discord_service.fetch_identity(token),
                    timeout=DISCORD_IDENTITY_LOOKUP_TIMEOUT_SECONDS,
                )
                client_id = identity.get("id") or client_id
            except Exception as exc:
                identity = {"error": "Discord identity lookup timed out." if isinstance(exc, asyncio.TimeoutError) else str(exc)}
        permissions = permissions_for_bot(bot)
        permission_integer = permission_value(permissions)
        return {
            "key": bot.key,
            "display_name": bot.display_name,
            "name": bot.display_name,
            "kind": bot.kind,
            "schema": bot.db_schema,
            "token_configured": bool(token),
            "client_id": client_id,
            "invite_url": invite_url_for_bot(client_id, permission_integer, scoped_guild_id) if client_id else None,
            "permission_integer": str(permission_integer),
            "permissions": permissions,
            "capability_summary": BOT_CAPABILITY_SUMMARIES.get(bot.kind, "Discord bot with slash commands and server tools."),
            "accent": BOT_ACCENTS.get(bot.key, "#89b4fa"),
            "connected_to_session_guild": bool(scoped_guild_id and bot.key in visible_keys),
            "icon_url": identity.get("avatar_url"),
            "identity_name": identity.get("global_name") or identity.get("username"),
            "identity_error": identity.get("error"),
        }

    return {
        "bots": [
            {
                "key": bot.key,
                "display_name": bot.display_name,
                "name": bot.display_name,
                "kind": bot.kind,
                "schema": bot.db_schema,
                "token_configured": bool(settings.bot_tokens.get(bot.key)),
            }
            for bot in visible_bots
        ],
        # Build identity-backed invite cards concurrently so the panel does not
        # wait on nine Discord identity requests in series.
        "invite_bots": list(await asyncio.gather(*(invite_payload(bot) for bot in visible_bots))),
        "scoped_guild_id": scoped_guild_id,
    }


@router.get("/api/bots/{bot_key}/inventory")
async def bot_inventory(request: Request, bot_key: str, include_channels: bool = True):
    auth = _require_api_auth(request)
    bot = BOT_INDEX.get(bot_key)
    if not bot:
        raise HTTPException(status_code=404, detail="Unknown bot key")
    scoped_guild_id = _scoped_guild_id(auth)
    if scoped_guild_id:
        await _require_bot_guild_access(auth, bot_key, scoped_guild_id)

    token = settings.bot_tokens.get(bot_key, "")
    if not token:
        raise HTTPException(status_code=400, detail=f"Missing token env for {bot.display_name}")

    guild_hints = []
    if bot.kind == "music":
        try:
            guild_hints = await db.get_known_guild_ids(bot_key)
        except Exception:
            guild_hints = []
    inventory = await discord_service.fetch_inventory(
        token,
        include_channels=include_channels,
        guild_hints=[scoped_guild_id] if scoped_guild_id else guild_hints,
    )
    if scoped_guild_id:
        inventory["guilds"] = [
            guild for guild in inventory.get("guilds", [])
            if str(guild.get("id")) == scoped_guild_id
        ]
    return {
        "bot": {"key": bot.key, "display_name": bot.display_name, "kind": bot.kind},
        **inventory,
    }


def _control_state_error_payload(bot_key: str, display_name: str, guild_id: int, message: str) -> dict[str, Any]:
    return {
        "key": bot_key,
        "display_name": display_name,
        "guild_id": str(guild_id),
        "db": {
            "status": "error",
            "reachable": False,
            "message": message,
        },
        "discord": {
            "status": "unknown",
            "reachable": False,
            "message": "Discord state was not resolved because the live control query failed.",
            "token_configured": bool(settings.bot_tokens.get(bot_key)),
        },
        "session": {
            "guild_id": str(guild_id),
            "guild_name": None,
            "channel_id": None,
            "channel_name": None,
            "title": None,
            "video_url": None,
            "position_seconds": 0,
            "is_playing": False,
            "session_state": "idle",
            "session_state_label": "Idle",
            "volume": 100,
            "loop_mode": "queue",
            "filter_mode": "none",
            "transition_mode": "off",
            "custom_speed": 1.0,
            "custom_pitch": 1.0,
            "custom_modifiers_left": 0,
            "dj_only_mode": False,
            "stay_in_vc": False,
            "queue_count": 0,
            "backup_queue_count": 0,
            "backup_restore_ready": False,
            "pending_direct_orders": 0,
            "latest_direct_order": None,
            "home_channel_id": None,
            "home_channel_name": None,
            "feedback_channel_id": None,
            "feedback_channel_name": None,
        },
    }


async def _enrich_control_state_with_discord(control_state: dict[str, Any]) -> dict[str, Any]:
    bot_key = control_state["key"]
    guild_id = str(control_state["guild_id"])
    token = settings.bot_tokens.get(bot_key, "").strip()
    session = control_state.get("session", {})

    if not token:
        control_state["discord"] = {
            "status": "missing",
            "reachable": False,
            "message": "Panel token is not configured for Discord inventory access.",
            "token_configured": False,
        }
        return control_state

    try:
        guild = await discord_service.fetch_guild(token, guild_id)
        placements = [(guild_id, None)]
        for channel_id in (
            session.get("channel_id"),
            session.get("home_channel_id"),
            session.get("feedback_channel_id"),
        ):
            if channel_id:
                placements.append((guild_id, str(channel_id)))

        name_map = await discord_service.resolve_guild_channel_names(token, placements)
        guild_meta = name_map.get((guild_id, None), {})
        session["guild_name"] = guild_meta.get("guild_name") or guild.get("name") or f"Guild {guild_id}"

        if session.get("channel_id"):
            session["channel_name"] = (name_map.get((guild_id, str(session["channel_id"]))) or {}).get("channel_name")
        if session.get("home_channel_id"):
            session["home_channel_name"] = (name_map.get((guild_id, str(session["home_channel_id"]))) or {}).get("channel_name")
        if session.get("feedback_channel_id"):
            session["feedback_channel_name"] = (name_map.get((guild_id, str(session["feedback_channel_id"]))) or {}).get("channel_name")

        control_state["discord"] = {
            "status": "online",
            "reachable": True,
            "message": f"Live Discord route is valid in {session['guild_name']}.",
            "token_configured": True,
        }
    except Exception as exc:
        control_state["discord"] = {
            "status": "error",
            "reachable": False,
            "message": str(exc)[:240],
            "token_configured": True,
        }

    return control_state


@router.get("/api/bots/{bot_key}/control-state")
async def bot_control_state(request: Request, bot_key: str, guild_id: str):
    auth = _require_api_auth(request)
    await _require_bot_guild_access(auth, bot_key, guild_id)
    bot = BOT_INDEX.get(bot_key)
    if not bot or bot.kind != "music":
        raise HTTPException(status_code=404, detail="Unknown music bot key")

    try:
        state = await db.get_bot_control_state(bot_key, guild_id)
        return await _enrich_control_state_with_discord(state)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    except Exception as exc:
        action_logger.exception("Failed building control state bot=%s guild=%s: %s", bot_key, guild_id, exc)
        raise HTTPException(status_code=503, detail=_safe_error_detail("Control state unavailable", exc))


@router.get("/api/guilds/{guild_id}/control-matrix")
async def guild_control_matrix(request: Request, guild_id: str):
    auth = _require_api_auth(request)
    _require_guild_scope(auth, guild_id)
    visible_bots = await _visible_music_bots_for_auth(auth)

    async def collect(bot) -> dict[str, Any]:
        try:
            state = await db.get_bot_control_state(bot.key, guild_id)
            return await _enrich_control_state_with_discord(state)
        except Exception as exc:
            action_logger.warning("Failed control matrix snapshot bot=%s guild=%s: %s", bot.key, guild_id, exc)
            return _control_state_error_payload(bot.key, bot.display_name, guild_id, str(exc))

    bots = await asyncio.gather(*(collect(bot) for bot in visible_bots))
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "guild_id": str(guild_id),
        "bots": bots,
    }


@router.get("/api/music-intelligence")
async def music_intelligence(request: Request, guild_id: str | None = None, bot_key: str | None = None, limit: int = 8):
    auth = _require_api_auth(request)
    limit = _bounded_query_limit(limit, default=8, max_limit=50)
    scoped_guild = _scoped_guild_id(auth)
    if scoped_guild:
        guild_id = str(scoped_guild)
    elif guild_id:
        _require_guild_scope(auth, guild_id)
    else:
        _require_admin_auth(request)

    if bot_key and guild_id:
        await _require_bot_guild_access(auth, bot_key, guild_id)
    elif bot_key and scoped_guild:
        await _require_bot_guild_access(auth, bot_key, scoped_guild)

    try:
        return {
            "ok": True,
            "data": await db.get_music_intelligence_summary(guild_id=guild_id, bot_key=bot_key, limit=limit),
        }
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    except Exception as exc:
        action_logger.exception("Failed loading music intelligence guild=%s bot=%s: %s", guild_id, bot_key, exc)
        raise HTTPException(status_code=503, detail=_safe_error_detail("Music intelligence unavailable", exc))


@router.post("/api/bots/control")
async def api_bot_control(request: Request, req: BotControlRequest):
    auth = _require_api_auth(request)
    try:
        action_name = _normalize_control_action(req.action or req.command or "")
        if _scoped_guild_id(auth) and action_name == "RESTART":
            raise HTTPException(status_code=403, detail="Restart is admin-only because it affects the whole bot node")
        await _require_bot_guild_access(auth, req.bot_key, req.guild_id)
        action, guild_id, payload = await _normalize_bot_control_request(req)
        result = await db.control_bot(req.bot_key, guild_id, action, payload)
        result.setdefault("command", action)
        await push_feed_event(
            "info",
            "Bot Control Accepted",
            result.get("message") or f"{action} accepted for {req.bot_key} in guild {guild_id}.",
            source="api",
            event_type="command_ack",
        )
        return {"ok": True, **result}
    except ValueError as e:
        await push_feed_event("warning", "Invalid Bot Control", str(e), source="api")
        raise HTTPException(status_code=400, detail=str(e))
    except HTTPException:
        raise
    except Exception as e:
        await push_feed_event("error", "Bot Control Failed", str(e), source="api")
        raise HTTPException(status_code=500, detail=_safe_error_detail("Bot control failed", e))
