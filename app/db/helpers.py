"""Free-function helpers and constants shared across the PanelDatabase
mixins (accounts, social, bots, gallery, admin-browser, metrics). Kept in one
module rather than perfectly attributed per-domain, since most of these are
small, low-risk pure functions used by more than one mixin."""

import base64
import hashlib
import logging
import os
import re
import secrets
from typing import Any
from urllib.parse import parse_qs, urlparse

logger = logging.getLogger("swarm_panel")

ACCOUNT_USERNAME_RE = re.compile(r"^[A-Za-z0-9_.-]{2,80}$")
ACCOUNT_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
ACCOUNT_LOGIN_SCHEMA = "accountlogins"
ACCOUNT_LOGIN_TABLE = "users"
ACCOUNT_GUILD_LOCK_TABLE = "guild_locks"
ACCOUNT_AUTH_COLUMNS = (
    ("password_hash", "TEXT NULL"),
)
ACCOUNT_PROFILE_COLUMNS = (
    ("email", "VARCHAR(255) NULL"),
    ("email_verified_at", "TIMESTAMP NULL DEFAULT NULL"),
    ("email_verification_token_hash", "CHAR(64) NULL"),
    ("email_verification_code_hash", "CHAR(64) NULL"),
    ("email_verification_sent_at", "TIMESTAMP NULL DEFAULT NULL"),
    ("verification_webhook_url", "TEXT NULL"),
    ("verification_webhook_channel_id", "VARCHAR(40) NULL"),
    ("verification_webhook_name", "VARCHAR(120) NULL"),
    ("webhook_verified_at", "TIMESTAMP NULL DEFAULT NULL"),
    ("webhook_verification_code_hash", "CHAR(64) NULL"),
    ("webhook_verification_sent_at", "TIMESTAMP NULL DEFAULT NULL"),
    ("display_name", "VARCHAR(80) NULL"),
    ("avatar_url", "TEXT NULL"),
    ("bio", "VARCHAR(280) NULL"),
    ("profile_headline", "VARCHAR(140) NULL"),
    ("profile_tags", "JSON NULL"),
    ("profile_links", "JSON NULL"),
    ("profile_banner_url", "TEXT NULL"),
    ("profile_banner_mode", "VARCHAR(30) NULL"),
    ("profile_card_style", "VARCHAR(30) NULL"),
    ("profile_social_mode", "VARCHAR(30) NULL"),
    ("favorite_bot", "VARCHAR(50) NULL"),
    ("theme_accent", "VARCHAR(20) NULL"),
    ("public_profile", "TINYINT(1) NOT NULL DEFAULT 1"),
    ("server_invite_url", "TEXT NULL"),
    ("server_name", "VARCHAR(120) NULL"),
    ("server_icon_url", "TEXT NULL"),
    ("panel_preferences", "JSON NULL"),
    ("profile_quote", "VARCHAR(160) NULL"),
    ("profile_layout_mode", "VARCHAR(30) NULL"),
    ("profile_header_style", "VARCHAR(30) NULL"),
    ("profile_border_accent", "VARCHAR(30) NULL"),
    ("last_seen_at", "TIMESTAMP NULL DEFAULT NULL"),
    ("updated_at", "TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP"),
)
ACCOUNT_PROFILE_FIELDS = {name for name, _definition in ACCOUNT_PROFILE_COLUMNS}
SYSTEM_SCHEMAS = {"information_schema", "mysql", "performance_schema", "sys"}
YOUTUBE_HOSTS = {
    "youtube.com",
    "www.youtube.com",
    "m.youtube.com",
    "music.youtube.com",
    "youtu.be",
    "www.youtu.be",
}
SOUNDCLOUD_HOST_SUFFIXES = ("soundcloud.com",)
SOUNDCLOUD_HOSTS = {"snd.sc"}
THUMBNAIL_CACHE_TTL_SECONDS = 60 * 60
SMART_TITLE_NOISE_RE = re.compile(r"\s*[\[(][^\])]*(?:official|lyrics?|audio|video|visualizer|remaster|sped up|slowed)[^\])]*[\])]\s*", re.IGNORECASE)

PANEL_DB_POOL_MIN_SIZE = max(1, int(os.getenv("PANEL_DB_POOL_MIN_SIZE", "1") or "1"))
PANEL_DB_POOL_MAX_SIZE = max(PANEL_DB_POOL_MIN_SIZE, int(os.getenv("PANEL_DB_POOL_MAX_SIZE", "6") or "6"))
PANEL_DB_CONNECT_TIMEOUT_SECONDS = max(3, int(os.getenv("PANEL_DB_CONNECT_TIMEOUT_SECONDS", "10") or "10"))
PANEL_DB_QUERY_TIMEOUT_SECONDS = max(3.0, float(os.getenv("PANEL_DB_QUERY_TIMEOUT_SECONDS", "15") or "15"))
PANEL_DB_POOL_RECYCLE_SECONDS = max(60, int(os.getenv("PANEL_DB_POOL_RECYCLE_SECONDS", "900") or "900"))
PANEL_DASHBOARD_SNAPSHOT_CONCURRENCY = max(1, int(os.getenv("PANEL_DASHBOARD_SNAPSHOT_CONCURRENCY", "4") or "4"))
PANEL_TABLE_CACHE_TTL_SECONDS = max(10.0, float(os.getenv("PANEL_TABLE_CACHE_TTL_SECONDS", "120") or "120"))
PANEL_DASHBOARD_CACHE_TTL_SECONDS = max(0.5, float(os.getenv("PANEL_DASHBOARD_CACHE_TTL_SECONDS", "1") or "1"))
PANEL_SCHEMA_CACHE_TTL_SECONDS = max(10.0, float(os.getenv("PANEL_SCHEMA_CACHE_TTL_SECONDS", "120") or "120"))
PANEL_TABLE_DATA_CACHE_TTL_SECONDS = max(2.0, float(os.getenv("PANEL_TABLE_DATA_CACHE_TTL_SECONDS", "20") or "20"))
PANEL_TABLE_DATA_CACHE_MAX_ITEMS = max(16, int(os.getenv("PANEL_TABLE_DATA_CACHE_MAX_ITEMS", "64") or "64"))
PANEL_IMAGE_GALLERY_ADMIN_CACHE_TTL_SECONDS = max(2.0, float(os.getenv("PANEL_IMAGE_GALLERY_ADMIN_CACHE_TTL_SECONDS", "10") or "10"))
PANEL_MUSIC_INTELLIGENCE_CACHE_TTL_SECONDS = max(2.0, float(os.getenv("PANEL_MUSIC_INTELLIGENCE_CACHE_TTL_SECONDS", "20") or "20"))

GUILD_SETTINGS_COLUMNS = (
    ("home_vc_id", "BIGINT"),
    ("volume", "INT DEFAULT 100"),
    ("loop_mode", "VARCHAR(10) DEFAULT 'queue'"),
    ("filter_mode", "VARCHAR(20) DEFAULT 'none'"),
    ("dj_role_id", "BIGINT DEFAULT NULL"),
    ("feedback_channel_id", "BIGINT DEFAULT NULL"),
    ("transition_mode", "VARCHAR(10) DEFAULT 'off'"),
    ("fade_seconds", "FLOAT DEFAULT 5.0"),
    ("fade_curve", "VARCHAR(20) DEFAULT 'linear'"),
    ("custom_speed", "FLOAT DEFAULT 1.0"),
    ("custom_pitch", "FLOAT DEFAULT 1.0"),
    ("custom_modifiers_left", "INT DEFAULT 0"),
    ("dj_only_mode", "BOOLEAN DEFAULT FALSE"),
    ("stay_in_vc", "BOOLEAN DEFAULT FALSE"),
)


def _coerce_int(value: Any, field_name: str) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        raise ValueError(f"Invalid {field_name}: {value!r}") from None


def _normalize_account_username(value: Any) -> str:
    username = str(value or "").strip()
    if not ACCOUNT_USERNAME_RE.fullmatch(username):
        raise ValueError("Username must be 2-80 characters using letters, numbers, dots, dashes, or underscores.")
    return username


def _normalize_email(value: Any) -> str | None:
    email = str(value or "").strip().lower()
    if not email:
        return None
    if len(email) > 255 or not ACCOUNT_EMAIL_RE.fullmatch(email):
        raise ValueError("Enter a valid email address.")
    return email


def _verification_token_hash(token: str) -> str:
    return hashlib.sha256(str(token).encode("utf-8")).hexdigest()


def _password_hash(password: str) -> str:
    salt = secrets.token_bytes(16)
    iterations = 260_000
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations)
    return f"pbkdf2_sha256${iterations}${base64.b64encode(salt).decode()}${base64.b64encode(digest).decode()}"


def _verify_password_hash(password: str, stored_hash: str | None) -> bool:
    raw_hash = str(stored_hash or "").strip()
    if not raw_hash:
        return False
    try:
        algorithm, iterations_text, salt_b64, digest_b64 = raw_hash.split("$", 3)
        if algorithm != "pbkdf2_sha256":
            return False
        iterations = int(iterations_text)
        salt = base64.b64decode(salt_b64.encode())
        expected = base64.b64decode(digest_b64.encode())
        actual = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations)
        return secrets.compare_digest(actual, expected)
    except Exception:
        return False


def _gallery_password_hash(password: str) -> str:
    return _password_hash(password)


def _account_password_hash(password: str) -> str:
    return _password_hash(password)


def _normalize_account_password(value: Any, field_name: str = "Password") -> str:
    password = str(value or "")
    if len(password) < 8:
        raise ValueError(f"{field_name} must be at least 8 characters.")
    return password


def _normalize_loop_mode(value: Any) -> str:
    mode = str(value or "").strip().lower()
    valid_modes = {"off", "song", "queue"}
    if mode not in valid_modes:
        raise ValueError(f"Invalid loop mode: {value!r}. Expected one of: {', '.join(sorted(valid_modes))}")
    return mode


def _normalize_filter_mode(value: Any) -> str:
    mode = str(value or "").strip().lower().replace(" ", "")
    valid_modes = {
        "none",
        "nightcore",
        "vaporwave",
        "bassboost",
        "8d",
        "karaoke",
        "tremolo",
        "vibrato",
        "lowpass",
        "lofi",
        "electronic",
        "party",
        "radio",
        "cinema",
    }
    if mode not in valid_modes:
        raise ValueError(f"Invalid filter mode: {value!r}. Expected one of: {', '.join(sorted(valid_modes))}")
    return mode


def _derive_session_state(
    playback: dict[str, Any],
    *,
    queue_count: int,
    has_settings: bool,
    home_channel_id: int | None,
    backup_queue_count: int = 0,
) -> tuple[str, str]:
    is_playing = bool(playback.get("is_playing"))
    is_paused = bool(playback.get("is_paused"))
    has_track = bool(playback.get("title") or playback.get("video_url"))
    has_channel = playback.get("channel_id") is not None
    has_recovery_path = bool(home_channel_id and (has_track or queue_count > 0 or backup_queue_count > 0))

    if is_paused and has_track and has_channel:
        return "paused", "Paused"
    if is_playing and has_track and has_channel:
        return "playing", "Playing"
    if has_track and has_channel:
        return "paused", "Paused"
    if has_recovery_path and (queue_count > 0 or backup_queue_count > 0 or has_track):
        return "recovering", "Recovery Pending"
    if queue_count > 0:
        return "queued", "Queued"
    if has_settings or home_channel_id:
        return "configured", "Configured"
    return "idle", "Idle"


def _extract_youtube_video_id(video_url: str | None) -> str | None:
    if not video_url:
        return None

    try:
        parsed = urlparse(video_url.strip())
    except Exception:
        return None

    host = (parsed.netloc or "").lower()
    if host not in YOUTUBE_HOSTS:
        return None

    if host.endswith("youtu.be"):
        video_id = parsed.path.strip("/").split("/", 1)[0]
        return video_id or None

    path_parts = [part for part in parsed.path.split("/") if part]
    if parsed.path == "/watch":
        video_id = parse_qs(parsed.query).get("v", [None])[0]
        return video_id or None

    if len(path_parts) >= 2 and path_parts[0] in {"shorts", "embed", "live"}:
        return path_parts[1] or None

    return None


def _is_soundcloud_url(video_url: str | None) -> bool:
    if not video_url:
        return False

    try:
        parsed = urlparse(video_url.strip())
    except Exception:
        return False

    host = (parsed.netloc or "").lower()
    return host in SOUNDCLOUD_HOSTS or host.endswith(SOUNDCLOUD_HOST_SUFFIXES)


def _is_generic_url(video_url: str | None) -> bool:
    if not video_url:
        return False

    try:
        parsed = urlparse(video_url.strip())
    except Exception:
        return False

    return bool(parsed.scheme and parsed.netloc)


def _detect_media_source(video_url: str | None) -> dict[str, str]:
    if _extract_youtube_video_id(video_url):
        return {"key": "youtube", "label": "YouTube"}
    if _is_soundcloud_url(video_url):
        return {"key": "soundcloud", "label": "SoundCloud"}
    if _is_generic_url(video_url):
        return {"key": "link", "label": "Direct Link"}
    if str(video_url or "").strip():
        return {"key": "search", "label": "Search"}
    return {"key": "unknown", "label": "Unknown"}


def _derive_thumbnail_url(video_url: str | None) -> str | None:
    video_id = _extract_youtube_video_id(video_url)
    if not video_id:
        return None
    return f"https://i.ytimg.com/vi/{video_id}/hqdefault.jpg"


# Read-only view of the music-bot audio cache (mounted into the panel container). Lets the
# panel report what's cached and whether a track is playing locally vs streaming.
_AUDIO_CACHE_DIR = os.getenv("AUDIO_CACHE_PANEL_DIR", "/audiocache")
_AUDIO_CACHE_EXTS = ("opus", "ogg", "mp3")


def _is_track_cached(video_url: str | None) -> bool:
    vid = _extract_youtube_video_id(video_url)
    if not vid:
        return False
    for ext in _AUDIO_CACHE_EXTS:
        try:
            if os.path.getsize(os.path.join(_AUDIO_CACHE_DIR, f"{vid}.{ext}")) >= 8192:
                return True
        except OSError:
            continue
    return False


def _audio_cache_summary() -> dict[str, int]:
    files = 0
    total = 0
    try:
        with os.scandir(_AUDIO_CACHE_DIR) as it:
            for e in it:
                if e.name.startswith(".") or not e.name.endswith(_AUDIO_CACHE_EXTS):
                    continue
                try:
                    total += e.stat().st_size
                    files += 1
                except OSError:
                    continue
    except OSError:
        pass
    return {"files": files, "bytes": total}


def _smart_query_from_title(title: str | None) -> str:
    cleaned = re.sub(r"https?://\S+", "", str(title or ""))
    cleaned = SMART_TITLE_NOISE_RE.sub(" ", cleaned)
    cleaned = re.sub(r"\s+", " ", cleaned).strip(" -|")
    return cleaned[:180] or str(title or "").strip()[:180]
