"""Field-normalization helpers shared by request payload cleaning across
domains (profiles, panel appearance preferences, swarm-account/gallery admin
updates). Pure functions — no settings/db/service dependency."""

import re
from typing import Any
from urllib.parse import urlparse

PROFILE_ACCENT_RE = re.compile(r"^#[0-9A-Fa-f]{6}$")

DISCORD_INVITE_HOSTS = {
    "discord.gg",
    "www.discord.gg",
    "discord.com",
    "www.discord.com",
    "discordapp.com",
    "www.discordapp.com",
}

PANEL_THEME_MODES = {"dark", "light", "system"}
PANEL_BACKGROUND_MODES = {"default", "midnight", "aurora", "ember", "custom_color", "custom_image"}
PANEL_LAYOUT_MODES = {"standard", "focused", "wide"}
PANEL_DENSITY_MODES = {"comfortable", "compact"}
PANEL_SHAPE_MODES = {"soft", "crisp"}
PANEL_FONT_MODES = {"normal", "large", "dense"}
PANEL_MOTION_MODES = {"standard", "reduced"}
PANEL_OPERATOR_LAYOUT_MODES = {"command", "console", "compact"}
PANEL_ROSTER_LAYOUT_MODES = {"cards", "signals", "ledger"}
PANEL_TAB_STYLE_MODES = {"rail", "underline", "minimal"}
PANEL_STREAM_CARD_MODES = {"telemetry", "compact", "cinematic"}
PANEL_DASHBOARD_DENSITY_MODES = {"command", "dense"}
PANEL_LOOK_ALIASES = {
    "operator_layout": {"spotlight": "command", "studio": "console"},
    "roster_layout": {"grid": "cards", "magazine": "signals", "stack": "ledger"},
    "tab_style": {"pills": "rail"},
    "stream_card_style": {"editorial": "telemetry"},
    "dashboard_density": {"comfortable": "command", "compact": "dense"},
}
PROFILE_BANNER_MODES = {"gradient", "image", "signal", "quiet", "contrast"}
PROFILE_CARD_STYLES = {"solid", "glass", "outline", "terminal"}
PROFILE_SOCIAL_MODES = {"open", "friends", "quiet"}
PROFILE_LAYOUT_MODES = {"default", "sidebar", "stacked", "split"}
PROFILE_HEADER_STYLES = {"solid", "glass", "blur", "transparent", "gradient"}
PROFILE_BORDER_ACCENTS = {"none", "glow", "pulse", "neon", "solid"}
PANEL_SIDEBAR_STYLES = {"full", "icons", "minimal"}
PANEL_FONT_FAMILIES = {"system", "mono", "rounded"}
PANEL_CARD_HOVER_EFFECTS = {"lift", "glow", "border", "none"}
PANEL_NOTIFICATION_POSITIONS = {"br", "bl", "tr", "tc"}
PANEL_BOT_CARD_DETAILS = {"full", "compact", "minimal"}
PANEL_RADIUS_MODES = {"none", "small", "medium", "large", "pill"}


def _validate_discord_webhook_url(value: Any) -> str:
    url = str(value or "").strip()
    parsed = urlparse(url)
    host = (parsed.netloc or "").lower()
    if parsed.scheme != "https" or host not in {"discord.com", "www.discord.com", "discordapp.com", "www.discordapp.com"}:
        raise ValueError("Invalid Discord webhook URL")
    parts = [part for part in parsed.path.split("/") if part]
    if len(parts) < 4 or parts[0] != "api" or parts[1] != "webhooks":
        raise ValueError("Invalid Discord webhook URL")
    return url


def _normalize_optional_text(value: Any, field_name: str, max_length: int) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    if len(text) > max_length:
        raise ValueError(f"{field_name} must be {max_length} characters or fewer")
    return text


def _normalize_public_url(value: Any, field_name: str, max_length: int = 600) -> str | None:
    url = _normalize_optional_text(value, field_name, max_length)
    if not url:
        return None
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError(f"{field_name} must be a public http or https URL")
    return url


def _normalize_server_invite_url(value: Any) -> str | None:
    url = _normalize_optional_text(value, "Server invite URL", 600)
    if not url:
        return None
    if url.startswith("discord.gg/"):
        url = f"https://{url}"
    parsed = urlparse(url)
    host = (parsed.netloc or "").lower()
    parts = [part for part in parsed.path.split("/") if part]
    valid_discord_invite = (
        parsed.scheme == "https"
        and host in DISCORD_INVITE_HOSTS
        and (
            host.endswith("discord.gg")
            or (len(parts) >= 2 and parts[0] == "invite")
        )
    )
    if not valid_discord_invite:
        raise ValueError("Server invite URL must be a Discord invite link")
    return url


def _normalize_profile_accent(value: Any) -> str | None:
    accent = _normalize_optional_text(value, "Theme accent", 20)
    if not accent:
        return None
    if not PROFILE_ACCENT_RE.fullmatch(accent):
        raise ValueError("Theme accent must be a hex color like #89b4fa")
    return accent.lower()


def _normalize_choice(value: Any, field_name: str, allowed: set[str], default: str) -> str:
    choice = str(value or default).strip().lower()
    if choice not in allowed:
        raise ValueError(f"{field_name} must be one of: {', '.join(sorted(allowed))}")
    return choice


def _normalize_panel_look_choice(value: Any, field_name: str, key: str, allowed: set[str], default: str) -> str:
    aliases = PANEL_LOOK_ALIASES.get(key, {})
    choice = str(value or default).strip().lower()
    choice = aliases.get(choice, choice)
    if choice not in allowed:
        raise ValueError(f"{field_name} must be one of: {', '.join(sorted(allowed))}")
    return choice


def _normalize_public_base_url(value: str | None) -> str:
    raw = str(value or "").strip()
    if not raw:
        return ""
    try:
        parsed = urlparse(raw)
    except Exception:
        return ""
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        return ""
    return f"{parsed.scheme}://{parsed.netloc}{parsed.path.rstrip('/')}"
