"""Lumisound (iOS bridge companion app) admin dashboard data."""

import copy
import time
from typing import Any

import aiomysql

from .helpers import PANEL_IMAGE_GALLERY_ADMIN_CACHE_TTL_SECONDS
from .identifiers import _validate_identifier


class LumisoundMixin:
    async def get_lumisound_admin_data(self, limit: int = 50) -> dict[str, Any]:
        # The Lumisound iOS app's ios_* tables live in the same schema as the
        # GWS bot (DB_NAME=discord_music_gws for the ios-bridge service).
        schema = _validate_identifier(self.settings.db_default_schema, "lumisound schema")
        safe_limit = max(1, min(int(limit or 50), 200))
        now = time.monotonic()
        cached = self._lumisound_admin_cache.get(safe_limit)
        if cached and cached[0] > now:
            return copy.deepcopy(cached[1])
        if cached:
            self._lumisound_admin_cache.pop(safe_limit, None)
        pool = await self._get_pool()
        async with pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                summary: dict[str, Any] = {"schema": schema}
                for key, sql in (
                    ("users", f"SELECT COUNT(*) AS count FROM `{schema}`.`ios_users`"),
                    ("active_users", f"SELECT COUNT(*) AS count FROM `{schema}`.`ios_users` WHERE is_active=1"),
                    ("uploads", f"SELECT COUNT(*) AS count FROM `{schema}`.`ios_user_music_metadata`"),
                    ("play_history", f"SELECT COUNT(*) AS count FROM `{schema}`.`ios_play_history`"),
                    ("playlists", f"SELECT COUNT(*) AS count FROM `{schema}`.`ios_user_playlists`"),
                    ("bug_reports_open", f"SELECT COUNT(*) AS count FROM `{schema}`.`ios_bug_reports` WHERE status='open'"),
                    ("listen_rooms_active", f"SELECT COUNT(*) AS count FROM `{schema}`.`ios_listen_rooms` WHERE updated_at > NOW() - INTERVAL 1 HOUR"),
                    ("listening_now", f"SELECT COUNT(*) AS count FROM `{schema}`.`ios_playback_state` WHERE updated_at > NOW() - INTERVAL 15 MINUTE"),
                    ("plays_24h", f"SELECT COUNT(*) AS count FROM `{schema}`.`ios_play_history` WHERE played_at > NOW() - INTERVAL 1 DAY"),
                    ("uploads_storage_bytes", f"SELECT COALESCE(SUM(file_size_bytes), 0) AS count FROM `{schema}`.`ios_user_music_metadata`"),
                ):
                    await cur.execute(sql)
                    row = await cur.fetchone() or {}
                    summary[key] = int(row.get("count") or 0)

                await cur.execute(
                    f"""
                    SELECT u.id, u.username, u.display_name, u.email, u.created_at, u.last_login,
                           u.is_active, u.share_listening_activity,
                           COUNT(DISTINCT p.id) AS playlist_count,
                           COUNT(DISTINCT up.id) AS upload_count
                    FROM `{schema}`.`ios_users` u
                    LEFT JOIN `{schema}`.`ios_user_playlists` p ON p.user_id = u.id
                    LEFT JOIN `{schema}`.`ios_user_music_metadata` up ON up.user_id = u.id
                    GROUP BY u.id
                    ORDER BY u.created_at DESC
                    LIMIT %s
                    """,
                    (safe_limit,),
                )
                users = [self._json_row(row) for row in await cur.fetchall()]

                await cur.execute(
                    f"""
                    SELECT up.id, up.user_id, up.filename, up.title, up.artist, up.file_size_bytes, up.uploaded_at,
                           u.username
                    FROM `{schema}`.`ios_user_music_metadata` up
                    JOIN `{schema}`.`ios_users` u ON u.id = up.user_id
                    ORDER BY up.uploaded_at DESC
                    LIMIT %s
                    """,
                    (safe_limit,),
                )
                uploads = [self._json_row(row) for row in await cur.fetchall()]

                await cur.execute(
                    f"""
                    SELECT b.id, b.user_id, b.category, b.description, b.contact_email, b.app_version,
                           b.device_info, b.status, b.created_at, u.username
                    FROM `{schema}`.`ios_bug_reports` b
                    LEFT JOIN `{schema}`.`ios_users` u ON u.id = b.user_id
                    ORDER BY FIELD(b.status, 'open', 'resolved'), b.created_at DESC
                    LIMIT %s
                    """,
                    (safe_limit,),
                )
                bug_reports = [self._json_row(row) for row in await cur.fetchall()]

                await cur.execute(
                    f"""
                    SELECT r.id, r.host_user_id, r.room_code, r.title, r.artist, r.is_playing, r.updated_at,
                           u.username AS host_username
                    FROM `{schema}`.`ios_listen_rooms` r
                    JOIN `{schema}`.`ios_users` u ON u.id = r.host_user_id
                    WHERE r.updated_at > NOW() - INTERVAL 1 HOUR
                    ORDER BY r.updated_at DESC
                    LIMIT %s
                    """,
                    (safe_limit,),
                )
                listen_rooms = [self._json_row(row) for row in await cur.fetchall()]

                await cur.execute(
                    f"""
                    SELECT p.user_id, p.song_id, p.title, p.artist, p.source,
                           p.position_seconds, p.duration_seconds, p.updated_at,
                           u.username
                    FROM `{schema}`.`ios_playback_state` p
                    JOIN `{schema}`.`ios_users` u ON u.id = p.user_id
                    WHERE p.updated_at > NOW() - INTERVAL 15 MINUTE
                    ORDER BY p.updated_at DESC
                    LIMIT %s
                    """,
                    (safe_limit,),
                )
                now_playing = [self._json_row(row) for row in await cur.fetchall()]

                await cur.execute(
                    f"""
                    SELECT h.id, h.user_id, h.title, h.artist, h.played_at, h.listen_seconds,
                           u.username
                    FROM `{schema}`.`ios_play_history` h
                    JOIN `{schema}`.`ios_users` u ON u.id = h.user_id
                    ORDER BY h.played_at DESC
                    LIMIT %s
                    """,
                    (safe_limit,),
                )
                recent_plays = [self._json_row(row) for row in await cur.fetchall()]
        result = {
            "schema": schema,
            "summary": summary,
            "users": users,
            "uploads": uploads,
            "bug_reports": bug_reports,
            "listen_rooms": listen_rooms,
            "now_playing": now_playing,
            "recent_plays": recent_plays,
        }
        self._lumisound_admin_cache[safe_limit] = (time.monotonic() + PANEL_IMAGE_GALLERY_ADMIN_CACHE_TTL_SECONDS, copy.deepcopy(result))
        return result

