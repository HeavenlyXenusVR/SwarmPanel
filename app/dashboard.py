"""Dashboard snapshot building and guild-scoped bot visibility.

Shared across domains: the health router's /api/dashboard route, the bots
router's guild-access checks, the websocket router's broadcast loop, and the
telegram bridge's /status /bots /sessions commands all need these — none of
that is health-only or bots-only despite the underlying data living in
BotsMixin.get_dashboard_data().
"""

import asyncio
import copy
import os
from datetime import datetime, timezone
from typing import Any

from fastapi import HTTPException

from .auth_deps import _is_admin_auth, _require_guild_scope, _scoped_guild_id
from .bots import ALL_BOTS, BOT_INDEX, MUSIC_BOTS
from .services import db, discord_service, settings

DISCORD_IDENTITY_LOOKUP_TIMEOUT_SECONDS = max(1.0, float(os.getenv("SWARM_PANEL_DISCORD_IDENTITY_TIMEOUT_SECONDS", "4.0") or "4.0"))
DISCORD_NAME_RESOLUTION_TIMEOUT_SECONDS = max(1.5, float(os.getenv("SWARM_PANEL_DISCORD_NAME_RESOLUTION_TIMEOUT_SECONDS", "6.0") or "6.0"))


async def _bot_has_registered_guild(bot_key: str, guild_id: str | int) -> bool:
    bot = BOT_INDEX.get(bot_key)
    if not bot or bot.kind != "music":
        return False

    try:
        known_guilds = await db.get_known_guild_ids(bot_key)
        if int(guild_id) in known_guilds:
            return True
    except Exception:
        pass

    token = settings.bot_tokens.get(bot_key, "").strip()
    if not token:
        return False
    try:
        guilds = await discord_service.fetch_guilds(token)
        return any(str(guild.get("id")) == str(guild_id) for guild in guilds)
    except Exception:
        return False


async def _visible_music_bots_for_auth(auth: dict[str, Any]) -> list:
    scoped = _scoped_guild_id(auth)
    if not scoped:
        return list(MUSIC_BOTS)
    checks = await asyncio.gather(
        *(_bot_has_registered_guild(bot.key, scoped) for bot in MUSIC_BOTS),
        return_exceptions=True,
    )
    return [bot for bot, ok in zip(MUSIC_BOTS, checks) if ok is True]


async def _require_bot_guild_access(auth: dict[str, Any], bot_key: str, guild_id: str | int) -> None:
    _require_guild_scope(auth, guild_id)
    scoped = _scoped_guild_id(auth)
    if scoped and not await _bot_has_registered_guild(bot_key, scoped):
        raise HTTPException(status_code=403, detail="This bot is not registered with your guild")


async def _load_dashboard_base_snapshot() -> dict[str, Any]:
    try:
        return await db.get_dashboard_data()
    except Exception as exc:
        return {
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "db_error": str(exc),
            "bots": [
                {
                    "key": bot.key,
                    "display_name": bot.display_name,
                    "kind": bot.kind,
                    "schema": bot.db_schema,
                    "status": "db-unavailable",
                    "heartbeat_age_seconds": None,
                    "heartbeat_status": "unknown",
                    "active_playing_count": 0,
                    "known_guild_count": 0,
                    "sessions": [],
                }
                for bot in ALL_BOTS
            ],
        }


def _dashboard_scope_cache_key(auth: dict[str, Any]) -> str:
    scoped_guild_id = _scoped_guild_id(auth)
    if scoped_guild_id:
        return f"guild:{scoped_guild_id}"
    return "admin" if _is_admin_auth(auth) else f"session:{str(auth.get('username') or auth.get('id') or 'default')}"


async def _build_dashboard_payload(auth: dict[str, Any], *, enrich_discord: bool) -> dict[str, Any]:
    scoped_guild_id = _scoped_guild_id(auth)
    data = copy.deepcopy(await _load_dashboard_base_snapshot())

    if scoped_guild_id:
        visible_bot_keys = {bot.key for bot in await _visible_music_bots_for_auth(auth)}
        scoped_bots = []
        for bot in data.get("bots", []):
            if bot.get("kind") != "music" or bot.get("key") not in visible_bot_keys:
                continue
            sessions = [
                session for session in bot.get("sessions", [])
                if str(session.get("guild_id")) == scoped_guild_id
            ]
            bot["sessions"] = sessions
            bot["known_guild_count"] = 1
            bot["guild_count"] = 1
            bot["active_playing_count"] = sum(1 for session in sessions if session.get("is_playing"))
            bot["queue_depth"] = sum(int(s.get("queue_count") or 0) for s in sessions)
            bot["backup_queue_depth"] = sum(int(s.get("backup_queue_count") or 0) for s in sessions)
            scoped_bots.append(bot)
        data["bots"] = scoped_bots

    flattened_sessions: list[dict[str, Any]] = []
    seen_session_keys: set[tuple[str, str]] = set()
    bots = list(data.get("bots", []))
    identity_tasks: dict[str, asyncio.Task[dict[str, Any]]] = {}
    name_tasks: dict[str, tuple[dict[str, Any], list[dict[str, Any]], asyncio.Task[dict[tuple[int, int | None], dict[str, str | None]]]]] = {}
    for bot in bots:
        bot.setdefault("name", bot.get("display_name"))
        bot.setdefault("guild_count", bot.get("known_guild_count", 0))
        token = settings.bot_tokens.get(bot["key"], "")
        if enrich_discord:
            bot["discord"] = {"token_configured": bool(token)}
            if token:
                identity_tasks[bot["key"]] = asyncio.create_task(
                    asyncio.wait_for(
                        discord_service.fetch_identity(token),
                        timeout=DISCORD_IDENTITY_LOOKUP_TIMEOUT_SECONDS,
                    )
                )
        sessions = bot.get("sessions", [])
        for session in sessions:
            session.setdefault("bot_key", bot.get("key"))
            session.setdefault("bot_name", bot.get("display_name"))
            session.setdefault("bot_display", bot.get("display_name"))
            session_key = (str(session.get("bot_key") or bot.get("key")), str(session.get("guild_id") or "0"))
            if session_key in seen_session_keys:
                continue
            seen_session_keys.add(session_key)
            flattened_sessions.append(session)
        if not enrich_discord or not sessions or not token:
            continue
        placements = []
        for session in sessions:
            guild_id = str(session["guild_id"])
            if session.get("channel_id"):
                placements.append((guild_id, str(session["channel_id"])))
            if session.get("home_channel_id"):
                placements.append((guild_id, str(session["home_channel_id"])))
        if placements:
            name_tasks[bot["key"]] = (
                bot,
                sessions,
                asyncio.create_task(
                    asyncio.wait_for(
                        discord_service.resolve_guild_channel_names(token, placements),
                        timeout=DISCORD_NAME_RESOLUTION_TIMEOUT_SECONDS,
                    )
                ),
            )

    if identity_tasks:
        identity_results = await asyncio.gather(*identity_tasks.values(), return_exceptions=True)
        for bot_key, result in zip(identity_tasks.keys(), identity_results):
            bot = next((item for item in bots if item.get("key") == bot_key), None)
            if not bot:
                continue
            bot.setdefault("discord", {})
            if isinstance(result, Exception):
                bot["discord"]["error"] = "Discord identity lookup timed out." if isinstance(result, asyncio.TimeoutError) else str(result)
                continue
            bot["discord"]["identity"] = result

    if name_tasks:
        name_results = await asyncio.gather(*(task for _bot, _sessions, task in name_tasks.values()), return_exceptions=True)
        for (bot_key, (bot, sessions, _task)), result in zip(name_tasks.items(), name_results):
            bot.setdefault("discord", {})
            if isinstance(result, Exception):
                bot["discord"]["name_resolution_error"] = "Discord channel lookup timed out." if isinstance(result, asyncio.TimeoutError) else str(result)
                continue
            name_map = result
            for session in sessions:
                guild_id = str(session["guild_id"])
                channel_key = (guild_id, str(session["channel_id"])) if session.get("channel_id") else None
                home_key = (guild_id, str(session["home_channel_id"])) if session.get("home_channel_id") else None

                channel_names = name_map.get(channel_key) if channel_key else None
                if channel_names:
                    session["guild_name"] = channel_names.get("guild_name")
                    session["channel_name"] = channel_names.get("channel_name")

                home_names = name_map.get(home_key) if home_key else None
                if home_names:
                    session["guild_name"] = session.get("guild_name") or home_names.get("guild_name")
                    session["home_channel_name"] = home_names.get("channel_name")

    data["bots"] = bots
    data["sessions"] = flattened_sessions
    return data
