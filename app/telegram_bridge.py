"""Telegram command handling and health-alert bridge.

Used exclusively by main.py's lifespan (registers _handle_telegram_command
with the TelegramPollingService and schedules _telegram_health_watch_loop as
a background task) — no route depends on this directly.
"""

import asyncio
import os
import time
from typing import Any

from . import services as _services_module
from .bots import BOT_INDEX
from .dashboard import _load_dashboard_base_snapshot
from .services import action_logger, db, diagnostics_service, settings


def _telegram_command_parts(text: str) -> tuple[str, str]:
    cleaned = str(text or "").strip()
    if not cleaned:
        return "", ""
    first, _, rest = cleaned.partition(" ")
    return first.split("@", 1)[0].lower(), rest.strip()


def _format_panel_dashboard(snapshot: dict[str, Any]) -> str:
    bots = list(snapshot.get("bots") or [])
    sessions = list(snapshot.get("sessions") or [])
    active = sum(int(bot.get("active_playing_count") or 0) for bot in bots)
    queued = sum(int(bot.get("queue_depth") or 0) for bot in bots)
    lines = [
        "SwarmPanel status",
        f"Bots: {len(bots)}",
        f"Active sessions: {active or len([s for s in sessions if s.get('is_playing')])}",
        f"Queued tracks: {queued}",
    ]
    for bot in bots[:10]:
        name = bot.get("display_name") or bot.get("name") or bot.get("key")
        state = bot.get("heartbeat_status") or bot.get("status") or "unknown"
        lines.append(f"- {name}: {state}, {int(bot.get('queue_depth') or 0)} queued")
    return "\n".join(lines)


def _format_panel_sessions(snapshot: dict[str, Any]) -> str:
    sessions = list(snapshot.get("sessions") or [])
    if not sessions:
        return "No live SwarmPanel sessions are reporting right now."
    lines = ["Live SwarmPanel sessions"]
    for session in sessions[:12]:
        bot_name = session.get("bot_name") or session.get("bot_key") or "bot"
        title = session.get("title") or session.get("session_state") or "idle"
        guild = session.get("guild_name") or session.get("guild_id") or "unknown guild"
        channel = session.get("channel_name") or session.get("home_channel_name") or "no channel"
        lines.append(f"- {bot_name}: {title} | {guild} / {channel}")
    return "\n".join(lines)


def _format_panel_bots_list(snapshot: dict[str, Any]) -> str:
    bots = list(snapshot.get("bots") or [])
    if not bots:
        return "No bots registered in SwarmPanel."
    lines = ["Music bots (use key with /pause /skip etc):"]
    for bot in bots[:15]:
        key = bot.get("key") or "?"
        name = bot.get("display_name") or bot.get("name") or key
        state = bot.get("heartbeat_status") or bot.get("status") or "unknown"
        active = int(bot.get("active_playing_count") or 0)
        guilds = int(bot.get("known_guild_count") or bot.get("guild_count") or 0)
        playing = f", playing" if active else ""
        lines.append(f"- {key} ({name}): {state}, {guilds} guild(s){playing}")
    return "\n".join(lines)


def _format_diag_snapshot(snapshot: dict[str, Any]) -> str:
    """Format the diagnostics snapshot from diagnostics_service.get_snapshot()."""
    lines = ["SwarmPanel diagnostics"]
    generated_at = snapshot.get("generated_at", "")
    if generated_at:
        lines.append(f"Generated: {generated_at[:19].replace('T', ' ')} UTC")

    # Panel DB
    panel = snapshot.get("panel") or {}
    panel_db = panel.get("db") or {}
    db_status = panel_db.get("status") or "unknown"
    db_host = panel_db.get("host") or settings.db_host
    lines.append(f"Panel DB ({db_host}): {db_status}")

    # Aria
    aria = snapshot.get("aria") or {}
    aria_db = aria.get("db") or {}
    aria_status = aria_db.get("status") or "unknown"
    aria_discord = aria.get("discord") or {}
    aria_discord_status = aria_discord.get("status") or "unknown"
    lines.append(f"Aria DB: {aria_status} | Discord: {aria_discord_status}")

    # Music bots
    bots = list(snapshot.get("bots") or [])
    if bots:
        lines.append(f"Music bots ({len(bots)}):")
        for bot in bots[:8]:
            key = bot.get("key") or "?"
            db_probe = (bot.get("db") or {})
            bot_db_status = db_probe.get("status") or "unknown"
            discord_probe = (bot.get("discord") or {})
            bot_discord_status = discord_probe.get("status") or "unknown"
            lines.append(f"  {key}: db={bot_db_status} discord={bot_discord_status}")

    # Shared env
    shared_env = snapshot.get("shared_env") or {}
    env_status = shared_env.get("status") or "unknown"
    lines.append(f"Shared env: {env_status}")

    return "\n".join(lines)


async def _telegram_issue_bot_control(
    bot_key: str, guild_id: str, action: str
) -> str:
    """Issue a simple bot control action from Telegram and return a result string."""
    bot = BOT_INDEX.get(bot_key)
    if not bot:
        return f"Unknown bot key '{bot_key}'. Use /bots to see valid keys."
    if bot.kind != "music":
        return f"Bot '{bot_key}' is not a music bot. Direct controls only work on music bots."
    try:
        result = await db.control_bot(bot_key, guild_id, action.upper(), None)
        msg = result.get("message") or f"{action.upper()} accepted for {bot_key} in guild {guild_id}."
        return f"OK: {msg}"
    except Exception as exc:
        action_logger.warning("Telegram bot control failed bot=%s guild=%s action=%s: %s", bot_key, guild_id, action, exc)
        return f"Control failed: {str(exc)[:300]}"


_TELEGRAM_HELP_TEXT = (
    "SwarmPanel Telegram bridge\n"
    "\n"
    "Status commands:\n"
    "  /status   — Swarm overview (bot states + queue counts)\n"
    "  /bots     — List all bots with their keys\n"
    "  /sessions — Live playback sessions\n"
    "  /diag     — Full diagnostics (DB, Discord, env)\n"
    "  /id       — Show your Telegram chat id\n"
    "  /ping     — Check bridge is alive\n"
    "\n"
    "Bot control (requires bot_key and guild_id):\n"
    "  /pause   <bot_key> <guild_id>\n"
    "  /resume  <bot_key> <guild_id>\n"
    "  /skip    <bot_key> <guild_id>\n"
    "  /stop    <bot_key> <guild_id>\n"
    "  /leave   <bot_key> <guild_id>\n"
    "  /clear   <bot_key> <guild_id>\n"
    "  /shuffle <bot_key> <guild_id>\n"
    "  /restart <bot_key>            (restarts the bot node)\n"
    "\n"
    "Example: /pause gws 123456789012345678\n"
    "Use /bots to see bot keys, /sessions to see active guild IDs."
)

_TELEGRAM_SIMPLE_ACTIONS = {
    "/pause": "PAUSE",
    "pause": "PAUSE",
    "/resume": "RESUME",
    "resume": "RESUME",
    "/skip": "SKIP",
    "skip": "SKIP",
    "/stop": "STOP",
    "stop": "STOP",
    "/leave": "LEAVE",
    "leave": "LEAVE",
    "/clear": "CLEAR",
    "clear": "CLEAR",
    "/shuffle": "SHUFFLE",
    "shuffle": "SHUFFLE",
}


async def _handle_telegram_command(message: dict[str, Any]) -> str:
    command, rest = _telegram_command_parts(str(message.get("text") or ""))

    if command in {"/start", "/help", "help", "/h"}:
        return _TELEGRAM_HELP_TEXT

    if command in {"/ping", "ping"}:
        return "SwarmPanel is online."

    if command == "/id":
        return f"Your Telegram chat id: {message.get('chat_id')}"

    if command in {"/status", "status"}:
        snapshot = await _load_dashboard_base_snapshot()
        return _format_panel_dashboard(snapshot)

    if command in {"/bots", "bots"}:
        snapshot = await _load_dashboard_base_snapshot()
        return _format_panel_bots_list(snapshot)

    if command in {"/sessions", "sessions"}:
        snapshot = await _load_dashboard_base_snapshot()
        return _format_panel_sessions(snapshot)

    if command in {"/diag", "/diagnostics", "diag"}:
        force = rest.lower() in {"force", "fresh", "true", "1"}
        snapshot = await diagnostics_service.get_snapshot(force=force)
        return _format_diag_snapshot(snapshot)

    # Simple bot control commands: /pause gws 123456789
    if command in _TELEGRAM_SIMPLE_ACTIONS:
        action = _TELEGRAM_SIMPLE_ACTIONS[command]
        parts = rest.split()
        if len(parts) < 2:
            return (
                f"Usage: {command} <bot_key> <guild_id>\n"
                f"Example: {command} gws 123456789012345678\n"
                "Use /bots to see bot keys, /sessions to see guild IDs."
            )
        bot_key = parts[0].lower()
        guild_id = parts[1]
        return await _telegram_issue_bot_control(bot_key, guild_id, action)

    # /restart <bot_key>
    if command in {"/restart", "restart"}:
        parts = rest.split()
        if not parts:
            return "Usage: /restart <bot_key>\nExample: /restart gws\nUse /bots to see bot keys."
        bot_key = parts[0].lower()
        return await _telegram_issue_bot_control(bot_key, "0", "RESTART")

    return "Unknown command. Send /help to see all SwarmPanel Telegram commands."


TELEGRAM_HEALTH_INTERVAL_SECONDS = max(60.0, float(os.getenv("PANEL_TELEGRAM_HEALTH_INTERVAL_SECONDS", "300") or "300"))
TELEGRAM_ALERT_COOLDOWN_SECONDS = max(300.0, float(os.getenv("PANEL_TELEGRAM_ALERT_COOLDOWN_SECONDS", "900") or "900"))
_telegram_alert_last: dict[str, float] = {}


async def _send_panel_telegram_alert(key: str, title: str, detail: str) -> None:
    # telegram_service lives in app/services.py and is reassigned during
    # lifespan startup — must read it live via the module, not a bound import.
    if not _services_module.telegram_service:
        return
    # Use alert_chat_ids() so learned recipients (username→chat_id) are included,
    # not just the raw configured chat IDs.
    alert_ids = _services_module.telegram_service.alert_chat_ids()
    if not alert_ids:
        action_logger.warning(
            "SwarmPanel Telegram alert '%s' skipped: no allowed chat IDs known yet. "
            "Message the bot first so it can learn your chat id.",
            key,
        )
        return
    now = time.monotonic()
    if now - _telegram_alert_last.get(key, 0.0) < TELEGRAM_ALERT_COOLDOWN_SECONDS:
        return
    _telegram_alert_last[key] = now
    message = f"{title}\n{str(detail or '').strip()[:1200]}"
    for chat_id in sorted(alert_ids):
        try:
            await _services_module.telegram_service.send_message(chat_id, message)
        except Exception:
            action_logger.exception("SwarmPanel Telegram alert delivery failed for chat %s.", chat_id)


async def _telegram_health_watch_loop() -> None:
    await asyncio.sleep(20)
    while True:
        try:
            db_ok = await db.ping()
            if not db_ok:
                raise RuntimeError("Database ping returned False")
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            action_logger.exception("SwarmPanel database health check failed.")
            await _send_panel_telegram_alert("db", "SwarmPanel database problem", str(exc))
            try:
                await db.connect()
            except asyncio.CancelledError:
                raise
            except Exception:
                action_logger.exception("SwarmPanel database reconnect failed after health alert.")
        try:
            await asyncio.sleep(TELEGRAM_HEALTH_INTERVAL_SECONDS)
        except asyncio.CancelledError:
            raise
