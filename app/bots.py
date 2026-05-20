import os
from dataclasses import dataclass
from pathlib import Path
from typing import Optional
from urllib.parse import urlencode

try:
    from dotenv import load_dotenv
except Exception:  # pragma: no cover - dotenv is a runtime dependency, but keep imports resilient.
    load_dotenv = None

if load_dotenv:
    _PANEL_ROOT = Path(__file__).resolve().parents[1]
    _PROJECTS_ROOT = _PANEL_ROOT.parent
    # BotDefinition values are created at import time, so the shared .env files
    # must be loaded before _music_schema() reads per-bot DB overrides.
    load_dotenv(_PANEL_ROOT / ".env", override=False)
    load_dotenv(_PROJECTS_ROOT / "Music" / ".env", override=False)


@dataclass(frozen=True)
class BotDefinition:
    key: str
    display_name: str
    kind: str
    token_env: str
    db_schema: Optional[str] = None
    table_prefix: Optional[str] = None


def _music_schema(bot_key: str, fallback: str) -> str:
    """Resolve a music bot database schema from the runtime environment.

    SwarmPanel runs from its own .env, while the music stack may define
    per-bot DB names in the Music .env. Keeping the schema configurable
    prevents a single renamed/shared bot schema from breaking login.
    """
    value = os.getenv(f"{bot_key.upper()}_DB_NAME", fallback).strip()
    return value or fallback


DISCORD_PERMISSION_BITS = {
    "Kick Members": 1,
    "Ban Members": 2,
    "Manage Channels": 4,
    "Manage Server": 5,
    "View Channels": 10,
    "Send Messages": 11,
    "Manage Messages": 13,
    "Embed Links": 14,
    "Attach Files": 15,
    "Read Message History": 16,
    "Connect": 20,
    "Speak": 21,
    "Use Voice Activity": 25,
    "Manage Nicknames": 27,
    "Manage Roles": 28,
    "Use Application Commands": 31,
    "Request To Speak": 32,
    "Timeout Members": 40,
}

MUSIC_BOT_PERMISSIONS = [
    "View Channels",
    "Send Messages",
    "Embed Links",
    "Attach Files",
    "Read Message History",
    "Connect",
    "Speak",
    "Use Voice Activity",
    "Use Application Commands",
    "Request To Speak",
    "Manage Channels",
]

ARIA_BOT_PERMISSIONS = [
    "View Channels",
    "Send Messages",
    "Embed Links",
    "Attach Files",
    "Read Message History",
    "Use Application Commands",
    "Kick Members",
    "Manage Messages",
    "Manage Channels",
    "Manage Server",
    "Manage Roles",
    "Manage Nicknames",
    "Ban Members",
    "Timeout Members",
]

BOT_ACCENTS = {
    "gws": "#cba6f7",
    "harmonic": "#89b4fa",
    "maestro": "#a6e3a1",
    "melodic": "#fab387",
    "nexus": "#f38ba8",
    "rhythm": "#94e2d5",
    "symphony": "#f9e2af",
    "tunestream": "#b4befe",
    "alucard": "#e06c75",
    "sapphire": "#4fc3f7",
    "strife": "#ff6b6b",
    "lockhart": "#f9a8d4",
    "aria": "#cba6f7",
}

BOT_CAPABILITY_SUMMARIES = {
    "music": "Music worker node: slash commands, queue controls, voice/stage playback, feedback messages, embeds, buttons, and channel status/topic updates.",
    "orchestrator": "Aria orchestrator: slash commands, swarm routing, AI/game/economy tools, scheduled messages, moderation, roles, nicknames, slowmode, channel locks, and server utilities.",
}


MUSIC_BOTS = [
    BotDefinition("gws", "GWS", "music", "GWS_DISCORD_TOKEN", _music_schema("gws", "discord_music_gws"), "gws"),
    BotDefinition("harmonic", "Harmonic", "music", "HARMONIC_DISCORD_TOKEN", _music_schema("harmonic", "discord_music_harmonic"), "harmonic"),
    BotDefinition("maestro", "Maestro", "music", "MAESTRO_DISCORD_TOKEN", _music_schema("maestro", "discord_music_maestro"), "maestro"),
    BotDefinition("melodic", "Melodic", "music", "MELODIC_DISCORD_TOKEN", _music_schema("melodic", "discord_music_melodic"), "melodic"),
    BotDefinition("nexus", "Nexus", "music", "NEXUS_DISCORD_TOKEN", _music_schema("nexus", "discord_music_nexus"), "nexus"),
    BotDefinition("rhythm", "Rhythm", "music", "RHYTHM_DISCORD_TOKEN", _music_schema("rhythm", "discord_music_rhythm"), "rhythm"),
    BotDefinition("symphony", "Symphony", "music", "SYMPHONY_DISCORD_TOKEN", _music_schema("symphony", "discord_music_symphony"), "symphony"),
    BotDefinition("tunestream", "Tunestream", "music", "TUNESTREAM_DISCORD_TOKEN", _music_schema("tunestream", "discord_music_tunestream"), "tunestream"),
    BotDefinition("alucard", "Alucard", "music", "ALUCARD_DISCORD_TOKEN", _music_schema("alucard", "discord_music_alucard"), "alucard"),
    BotDefinition("sapphire", "Sapphire", "music", "SAPPHIRE_DISCORD_TOKEN", _music_schema("sapphire", "discord_music_sapphire"), "sapphire"),
    BotDefinition("strife", "Strife", "music", "STRIFE_DISCORD_TOKEN", _music_schema("strife", "discord_music_strife"), "strife"),
    BotDefinition("lockhart", "Lockhart", "music", "LOCKHART_DISCORD_TOKEN", _music_schema("lockhart", "discord_music_lockhart"), "lockhart"),
]

ARIA_BOT = BotDefinition("aria", "Aria", "orchestrator", "ARIA_DISCORD_TOKEN")

ALL_BOTS = [*MUSIC_BOTS, ARIA_BOT]
BOT_INDEX = {bot.key: bot for bot in ALL_BOTS}


def permission_value(permission_names: list[str]) -> int:
    return sum(1 << DISCORD_PERMISSION_BITS[name] for name in permission_names)


def permissions_for_bot(bot: BotDefinition) -> list[str]:
    if bot.kind == "orchestrator":
        return ARIA_BOT_PERMISSIONS
    return MUSIC_BOT_PERMISSIONS


def invite_url_for_bot(client_id: str, permissions: int, guild_id: str | None = None) -> str:
    params = {
        "client_id": client_id,
        "permissions": str(permissions),
        "scope": "bot applications.commands",
    }
    if guild_id:
        params["guild_id"] = str(guild_id)
        params["disable_guild_select"] = "true"
    return f"https://discord.com/oauth2/authorize?{urlencode(params)}"
