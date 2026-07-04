"""Music-bot control state, dashboard aggregation, queue management, and
music-intelligence methods. This is the largest domain — it owns everything
that talks to the per-bot Discord music schemas."""

import asyncio
import copy
import random
import time
from datetime import datetime, timezone
from typing import Any

import aiomysql

from ..bots import BOT_INDEX, BotDefinition, MUSIC_BOTS
from .helpers import (
    PANEL_DASHBOARD_CACHE_TTL_SECONDS,
    PANEL_DASHBOARD_SNAPSHOT_CONCURRENCY,
    PANEL_DB_POOL_MAX_SIZE,
    PANEL_DB_QUERY_TIMEOUT_SECONDS,
    PANEL_MUSIC_INTELLIGENCE_CACHE_TTL_SECONDS,
    PANEL_TABLE_CACHE_TTL_SECONDS,
    THUMBNAIL_CACHE_TTL_SECONDS,
    _audio_cache_summary,
    _coerce_int,
    _derive_session_state,
    _derive_thumbnail_url,
    _detect_media_source,
    _is_soundcloud_url,
    _is_track_cached,
    _normalize_filter_mode,
    _normalize_loop_mode,
    _smart_query_from_title,
    logger,
)
from .identifiers import _validate_identifier


class BotsMixin:
    def _empty_music_activity_summary(self) -> dict[str, Any]:
        return {
            "top_tracks": [],
            "top_bots": [],
            "active_sessions": [],
            "total_plays": 0,
            "learned_tracks": 0,
            "smart_likes": 0,
            "smart_dislikes": 0,
            "smart_recommendations": 0,
            "top_smart_tracks": [],
        }

    async def get_music_activity_summary_for_guilds(self, guild_ids: list[str | int]) -> dict[str, dict[str, Any]]:
        normalized_guilds = sorted({_coerce_int(guild_id, "guild_id") for guild_id in guild_ids if guild_id not in (None, "")})
        summaries = {str(guild_id): self._empty_music_activity_summary() for guild_id in normalized_guilds}
        if not normalized_guilds:
            return summaries

        cache_key = tuple(normalized_guilds)
        now = time.monotonic()
        cached = self._music_activity_cache.get(cache_key)
        if cached and cached[0] > now:
            return copy.deepcopy(cached[1])

        placeholders = ", ".join(["%s"] * len(normalized_guilds))
        per_guild_tracks: dict[int, dict[str, dict[str, Any]]] = {guild_id: {} for guild_id in normalized_guilds}
        per_guild_bots: dict[int, dict[str, int]] = {guild_id: {} for guild_id in normalized_guilds}
        per_guild_active: dict[int, list[dict[str, Any]]] = {guild_id: [] for guild_id in normalized_guilds}

        async def _collect_bot_activity(bot):
            if not bot.db_schema or not bot.table_prefix:
                return bot, [], []
            schema = _validate_identifier(bot.db_schema, "schema")
            prefix = _validate_identifier(bot.table_prefix, "table prefix")
            history_table = f"{prefix}_history"
            playback_table = f"{prefix}_playback_state"

            history_rows: list[dict[str, Any]] = []
            active_rows: list[dict[str, Any]] = []

            if await self._table_exists(schema, history_table):
                try:
                    history_rows = await self._fetchall(
                        f"""
                        SELECT guild_id, title, video_url, COUNT(*) AS plays, MAX(played_at) AS last_played_at
                        FROM `{schema}`.`{history_table}`
                        WHERE guild_id IN ({placeholders}) AND title IS NOT NULL AND title != ''
                        GROUP BY guild_id, title, video_url
                        ORDER BY plays DESC, last_played_at DESC
                        LIMIT 300
                        """,
                        tuple(normalized_guilds),
                    )
                except Exception as exc:
                    logger.debug("Could not read %s.%s for user directory: %s", schema, history_table, exc)

            if await self._table_exists(schema, playback_table):
                try:
                    active_rows = await self._fetchall(
                        f"""
                        SELECT guild_id, title, video_url, is_playing, is_paused
                        FROM `{schema}`.`{playback_table}`
                        WHERE guild_id IN ({placeholders}) AND (is_playing = 1 OR is_paused = 1)
                        """,
                        tuple(normalized_guilds),
                    )
                except Exception:
                    try:
                        active_rows = await self._fetchall(
                            f"""
                            SELECT guild_id, title, video_url, is_playing
                            FROM `{schema}`.`{playback_table}`
                            WHERE guild_id IN ({placeholders}) AND is_playing = 1
                            """,
                            tuple(normalized_guilds),
                        )
                    except Exception as exc:
                        logger.debug("Could not read %s.%s active state for user directory: %s", schema, playback_table, exc)
                        active_rows = []

            return bot, history_rows, active_rows

        for bot, history_rows, active_rows in await asyncio.gather(*(_collect_bot_activity(bot) for bot in MUSIC_BOTS)):
            for row in history_rows:
                guild_id = int(row["guild_id"])
                title = str(row.get("title") or "Unknown Track").strip()
                play_count = int(row.get("plays") or 0)
                key = title.lower()
                existing = per_guild_tracks[guild_id].setdefault(key, {
                    "title": title,
                    "video_url": row.get("video_url"),
                    "plays": 0,
                })
                existing["plays"] += play_count
                per_guild_bots[guild_id][bot.key] = per_guild_bots[guild_id].get(bot.key, 0) + play_count
            for row in active_rows:
                guild_id = int(row["guild_id"])
                per_guild_active[guild_id].append({
                    "bot_key": bot.key,
                    "bot_display": bot.display_name,
                    "title": row.get("title") or "Unknown Track",
                    "video_url": row.get("video_url"),
                    "is_playing": bool(row.get("is_playing")),
                    "is_paused": bool(row.get("is_paused")),
                })

        for guild_id in normalized_guilds:
            summaries[str(guild_id)]["total_plays"] = sum(per_guild_bots[guild_id].values())
            tracks = sorted(per_guild_tracks[guild_id].values(), key=lambda item: (-int(item["plays"]), item["title"].lower()))
            bots = sorted(per_guild_bots[guild_id].items(), key=lambda item: (-item[1], item[0]))
            summaries[str(guild_id)]["top_tracks"] = tracks[:3]
            summaries[str(guild_id)]["top_bots"] = [
                {
                    "bot_key": bot_key,
                    "bot_display": BOT_INDEX.get(bot_key).display_name if BOT_INDEX.get(bot_key) else bot_key,
                    "plays": plays,
                }
                for bot_key, plays in bots[:3]
            ]
            summaries[str(guild_id)]["active_sessions"] = per_guild_active[guild_id][:4]

        intelligence = await self.get_music_intelligence_summary(limit=3, guild_ids=normalized_guilds)
        for bot_summary in intelligence.get("bots", []):
            for guild_row in bot_summary.get("guilds", []):
                guild_id = str(guild_row.get("guild_id"))
                if guild_id not in summaries:
                    continue
                smart = summaries[guild_id]
                smart["learned_tracks"] += int(guild_row.get("learned_tracks") or 0)
                smart["smart_likes"] += int(guild_row.get("likes") or 0)
                smart["smart_dislikes"] += int(guild_row.get("dislikes") or 0)
                smart["smart_recommendations"] += int(guild_row.get("recommendations") or 0)
                for track in bot_summary.get("top_tracks", []):
                    if str(track.get("guild_id")) == guild_id:
                        smart["top_smart_tracks"].append({
                            "bot_key": bot_summary.get("bot_key"),
                            "bot_display": bot_summary.get("bot_display"),
                            "title": track.get("title"),
                            "smart_score": track.get("smart_score"),
                        })
        for summary in summaries.values():
            summary["top_smart_tracks"] = sorted(
                summary["top_smart_tracks"],
                key=lambda item: -float(item.get("smart_score") or 0),
            )[:3]

        self._music_activity_cache[cache_key] = (time.monotonic() + PANEL_MUSIC_INTELLIGENCE_CACHE_TTL_SECONDS, copy.deepcopy(summaries))
        return summaries

    async def get_music_intelligence_summary(
        self,
        guild_id: str | int | None = None,
        bot_key: str | None = None,
        limit: int = 8,
        guild_ids: list[int] | None = None,
    ) -> dict[str, Any]:
        safe_limit = max(1, min(int(limit or 8), 25))
        normalized_guild_id = _coerce_int(guild_id, "guild_id") if guild_id not in (None, "") else None
        normalized_guild_ids = sorted({int(gid) for gid in (guild_ids or [])})
        if normalized_guild_id is not None:
            normalized_guild_ids = [normalized_guild_id]
        normalized_bot_key = str(bot_key or "").strip().lower() or None
        if normalized_bot_key and normalized_bot_key not in BOT_INDEX:
            raise ValueError("Unknown bot key")
        bots = [BOT_INDEX[normalized_bot_key]] if normalized_bot_key else list(MUSIC_BOTS)

        cache_guild_key = ",".join(str(gid) for gid in normalized_guild_ids) if normalized_guild_ids else None
        cache_key = (cache_guild_key, normalized_bot_key, safe_limit)
        now = time.monotonic()
        cached = self._music_intelligence_cache.get(cache_key)
        if cached and cached[0] > now:
            return copy.deepcopy(cached[1])

        totals = {
            "learned_tracks": 0,
            "plays": 0,
            "finishes": 0,
            "skips": 0,
            "likes": 0,
            "dislikes": 0,
            "recommendations": 0,
        }
        result_bots: list[dict[str, Any]] = []

        async def _collect_bot_intelligence(bot):
            if bot.kind != "music" or not bot.db_schema or not bot.table_prefix:
                return None
            schema = _validate_identifier(bot.db_schema, "schema")
            prefix = _validate_identifier(bot.table_prefix, "table prefix")
            intelligence_table = f"{prefix}_track_intelligence"
            affinity_table = f"{prefix}_user_track_affinity"
            recommendations_table = f"{prefix}_smart_recommendations"
            if not await self._table_exists(schema, intelligence_table):
                return None

            where = ""
            params: tuple[Any, ...] = ()
            if normalized_guild_ids:
                placeholders = ", ".join(["%s"] * len(normalized_guild_ids))
                where = f"WHERE guild_id IN ({placeholders})"
                params = tuple(normalized_guild_ids)

            summary = await self._fetchone(
                f"""
                SELECT COUNT(*) AS learned_tracks,
                       COALESCE(SUM(play_count), 0) AS plays,
                       COALESCE(SUM(finish_count), 0) AS finishes,
                       COALESCE(SUM(skip_count), 0) AS skips,
                       COALESCE(SUM(like_count), 0) AS likes,
                       COALESCE(SUM(dislike_count), 0) AS dislikes
                FROM `{schema}`.`{intelligence_table}`
                {where}
                """,
                params,
            ) or {}
            top_tracks = await self._fetchall(
                f"""
                SELECT guild_id, title, video_url, play_count, finish_count, skip_count, like_count, dislike_count,
                       ((finish_count * 3) + (like_count * 5) + play_count - (skip_count * 2) - (dislike_count * 5)) AS smart_score,
                       updated_at
                FROM `{schema}`.`{intelligence_table}`
                {where}
                ORDER BY smart_score DESC, updated_at DESC
                LIMIT %s
                """,
                (*params, safe_limit),
            )

            guild_rows: list[dict[str, Any]] = []
            if normalized_guild_ids:
                guild_rows = await self._fetchall(
                    f"""
                    SELECT guild_id, COUNT(*) AS learned_tracks,
                           COALESCE(SUM(play_count), 0) AS plays,
                           COALESCE(SUM(like_count), 0) AS likes,
                           COALESCE(SUM(dislike_count), 0) AS dislikes
                    FROM `{schema}`.`{intelligence_table}`
                    {where}
                    GROUP BY guild_id
                    """,
                    params,
                )
            elif summary.get("learned_tracks"):
                guild_rows = await self._fetchall(
                    f"""
                    SELECT guild_id, COUNT(*) AS learned_tracks,
                           COALESCE(SUM(play_count), 0) AS plays,
                           COALESCE(SUM(like_count), 0) AS likes,
                           COALESCE(SUM(dislike_count), 0) AS dislikes
                    FROM `{schema}`.`{intelligence_table}`
                    GROUP BY guild_id
                    ORDER BY learned_tracks DESC
                    LIMIT %s
                    """,
                    (safe_limit,),
                )

            top_users: list[dict[str, Any]] = []
            if await self._table_exists(schema, affinity_table):
                top_users = await self._fetchall(
                    f"""
                    SELECT guild_id, user_id, COUNT(*) AS track_count, COALESCE(SUM(score), 0) AS taste_score,
                           COALESCE(SUM(like_count), 0) AS likes, COALESCE(SUM(dislike_count), 0) AS dislikes
                    FROM `{schema}`.`{affinity_table}`
                    {where}
                    GROUP BY guild_id, user_id
                    ORDER BY taste_score DESC, likes DESC
                    LIMIT %s
                    """,
                    (*params, safe_limit),
                )

            recommendation_count = 0
            if await self._table_exists(schema, recommendations_table):
                rec_row = await self._fetchone(
                    f"SELECT COUNT(*) AS recommendations FROM `{schema}`.`{recommendations_table}` {where}",
                    params,
                ) or {}
                recommendation_count = int(rec_row.get("recommendations") or 0)
                if guild_rows:
                    rec_rows = await self._fetchall(
                        f"SELECT guild_id, COUNT(*) AS recommendations FROM `{schema}`.`{recommendations_table}` {where} GROUP BY guild_id",
                        params,
                    )
                    rec_map = {int(row["guild_id"]): int(row.get("recommendations") or 0) for row in rec_rows}
                    for row in guild_rows:
                        row["recommendations"] = rec_map.get(int(row["guild_id"]), 0)

            return {
                "bot_key": bot.key,
                "bot_display": bot.display_name,
                "schema": schema,
                "learned_tracks": int(summary.get("learned_tracks") or 0),
                "plays": int(summary.get("plays") or 0),
                "finishes": int(summary.get("finishes") or 0),
                "skips": int(summary.get("skips") or 0),
                "likes": int(summary.get("likes") or 0),
                "dislikes": int(summary.get("dislikes") or 0),
                "recommendations": recommendation_count,
                "top_tracks": top_tracks,
                "top_users": top_users,
                "guilds": guild_rows,
            }

        for item in await asyncio.gather(*(_collect_bot_intelligence(bot) for bot in bots)):
            if item is None:
                continue
            result_bots.append(item)
            totals["learned_tracks"] += item["learned_tracks"]
            totals["plays"] += item["plays"]
            totals["finishes"] += item["finishes"]
            totals["skips"] += item["skips"]
            totals["likes"] += item["likes"]
            totals["dislikes"] += item["dislikes"]
            totals["recommendations"] += item["recommendations"]

        result = {
            "guild_id": str(normalized_guild_id) if normalized_guild_id is not None else None,
            "guild_ids": [str(gid) for gid in normalized_guild_ids],
            "bot_key": normalized_bot_key,
            "totals": totals,
            "bots": result_bots,
            "generated_at": datetime.now(timezone.utc).isoformat(),
        }
        self._music_intelligence_cache[cache_key] = (time.monotonic() + PANEL_MUSIC_INTELLIGENCE_CACHE_TTL_SECONDS, copy.deepcopy(result))
        return result

    async def _resolve_soundcloud_thumbnail(self, video_url: str | None) -> str | None:
        if not _is_soundcloud_url(video_url):
            return None

        normalized_url = str(video_url or "").strip()
        if not normalized_url:
            return None

        now = time.time()
        cached = self.thumbnail_cache.get(normalized_url)
        if cached and cached[0] > now:
            return cached[1]

        thumbnail: str | None = None
        if self.http_session:
            try:
                async with self.http_session.get(
                    "https://soundcloud.com/oembed",
                    params={"format": "json", "url": normalized_url},
                ) as resp:
                    if resp.ok:
                        payload = await resp.json()
                        raw_thumbnail = payload.get("thumbnail_url")
                        if raw_thumbnail:
                            thumbnail = str(raw_thumbnail).strip() or None
            except Exception:
                thumbnail = None

        self.thumbnail_cache[normalized_url] = (now + THUMBNAIL_CACHE_TTL_SECONDS, thumbnail)
        return thumbnail

    async def _get_thumbnail_url(self, video_url: str | None) -> str | None:
        youtube_thumbnail = _derive_thumbnail_url(video_url)
        if youtube_thumbnail:
            return youtube_thumbnail
        return await self._resolve_soundcloud_thumbnail(video_url)

    async def get_known_guild_ids(self, bot_key: str) -> list[int]:
        bot = BOT_INDEX.get(bot_key)
        if not bot or bot.kind != "music" or not bot.db_schema or not bot.table_prefix:
            return []

        schema = _validate_identifier(bot.db_schema, "schema")
        prefix = _validate_identifier(bot.table_prefix, "table prefix")
        tables = [f"{prefix}_playback_state", f"{prefix}_guild_settings", f"{prefix}_queue", f"{prefix}_bot_home_channels"]
        guild_ids: set[int] = set()

        for table in tables:
            if not await self._table_exists(schema, table):
                continue
            rows = await self._fetchall(f"SELECT DISTINCT guild_id FROM `{schema}`.`{table}`")
            for row in rows:
                guild_id = row.get("guild_id")
                if guild_id is not None:
                    guild_ids.add(int(guild_id))

        return sorted(guild_ids)

    async def get_bot_control_state(self, bot_key: str, guild_id: str | int) -> dict[str, Any]:
        bot = BOT_INDEX.get(bot_key)
        if not bot or bot.kind != "music" or not bot.db_schema or not bot.table_prefix:
            raise ValueError("This action is only supported for music bots")

        gid = _coerce_int(guild_id, "guild_id")
        schema = _validate_identifier(bot.db_schema, "schema")
        prefix = _validate_identifier(bot.table_prefix, "table prefix")
        playback_table = f"{prefix}_playback_state"
        settings_table = f"{prefix}_guild_settings"
        queue_table = f"{prefix}_queue"
        backup_table = f"{prefix}_queue_backup"
        home_table = f"{prefix}_bot_home_channels"
        direct_orders_table = f"{prefix}_swarm_direct_orders"
        heartbeat_table = "swarm_health"
        metrics_table = f"{prefix}_metrics"
        intelligence_table = f"{prefix}_track_intelligence"
        affinity_table = f"{prefix}_user_track_affinity"
        recommendations_table = f"{prefix}_smart_recommendations"

        table_exists = {
            "playback": await self._table_exists(schema, playback_table),
            "settings": await self._table_exists(schema, settings_table),
            "queue": await self._table_exists(schema, queue_table),
            "backup": await self._table_exists(schema, backup_table),
            "home": await self._table_exists(schema, home_table),
            "direct_orders": await self._table_exists(schema, direct_orders_table),
            "heartbeat": await self._table_exists(schema, heartbeat_table),
            "metrics": await self._table_exists(schema, metrics_table),
            "intelligence": await self._table_exists(schema, intelligence_table),
            "affinity": await self._table_exists(schema, affinity_table),
            "recommendations": await self._table_exists(schema, recommendations_table),
        }

        playback: dict[str, Any] = {}
        settings: dict[str, Any] = {}
        queue_count = 0
        backup_queue_count = 0
        backup_queue_preview: list[dict[str, Any]] = []
        pending_direct_orders = 0
        latest_direct_order: dict[str, Any] | None = None
        home_channel_id: int | None = None
        feedback_channel_id: int | None = None
        heartbeat_age = None
        heartbeat_status = "unknown"
        metric: dict[str, Any] = {}
        intelligence = {
            "learned_tracks": 0,
            "plays": 0,
            "likes": 0,
            "dislikes": 0,
            "recommendations": 0,
            "top_seed": None,
            "top_user": None,
        }

        if table_exists["playback"]:
            try:
                playback = await self._fetchone(
                    f"SELECT * "
                    f"FROM `{schema}`.`{playback_table}` WHERE guild_id = %s AND bot_name = %s LIMIT 1",
                    (gid, bot.key),
                ) or {}
            except Exception:
                playback = await self._fetchone(
                    f"SELECT * "
                    f"FROM `{schema}`.`{playback_table}` WHERE guild_id = %s LIMIT 1",
                    (gid,),
                ) or {}

        if table_exists["settings"]:
            settings = await self._fetchone(
                f"SELECT volume, loop_mode, filter_mode, feedback_channel_id, transition_mode, "
                f"fade_seconds, fade_curve, custom_speed, custom_pitch, custom_modifiers_left, dj_only_mode, stay_in_vc "
                f"FROM `{schema}`.`{settings_table}` WHERE guild_id = %s LIMIT 1",
                (gid,),
            ) or {}
            feedback_channel_id = int(settings["feedback_channel_id"]) if settings.get("feedback_channel_id") else None

        if table_exists["queue"]:
            try:
                row = await self._fetchone(
                    f"SELECT COUNT(*) AS queue_count FROM `{schema}`.`{queue_table}` WHERE guild_id = %s AND bot_name = %s",
                    (gid, bot.key),
                ) or {}
            except Exception:
                row = await self._fetchone(
                    f"SELECT COUNT(*) AS queue_count FROM `{schema}`.`{queue_table}` WHERE guild_id = %s",
                    (gid,),
                ) or {}
            queue_count = int(row.get("queue_count") or 0)

        if table_exists["backup"]:
            try:
                row = await self._fetchone(
                    f"SELECT COUNT(*) AS backup_queue_count FROM `{schema}`.`{backup_table}` WHERE guild_id = %s AND bot_name = %s",
                    (gid, bot.key),
                ) or {}
            except Exception:
                row = await self._fetchone(
                    f"SELECT COUNT(*) AS backup_queue_count FROM `{schema}`.`{backup_table}` WHERE guild_id = %s",
                    (gid,),
                ) or {}
            backup_queue_count = int(row.get("backup_queue_count") or 0)
            try:
                backup_queue_preview = await self._fetchall(
                    f"SELECT title, video_url, requester_id FROM `{schema}`.`{backup_table}` "
                    f"WHERE guild_id = %s AND bot_name = %s ORDER BY id ASC LIMIT 8",
                    (gid, bot.key),
                )
            except Exception:
                backup_queue_preview = await self._fetchall(
                    f"SELECT title, video_url, requester_id FROM `{schema}`.`{backup_table}` "
                    f"WHERE guild_id = %s ORDER BY id ASC LIMIT 8",
                    (gid,),
                )

        if table_exists["home"]:
            try:
                row = await self._fetchone(
                    f"SELECT home_vc_id FROM `{schema}`.`{home_table}` WHERE guild_id = %s AND bot_name = %s LIMIT 1",
                    (gid, bot.key),
                ) or {}
            except Exception:
                row = await self._fetchone(
                    f"SELECT home_vc_id FROM `{schema}`.`{home_table}` WHERE guild_id = %s LIMIT 1",
                    (gid,),
                ) or {}
            home_channel_id = int(row["home_vc_id"]) if row.get("home_vc_id") else None

        if table_exists["direct_orders"]:
            try:
                row = await self._fetchone(
                    f"SELECT COUNT(*) AS pending_direct_orders FROM `{schema}`.`{direct_orders_table}` WHERE guild_id = %s AND bot_name = %s",
                    (gid, bot.key),
                ) or {}
            except Exception:
                row = await self._fetchone(
                    f"SELECT COUNT(*) AS pending_direct_orders FROM `{schema}`.`{direct_orders_table}` WHERE guild_id = %s",
                    (gid,),
                ) or {}
            pending_direct_orders = int(row.get("pending_direct_orders") or 0)
            try:
                latest_direct_order = await self._fetchone(
                    f"SELECT command, data, vc_id, text_channel_id "
                    f"FROM `{schema}`.`{direct_orders_table}` WHERE guild_id = %s AND bot_name = %s "
                    f"ORDER BY id DESC LIMIT 1",
                    (gid, bot.key),
                ) or None
            except Exception:
                try:
                    latest_direct_order = await self._fetchone(
                        f"SELECT command, data, vc_id, text_channel_id "
                        f"FROM `{schema}`.`{direct_orders_table}` WHERE guild_id = %s "
                        f"ORDER BY id DESC LIMIT 1",
                        (gid,),
                    ) or None
                except Exception:
                    latest_direct_order = await self._fetchone(
                        f"SELECT command, data, vc_id "
                        f"FROM `{schema}`.`{direct_orders_table}` WHERE guild_id = %s "
                        f"ORDER BY id DESC LIMIT 1",
                        (gid,),
                    ) or None

        if table_exists["heartbeat"]:
            row = await self._fetchone(
                f"SELECT status, TIMESTAMPDIFF(SECOND, last_pulse, NOW()) AS heartbeat_age "
                f"FROM `{schema}`.`{heartbeat_table}` WHERE bot_name = %s LIMIT 1",
                (bot.key,),
            ) or {}
            if row:
                heartbeat_age = int(row.get("heartbeat_age") or 0)
                heartbeat_status = row.get("status") or "unknown"

        if table_exists["metrics"]:
            try:
                metric = await self._fetchone(
                    f"SELECT *, TIMESTAMPDIFF(SECOND, updated_at, NOW()) AS metric_age_seconds "
                    f"FROM `{schema}`.`{metrics_table}` WHERE guild_id = %s AND bot_name = %s LIMIT 1",
                    (gid, bot.key),
                ) or {}
            except Exception:
                metric = await self._fetchone(
                    f"SELECT *, TIMESTAMPDIFF(SECOND, updated_at, NOW()) AS metric_age_seconds "
                    f"FROM `{schema}`.`{metrics_table}` WHERE guild_id = %s LIMIT 1",
                    (gid,),
                ) or {}

        if table_exists["intelligence"]:
            row = await self._fetchone(
                f"""
                SELECT COUNT(*) AS learned_tracks,
                       COALESCE(SUM(play_count), 0) AS plays,
                       COALESCE(SUM(like_count), 0) AS likes,
                       COALESCE(SUM(dislike_count), 0) AS dislikes
                FROM `{schema}`.`{intelligence_table}`
                WHERE guild_id = %s
                """,
                (gid,),
            ) or {}
            intelligence.update({
                "learned_tracks": int(row.get("learned_tracks") or 0),
                "plays": int(row.get("plays") or 0),
                "likes": int(row.get("likes") or 0),
                "dislikes": int(row.get("dislikes") or 0),
            })
            top_seed = await self._fetchone(
                f"""
                SELECT title, video_url,
                       ((finish_count * 3) + (like_count * 5) + play_count - (skip_count * 2) - (dislike_count * 5)) AS smart_score
                FROM `{schema}`.`{intelligence_table}`
                WHERE guild_id = %s AND dislike_count <= like_count
                ORDER BY smart_score DESC, updated_at DESC
                LIMIT 1
                """,
                (gid,),
            )
            if top_seed:
                intelligence["top_seed"] = top_seed

        if table_exists["affinity"]:
            top_user = await self._fetchone(
                f"""
                SELECT user_id, COUNT(*) AS track_count, COALESCE(SUM(score), 0) AS taste_score,
                       COALESCE(SUM(like_count), 0) AS likes, COALESCE(SUM(dislike_count), 0) AS dislikes
                FROM `{schema}`.`{affinity_table}`
                WHERE guild_id = %s
                GROUP BY user_id
                ORDER BY taste_score DESC, likes DESC
                LIMIT 1
                """,
                (gid,),
            )
            if top_user:
                intelligence["top_user"] = top_user

        if table_exists["recommendations"]:
            row = await self._fetchone(
                f"SELECT COUNT(*) AS recommendations FROM `{schema}`.`{recommendations_table}` WHERE guild_id = %s",
                (gid,),
            ) or {}
            intelligence["recommendations"] = int(row.get("recommendations") or 0)

        metric_fresh = int(metric.get("metric_age_seconds") or 999999) <= 90 if metric else False
        is_playing = bool(metric.get("player_playing")) if metric_fresh else bool(playback.get("is_playing"))
        is_paused = bool(metric.get("player_paused")) if metric_fresh else bool(playback.get("is_paused"))
        effective_channel_id = metric.get("connected_channel_id") if metric_fresh and metric.get("connected_channel_id") else playback.get("channel_id")
        effective_position = int(metric.get("position_seconds") or playback.get("position_seconds") or 0)
        effective_duration = int(
            metric.get("duration_seconds")
            or metric.get("track_length_seconds")
            or playback.get("duration_seconds")
            or playback.get("length_seconds")
            or playback.get("track_length_seconds")
            or 0
        )
        observed_at = metric.get("updated_at") if metric_fresh and metric.get("updated_at") else playback.get("updated_at")
        effective_playback = {
            **playback,
            "is_playing": is_playing,
            "is_paused": is_paused,
            "channel_id": effective_channel_id,
        }

        session_state, session_state_label = _derive_session_state(
            effective_playback,
            queue_count=queue_count,
            has_settings=bool(settings),
            home_channel_id=home_channel_id,
            backup_queue_count=backup_queue_count,
        )

        backup_restore_ready = bool(
            backup_queue_count > 0
            and home_channel_id
            and (
                queue_count == 0
                or not bool(is_playing)
                or session_state in {"recovering", "configured", "idle"}
            )
        )
        if backup_queue_count <= 0:
            backup_restore_reason = "No backup queue entries are stored for this guild."
        elif not home_channel_id:
            backup_restore_reason = "Backup queue exists, but no home channel is set for auto-restore."
        elif bool(is_playing) and queue_count > 0:
            backup_restore_reason = "Live playback/queue is already active, so backup restore is standing by."
        elif queue_count > 0:
            backup_restore_reason = "Live queue already contains items, so backup restore is waiting for an empty queue."
        else:
            backup_restore_reason = "Backup queue is armed and should restore this guild automatically if playback stalls."

        return {
            "key": bot.key,
            "display_name": bot.display_name,
            "guild_id": str(gid),
            "db": {
                "status": "online",
                "reachable": True,
                "message": "Live bot schema query succeeded.",
                "schema": schema,
            },
            "heartbeat": {
                "status": heartbeat_status,
                "age_seconds": heartbeat_age,
            },
            "session": {
                "guild_id": str(gid),
                "guild_name": None,
                "channel_id": str(effective_channel_id) if effective_channel_id else None,
                "channel_name": None,
                "title": playback.get("title"),
                "video_url": playback.get("video_url"),
                "position_seconds": effective_position,
                "duration_seconds": effective_duration,
                "position_observed_at": observed_at.isoformat() if hasattr(observed_at, "isoformat") else None,
                "is_playing": is_playing,
                "is_paused": is_paused,
                "session_state": session_state,
                "session_state_label": session_state_label,
                "volume": int(settings.get("volume") or 100),
                "loop_mode": settings.get("loop_mode") or "queue",
                "filter_mode": settings.get("filter_mode") or "none",
                "transition_mode": settings.get("transition_mode") or "off",
                "fade_seconds": float(settings.get("fade_seconds") or 5.0),
                "fade_curve": settings.get("fade_curve") or "linear",
                "custom_speed": float(settings.get("custom_speed") or 1.0),
                "custom_pitch": float(settings.get("custom_pitch") or 1.0),
                "custom_modifiers_left": int(settings.get("custom_modifiers_left") or 0),
                "dj_only_mode": bool(settings.get("dj_only_mode")),
                "stay_in_vc": bool(settings.get("stay_in_vc")),
                "queue_count": queue_count,
                "backup_queue_count": backup_queue_count,
                "backup_queue_preview": backup_queue_preview,
                "backup_restore_ready": backup_restore_ready,
                "backup_restore_reason": backup_restore_reason,
                "pending_direct_orders": pending_direct_orders,
                "latest_direct_order": latest_direct_order,
                "home_channel_id": str(home_channel_id) if home_channel_id else None,
                "home_channel_name": None,
                "feedback_channel_id": str(feedback_channel_id) if feedback_channel_id else None,
                "feedback_channel_name": None,
                "intelligence": intelligence,
            },
        }

    async def _batch_table_exists(self, schema: str, table_names: list[str]) -> dict[str, bool]:
        """Check existence of multiple tables in one information_schema query.

        Uses the TTL cache per table so repeated calls within the cache window are free.
        Returns a mapping of table_name -> bool.
        """
        schema = _validate_identifier(schema, "schema")
        now = time.monotonic()
        result: dict[str, bool] = {}
        missing: list[str] = []
        for table in table_names:
            key = (schema, table)
            cached = self._table_exists_cache.get(key)
            if cached and cached[0] > now:
                result[table] = bool(cached[1])
            else:
                missing.append(table)
        if missing:
            placeholders = ", ".join(["%s"] * len(missing))
            rows = await self._fetchall(
                f"""
                SELECT table_name
                FROM information_schema.tables
                WHERE table_schema = %s AND table_name IN ({placeholders})
                """,
                (schema, *missing),
                dict_cursor=False,
            )
            found = {row[0] for row in rows}
            for table in missing:
                exists = table in found
                self._table_exists_cache[(schema, table)] = (now + PANEL_TABLE_CACHE_TTL_SECONDS, exists)
                result[table] = exists
        return result

    async def _music_bot_snapshot(self, bot: BotDefinition) -> dict[str, Any]:
        assert bot.db_schema and bot.table_prefix
        schema = _validate_identifier(bot.db_schema, "schema")
        prefix = _validate_identifier(bot.table_prefix, "table prefix")
        playback_table = f"{prefix}_playback_state"
        settings_table = f"{prefix}_guild_settings"
        queue_table = f"{prefix}_queue"
        backup_table = f"{prefix}_queue_backup"
        home_table = f"{prefix}_bot_home_channels"
        heartbeat_table = "swarm_health"
        metrics_table = f"{prefix}_metrics"
        intelligence_table = f"{prefix}_track_intelligence"
        recommendations_table = f"{prefix}_smart_recommendations"

        # Batch all table-existence checks into a single information_schema query
        # instead of 9 sequential round-trips.
        _table_names = [
            playback_table, settings_table, queue_table, backup_table,
            home_table, heartbeat_table, metrics_table, intelligence_table, recommendations_table,
        ]
        _exists = await self._batch_table_exists(schema, _table_names)
        table_exists = {
            "playback": _exists.get(playback_table, False),
            "settings": _exists.get(settings_table, False),
            "queue": _exists.get(queue_table, False),
            "backup": _exists.get(backup_table, False),
            "home": _exists.get(home_table, False),
            "heartbeat": _exists.get(heartbeat_table, False),
            "metrics": _exists.get(metrics_table, False),
            "intelligence": _exists.get(intelligence_table, False),
            "recommendations": _exists.get(recommendations_table, False),
        }

        playback_rows: list[dict[str, Any]] = []
        filter_map: dict[int, dict[str, Any]] = {}
        queue_map: dict[int, int] = {}
        backup_queue_map: dict[int, int] = {}
        home_map: dict[int, int | None] = {}
        metrics_map: dict[int, dict[str, Any]] = {}
        intelligence_map: dict[int, dict[str, Any]] = {}
        recommendation_map: dict[int, int] = {}
        known_guilds: set[int] = set()

        if table_exists["playback"]:
            try:
                playback_rows = await self._fetchall(
                    f"SELECT * FROM `{schema}`.`{playback_table}` ORDER BY guild_id LIMIT 500"
                )
            except Exception:
                playback_rows = []
            for row in playback_rows:
                guild_id = row.get("guild_id")
                if guild_id is not None:
                    known_guilds.add(int(guild_id))

        if table_exists["settings"]:
            rows = await self._fetchall(
                f"SELECT guild_id, filter_mode, loop_mode, transition_mode, fade_seconds, fade_curve "
                f"FROM `{schema}`.`{settings_table}` LIMIT 500"
            )
            for row in rows:
                guild_id = int(row["guild_id"])
                filter_map[guild_id] = {
                    "filter_mode": row.get("filter_mode") or "none",
                    "loop_mode": row.get("loop_mode") or "queue",
                    "transition_mode": row.get("transition_mode") or "off",
                    "fade_seconds": float(row.get("fade_seconds") or 5.0),
                    "fade_curve": row.get("fade_curve") or "linear",
                }
                known_guilds.add(guild_id)

        if table_exists["queue"]:
            try:
                rows = await self._fetchall(
                    f"SELECT guild_id, COUNT(*) AS queue_len FROM `{schema}`.`{queue_table}` WHERE bot_name = %s GROUP BY guild_id",
                    (bot.key,),
                )
            except Exception:
                rows = await self._fetchall(
                    f"SELECT guild_id, COUNT(*) AS queue_len FROM `{schema}`.`{queue_table}` GROUP BY guild_id"
                )
            for row in rows:
                guild_id = int(row["guild_id"])
                queue_map[guild_id] = int(row.get("queue_len") or 0)
                known_guilds.add(guild_id)

        if table_exists["backup"]:
            try:
                rows = await self._fetchall(
                    f"SELECT guild_id, COUNT(*) AS backup_len FROM `{schema}`.`{backup_table}` WHERE bot_name = %s GROUP BY guild_id",
                    (bot.key,),
                )
            except Exception:
                rows = await self._fetchall(
                    f"SELECT guild_id, COUNT(*) AS backup_len FROM `{schema}`.`{backup_table}` GROUP BY guild_id"
                )
            for row in rows:
                guild_id = int(row["guild_id"])
                backup_queue_map[guild_id] = int(row.get("backup_len") or 0)

        if table_exists["home"]:
            rows = await self._fetchall(
                f"SELECT guild_id, home_vc_id FROM `{schema}`.`{home_table}` WHERE bot_name = %s LIMIT 500",
                (bot.key,),
            )
            for row in rows:
                guild_id = int(row["guild_id"])
                home_map[guild_id] = int(row["home_vc_id"]) if row.get("home_vc_id") else None
                known_guilds.add(guild_id)

        if table_exists.get("metrics"):
            try:
                rows = await self._fetchall(
                    f"SELECT *, TIMESTAMPDIFF(SECOND, updated_at, NOW()) AS metric_age_seconds "
                    f"FROM `{schema}`.`{metrics_table}` WHERE bot_name = %s LIMIT 500",
                    (bot.key,),
                )
                for row in rows:
                    guild_id = int(row["guild_id"])
                    metrics_map[guild_id] = row
                    known_guilds.add(guild_id)
            except Exception:
                logger.exception("Failed reading metrics for %s", bot.key)

        if table_exists.get("intelligence"):
            try:
                rows = await self._fetchall(
                    f"""
                    SELECT guild_id, COUNT(*) AS learned_tracks,
                           COALESCE(SUM(play_count), 0) AS plays,
                           COALESCE(SUM(like_count), 0) AS likes,
                           COALESCE(SUM(dislike_count), 0) AS dislikes
                    FROM `{schema}`.`{intelligence_table}`
                    GROUP BY guild_id
                    LIMIT 500
                    """
                )
                for row in rows:
                    guild_id = int(row["guild_id"])
                    intelligence_map[guild_id] = {
                        "learned_tracks": int(row.get("learned_tracks") or 0),
                        "plays": int(row.get("plays") or 0),
                        "likes": int(row.get("likes") or 0),
                        "dislikes": int(row.get("dislikes") or 0),
                    }
                    known_guilds.add(guild_id)
            except Exception:
                logger.exception("Failed reading music intelligence for %s", bot.key)

        if table_exists.get("recommendations"):
            try:
                rows = await self._fetchall(
                    f"SELECT guild_id, COUNT(*) AS recommendations FROM `{schema}`.`{recommendations_table}` GROUP BY guild_id LIMIT 500"
                )
                for row in rows:
                    recommendation_map[int(row["guild_id"])] = int(row.get("recommendations") or 0)
            except Exception:
                logger.exception("Failed reading smart recommendations for %s", bot.key)

        playback_map = {int(row["guild_id"]): row for row in playback_rows if row.get("guild_id") is not None}
        sessions = []
        active_playing_count = 0
        sorted_guild_ids = sorted(known_guilds)

        for guild_id in sorted_guild_ids:
            playback = playback_map.get(guild_id, {})
            metric = metrics_map.get(guild_id, {})
            settings = filter_map.get(guild_id, {})
            queue_count = queue_map.get(guild_id, 0)
            backup_queue_count = backup_queue_map.get(guild_id, 0)
            home_channel_id = home_map.get(guild_id)
            smart = dict(intelligence_map.get(guild_id, {}))
            smart["recommendations"] = recommendation_map.get(guild_id, 0)
            source_info = _detect_media_source(playback.get("video_url"))
            track_cached = _is_track_cached(playback.get("video_url"))
            metric_fresh = int(metric.get("metric_age_seconds") or 999999) <= 90 if metric else False
            is_playing = bool(metric.get("player_playing")) if metric_fresh else bool(playback.get("is_playing"))
            is_paused = bool(metric.get("player_paused")) if metric_fresh else bool(playback.get("is_paused"))
            effective_channel_id = metric.get("connected_channel_id") if metric_fresh and metric.get("connected_channel_id") else playback.get("channel_id")
            effective_position = int(metric.get("position_seconds") or playback.get("position_seconds") or 0)
            effective_duration = int(
                metric.get("duration_seconds")
                or metric.get("track_length_seconds")
                or playback.get("duration_seconds")
                or playback.get("length_seconds")
                or playback.get("track_length_seconds")
                or 0
            )
            observed_at = metric.get("updated_at") if metric_fresh and metric.get("updated_at") else playback.get("updated_at")
            effective_playback = {**playback, "is_playing": is_playing, "is_paused": is_paused, "channel_id": effective_channel_id}
            session_state, session_state_label = _derive_session_state(
                effective_playback,
                queue_count=queue_count,
                has_settings=guild_id in filter_map,
                home_channel_id=home_channel_id,
                backup_queue_count=backup_queue_count,
            )
            if is_playing:
                active_playing_count += 1
            sessions.append(
                {
                    "guild_id": str(guild_id),
                    "channel_id": str(effective_channel_id) if effective_channel_id else None,
                    "title": playback.get("title"),
                    "video_url": playback.get("video_url"),
                    "media_source": source_info["key"],
                    "media_source_label": source_info["label"],
                    "cached": track_cached,
                    "playback_source": (("local" if track_cached else "stream") if is_playing else None),
                    "playback_source_label": (("Local cache" if track_cached else "Streaming") if is_playing else None),
                    "thumbnail": None,
                    "position_seconds": effective_position,
                    "duration_seconds": effective_duration,
                    "position_observed_at": observed_at.isoformat() if hasattr(observed_at, "isoformat") else None,
                    "is_playing": is_playing,
                    "is_paused": is_paused,
                    "metric_age_seconds": int(metric.get("metric_age_seconds") or -1) if metric else None,
                    "session_state": session_state,
                    "session_state_label": session_state_label,
                    "filter_mode": settings.get("filter_mode", "none"),
                    "loop_mode": settings.get("loop_mode", "queue"),
                    "transition_mode": settings.get("transition_mode", "off"),
                    "fade_seconds": settings.get("fade_seconds", 5.0),
                    "fade_curve": settings.get("fade_curve", "linear"),
                    "queue_count": queue_count,
                    "backup_queue_count": backup_queue_count,
                    "backup_restore_ready": bool(backup_queue_count > 0 and session_state in {"recovering", "queued", "configured", "idle", "paused"}),
                    "backup_restore_reason": "Backup queue is armed when the live queue or playback path goes idle." if backup_queue_count > 0 else "No backup queue entries are stored for this guild.",
                    "home_channel_id": str(home_channel_id) if home_channel_id else None,
                    "home_channel_name": None,
                    "guild_name": None,
                    "channel_name": None,
                    "intelligence": smart,
                }
            )

        if sessions:
            thumbnails = await asyncio.gather(
                *(self._get_thumbnail_url(session.get("video_url")) for session in sessions),
                return_exceptions=True,
            )
            for session, thumbnail in zip(sessions, thumbnails):
                session["thumbnail"] = None if isinstance(thumbnail, Exception) else thumbnail

        heartbeat_age = None
        heartbeat_status = "unknown"
        if table_exists["heartbeat"]:
            row = await self._fetchone(
                f"SELECT status, TIMESTAMPDIFF(SECOND, last_pulse, NOW()) AS heartbeat_age FROM `{schema}`.`{heartbeat_table}` WHERE bot_name = %s LIMIT 1",
                (bot.key,),
            )
            if row:
                heartbeat_age = int(row.get("heartbeat_age") or 0)
                heartbeat_status = row.get("status") or "unknown"

        node_status = "unknown" if heartbeat_age is None else ("online" if heartbeat_age <= 120 else "stale")

        return {
            "key": bot.key,
            "display_name": bot.display_name,
            "kind": bot.kind,
            "schema": schema,
            "status": node_status,
            "heartbeat_age_seconds": heartbeat_age,
            "heartbeat_status": heartbeat_status,
            "active_playing_count": active_playing_count,
            "known_guild_count": len(known_guilds),
            "queue_depth": sum(int(item.get("queue_count") or 0) for item in sessions),
            "backup_queue_depth": sum(int(item.get("backup_queue_count") or 0) for item in sessions),
            "learned_track_count": sum(int(item.get("learned_tracks") or 0) for item in intelligence_map.values()),
            "smart_recommendation_count": sum(recommendation_map.values()),
            "local_playing_count": sum(1 for item in sessions if item.get("playback_source") == "local"),
            "audio_cache": _audio_cache_summary(),
            "sessions": sessions,
        }

    async def get_dashboard_data(self) -> dict[str, Any]:
        now = time.monotonic()
        if self._dashboard_cache and self._dashboard_cache[0] > now:
            return copy.deepcopy(self._dashboard_cache[1])
        await self._get_pool()  # ensures pool is initialized before spawning concurrent snapshots
        snapshot_limit = min(PANEL_DASHBOARD_SNAPSHOT_CONCURRENCY, max(1, PANEL_DB_POOL_MAX_SIZE))
        semaphore = asyncio.Semaphore(snapshot_limit)

        async def collect_music_snapshot(bot: BotDefinition) -> dict[str, Any]:
            async with semaphore:
                try:
                    return await self._music_bot_snapshot(bot)
                except Exception as exc:
                    logger.exception("Failed collecting snapshot for %s", bot.key)
                    return {
                        "key": bot.key,
                        "display_name": bot.display_name,
                        "kind": bot.kind,
                        "schema": bot.db_schema,
                        "status": "error",
                        "error": str(exc),
                        "heartbeat_age_seconds": None,
                        "heartbeat_status": "unknown",
                        "active_playing_count": 0,
                        "known_guild_count": 0,
                        "sessions": [],
                    }

        bots = []
        for bot_snapshot in await asyncio.gather(*(collect_music_snapshot(bot) for bot in MUSIC_BOTS)):
            try:
                bots.append(bot_snapshot)
            except Exception:
                logger.exception("Unexpected error handling dashboard snapshot result.")

        total_active = sum(int(bot.get("active_playing_count") or 0) for bot in bots)
        aria_recent_interactions: list[dict[str, Any]] = []
        aria_recent_interaction_count = 0
        aria_medic_summary: dict[str, Any] = {
            "pending_repairs": 0,
            "pending_infra": 0,
            "critical_health": 0,
            "recoverable_health": 0,
            "recent_operator_decisions": [],
            "recent_infra_history": [],
            "recent_swarm_events": [],
        }
        # Authentic Database Query for Aria
        aria_heartbeat_age = None
        aria_heartbeat_status = "n/a"
        try:
            pool = await self._get_pool()
            async with pool.acquire() as conn:
                async with conn.cursor(aiomysql.DictCursor) as cur:
                    await cur.execute("SELECT status, TIMESTAMPDIFF(SECOND, last_pulse, NOW()) as age FROM `discord_aria`.`swarm_health` WHERE bot_name = 'aria'")
                    row = await cur.fetchone()
                    if row:
                        aria_heartbeat_age = row["age"]
                        aria_heartbeat_status = row["status"]
                    try:
                        await cur.execute(
                            "SELECT COUNT(*) AS total FROM `discord_aria`.`aria_interactions`"
                        )
                        count_row = await cur.fetchone() or {}
                        aria_recent_interaction_count = int(count_row.get("total") or 0)
                        await cur.execute(
                            """
                            SELECT guild_id, channel_id, user_id, user_name, interaction_type, prompt_text, response_text, created_at
                            FROM `discord_aria`.`aria_interactions`
                            ORDER BY created_at DESC, id DESC
                            LIMIT 6
                            """
                        )
                        aria_recent_interactions = list(await cur.fetchall() or [])
                    except Exception:
                        aria_recent_interactions = []
                        aria_recent_interaction_count = 0
                    try:
                        await cur.execute("SELECT COUNT(*) AS total FROM `discord_aria`.`aria_repair_tasks` WHERE status='pending'")
                        row = await cur.fetchone() or {}
                        aria_medic_summary["pending_repairs"] = int(row.get("total") or 0)
                    except Exception:
                        pass
                    try:
                        await cur.execute("SELECT COUNT(*) AS total FROM `discord_aria`.`aria_infra_tasks` WHERE status='pending'")
                        row = await cur.fetchone() or {}
                        aria_medic_summary["pending_infra"] = int(row.get("total") or 0)
                    except Exception:
                        pass
                    try:
                        await cur.execute("SELECT COUNT(*) AS total FROM `discord_aria`.`aria_swarm_health` WHERE status_label='critical'")
                        row = await cur.fetchone() or {}
                        aria_medic_summary["critical_health"] = int(row.get("total") or 0)
                    except Exception:
                        pass
                    try:
                        await cur.execute("SELECT COUNT(*) AS total FROM `discord_aria`.`aria_swarm_health` WHERE status_label IN ('recoverable','degraded')")
                        row = await cur.fetchone() or {}
                        aria_medic_summary["recoverable_health"] = int(row.get("total") or 0)
                    except Exception:
                        pass
                    try:
                        await cur.execute("SELECT issue_type, bot_name, guild_id, priority_score, urgency_label, created_at FROM `discord_aria`.`aria_operator_decisions` ORDER BY created_at DESC, id DESC LIMIT 5")
                        aria_medic_summary["recent_operator_decisions"] = list(await cur.fetchall() or [])
                    except Exception:
                        aria_medic_summary["recent_operator_decisions"] = []
                    try:
                        await cur.execute("SELECT target_name, action_name, issue_type, success, execution_mode, result_text, created_at FROM `discord_aria`.`aria_infra_history` ORDER BY created_at DESC, id DESC LIMIT 5")
                        aria_medic_summary["recent_infra_history"] = list(await cur.fetchall() or [])
                    except Exception:
                        aria_medic_summary["recent_infra_history"] = []
                    try:
                        await cur.execute("SELECT event_type, bot_name, guild_id, severity, created_at FROM `discord_aria`.`aria_swarm_events` ORDER BY created_at DESC, id DESC LIMIT 6")
                        aria_medic_summary["recent_swarm_events"] = list(await cur.fetchall() or [])
                    except Exception:
                        aria_medic_summary["recent_swarm_events"] = []
        except Exception:
            pass

        # Aria is ONLINE only when it has a recent heartbeat.
        # Never infer ONLINE from the presence of music bots — that masks an offline Aria.
        if aria_heartbeat_age is not None and aria_heartbeat_age < 120:
            aria_status_real = "ONLINE"
        else:
            aria_status_real = "OFFLINE"

        bots.append(
            {
                "key": "aria",
                "display_name": "Aria",
                "kind": "orchestrator",
                "schema": "discord_aria",
                "status": aria_status_real,
                "heartbeat_age_seconds": aria_heartbeat_age,
                "heartbeat_status": aria_heartbeat_status,
                "active_playing_count": total_active,
                "known_guild_count": sum(int(bot.get("known_guild_count") or 0) for bot in bots),
                "sessions": [],
                "recent_interactions": aria_recent_interactions,
                "recent_interaction_count": aria_recent_interaction_count,
                "medic_summary": aria_medic_summary,
            }
        )

        result = {
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "bots": bots,
        }
        self._dashboard_cache = (time.monotonic() + PANEL_DASHBOARD_CACHE_TTL_SECONDS, copy.deepcopy(result))
        return result



    async def _clear_pending_orders(self, cur: aiomysql.DictCursor, schema: str, prefix: str, gid: int, bot_key: str) -> None:
        overrides_table = f"{prefix}_swarm_overrides"
        direct_orders_table = f"{prefix}_swarm_direct_orders"
        try:
            await cur.execute(
                f"DELETE FROM `{schema}`.`{overrides_table}` WHERE guild_id = %s AND bot_name = %s",
                (gid, bot_key),
            )
        except Exception:
            pass
        try:
            await cur.execute(
                f"DELETE FROM `{schema}`.`{direct_orders_table}` WHERE guild_id = %s AND bot_name = %s",
                (gid, bot_key),
            )
        except Exception:
            pass

    async def _shuffle_live_queue(self, cur: aiomysql.DictCursor, schema: str, prefix: str, gid: int, bot_key: str, *, manage_transaction: bool = True) -> int:
        await cur.execute(
            f"CREATE TABLE IF NOT EXISTS `{schema}`.`{prefix}_queue` "
            "(id INT AUTO_INCREMENT PRIMARY KEY, guild_id BIGINT, "
            "bot_name VARCHAR(50), video_url TEXT, title TEXT, requester_id BIGINT DEFAULT NULL)"
        )
        await cur.execute(
            f"SELECT * FROM `{schema}`.`{prefix}_queue` WHERE guild_id = %s AND bot_name = %s ORDER BY id ASC",
            (gid, bot_key),
        )
        rows = list(await cur.fetchall() or [])
        if len(rows) <= 1:
            return len(rows)

        first = rows.pop(0)
        random.shuffle(rows)
        rows.insert(0, first)
        cols = [column for column in rows[0].keys() if column != "id"]
        col_names = ", ".join(f"`{column}`" for column in cols)
        placeholders = ", ".join("%s" for _ in cols)

        # Queue-control sync fix: panel-side shuffle must behave like the hardened
        # bot shuffle path. Use one transaction, bulk INSERTs, and mirror the
        # shuffled order into the backup queue so bot recovery does not resurrect
        # the old pre-shuffle order.
        insert_values = [tuple(row[column] for column in cols) for row in rows]
        try:
            if manage_transaction:
                await cur.execute("START TRANSACTION")
            await cur.execute(f"DELETE FROM `{schema}`.`{prefix}_queue` WHERE guild_id = %s AND bot_name = %s", (gid, bot_key))
            if insert_values:
                await cur.executemany(
                    f"INSERT INTO `{schema}`.`{prefix}_queue` ({col_names}) VALUES ({placeholders})",
                    insert_values,
                )
            try:
                await cur.execute(
                    f"CREATE TABLE IF NOT EXISTS `{schema}`.`{prefix}_queue_backup` "
                    "(id INT AUTO_INCREMENT PRIMARY KEY, guild_id BIGINT, "
                    "bot_name VARCHAR(50), video_url TEXT, title TEXT, requester_id BIGINT DEFAULT NULL)"
                )
                await cur.execute(f"DELETE FROM `{schema}`.`{prefix}_queue_backup` WHERE guild_id = %s AND bot_name = %s", (gid, bot_key))
                if insert_values:
                    await cur.executemany(
                        f"INSERT INTO `{schema}`.`{prefix}_queue_backup` ({col_names}) VALUES ({placeholders})",
                        insert_values,
                    )
            except Exception:
                logger.warning(
                    "Could not mirror shuffled queue into backup for %s/%s; keeping live shuffle atomic.",
                    bot_key,
                    gid,
                    exc_info=True,
                )
            if manage_transaction:
                await cur.execute("COMMIT")
        except Exception:
            if manage_transaction:
                try:
                    await cur.execute("ROLLBACK")
                except Exception:
                    pass
            raise
        return len(rows)

    async def _prime_panel_playback_defaults(self, cur: aiomysql.DictCursor, schema: str, prefix: str, gid: int, bot_key: str, *, manage_transaction: bool = True) -> int:
        await self._ensure_music_guild_settings_schema(cur, schema, prefix)
        await cur.execute(
            f"INSERT INTO `{schema}`.`{prefix}_guild_settings` (guild_id, loop_mode) VALUES (%s, %s) "
            f"ON DUPLICATE KEY UPDATE loop_mode = VALUES(loop_mode)",
            (gid, "queue"),
        )
        return await self._shuffle_live_queue(cur, schema, prefix, gid, bot_key, manage_transaction=manage_transaction)

    async def control_bot(self, bot_key: str, guild_id: str, action: str, payload: Any = None) -> dict[str, Any]:
        bot = BOT_INDEX.get(bot_key)
        if not bot:
            raise ValueError("Invalid bot")
        if bot.kind != "music" or not bot.db_schema or not bot.table_prefix:
            raise ValueError("This action is only supported for music bots")

        schema = _validate_identifier(bot.db_schema, "schema")
        prefix = _validate_identifier(bot.table_prefix, "table prefix")
        gid = _coerce_int(guild_id, "guild_id")
        action = str(action or "").strip().upper()

        result: dict[str, Any] = {"action": action, "command": action}

        pool = await self._get_pool()
        async with pool.acquire() as conn:
            # Explicit DictCursor fixes Shuffle crashes, explicit commit fixes silent rollbacks
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("START TRANSACTION")
                try:
                    if action in ["PAUSE", "RESUME", "SKIP", "STOP"]:
                        await self._clear_pending_orders(cur, schema, prefix, gid, bot_key)
                        await asyncio.wait_for(cur.execute(f"CREATE TABLE IF NOT EXISTS `{schema}`.`{prefix}_swarm_overrides` (guild_id BIGINT, bot_name VARCHAR(50), command VARCHAR(20), PRIMARY KEY(guild_id, bot_name))"), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
                        await cur.execute(f"REPLACE INTO `{schema}`.`{prefix}_swarm_overrides` (guild_id, bot_name, command) VALUES (%s, %s, %s)", (gid, bot_key, action))
                        # Mirror the intended pause/resume state immediately so the panel does not lag behind Discord.
                        try:
                            await cur.execute(f"ALTER TABLE `{schema}`.`{prefix}_playback_state` ADD COLUMN is_paused BOOLEAN DEFAULT FALSE")
                        except Exception:
                            pass
                        if action == "PAUSE":
                            await cur.execute(
                                f"UPDATE `{schema}`.`{prefix}_playback_state` SET is_paused = TRUE, is_playing = FALSE WHERE guild_id = %s AND bot_name = %s",
                                (gid, bot_key),
                            )
                        elif action == "RESUME":
                            await cur.execute(
                                f"UPDATE `{schema}`.`{prefix}_playback_state` SET is_paused = FALSE, is_playing = TRUE WHERE guild_id = %s AND bot_name = %s",
                                (gid, bot_key),
                            )
                        elif action in {"STOP", "SKIP"}:
                            await cur.execute(
                                f"UPDATE `{schema}`.`{prefix}_playback_state` SET is_paused = FALSE WHERE guild_id = %s AND bot_name = %s",
                                (gid, bot_key),
                            )
                        result["message"] = f"{bot.display_name} will {action.lower()} in guild {gid}."
                
                    elif action == "RESTART":
                        await self._clear_pending_orders(cur, schema, prefix, 0, bot_key)
                        # BUG FIX: bots poll swarm_overrides every 2 s, but they NEVER read
                        # swarm_health for a RESTART signal.  Writing to swarm_health was a
                        # silent no-op.  Corrected: write RESTART to swarm_overrides (guild 0)
                        # so aria_command_listener picks it up and calls sys.exit(0).
                        await cur.execute(
                            f"CREATE TABLE IF NOT EXISTS `{schema}`.`{prefix}_swarm_overrides` "
                            "(guild_id BIGINT, bot_name VARCHAR(50), command VARCHAR(20), "
                            "PRIMARY KEY(guild_id, bot_name))"
                        )
                        await cur.execute(
                            f"REPLACE INTO `{schema}`.`{prefix}_swarm_overrides` "
                            "(guild_id, bot_name, command) VALUES (%s, %s, %s)",
                            (0, bot_key, "RESTART"),
                        )
                        # Mark only this bot's runtime flags stale without wiping recovery metadata for other bots.
                        try:
                            await cur.execute(
                                f"UPDATE `{schema}`.`{prefix}_playback_state` SET is_playing = FALSE, is_paused = FALSE WHERE bot_name = %s",
                                (bot_key,),
                            )
                        except Exception:
                            pass
                        result["message"] = f"Restart signal queued for {bot.display_name}."

                    elif action == "CLEAR":
                        await self._clear_pending_orders(cur, schema, prefix, gid, bot_key)
                        await asyncio.wait_for(cur.execute(f"CREATE TABLE IF NOT EXISTS `{schema}`.`{prefix}_swarm_overrides` (guild_id BIGINT, bot_name VARCHAR(50), command VARCHAR(20), PRIMARY KEY(guild_id, bot_name))"), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
                        await cur.execute(
                            f"REPLACE INTO `{schema}`.`{prefix}_swarm_overrides` (guild_id, bot_name, command) VALUES (%s, %s, %s)",
                            (gid, bot_key, "STOP"),
                        )
                        await cur.execute(
                            f"CREATE TABLE IF NOT EXISTS `{schema}`.`{prefix}_queue` "
                            "(id INT AUTO_INCREMENT PRIMARY KEY, guild_id BIGINT, "
                            "bot_name VARCHAR(50), video_url TEXT, title TEXT, requester_id BIGINT DEFAULT NULL)"
                        )
                        # Scope every clear by bot_name; clear backup + voice desired state so cleared tracks do not resurrect.
                        await cur.execute(f"DELETE FROM `{schema}`.`{prefix}_queue` WHERE guild_id = %s AND bot_name = %s", (gid, bot_key))
                        try:
                            await cur.execute(f"DELETE FROM `{schema}`.`{prefix}_queue_backup` WHERE guild_id = %s AND bot_name = %s", (gid, bot_key))
                        except Exception:
                            pass
                        try:
                            await cur.execute(
                                f"UPDATE `{schema}`.`{prefix}_playback_state` "
                                "SET title = NULL, video_url = NULL, position_seconds = 0, is_playing = FALSE, is_paused = FALSE "
                                "WHERE guild_id = %s AND bot_name = %s",
                                (gid, bot_key),
                            )
                        except Exception:
                            try:
                                await cur.execute(
                                    f"UPDATE `{schema}`.`{prefix}_playback_state` "
                                    "SET title = NULL, position_seconds = 0, is_playing = FALSE, is_paused = FALSE "
                                    "WHERE guild_id = %s AND bot_name = %s",
                                    (gid, bot_key),
                                )
                            except Exception:
                                pass
                        try:
                            await cur.execute(
                                f"UPDATE `{schema}`.`{prefix}_voice_state` SET desired_connected = FALSE, connected_channel_id = NULL, disconnected_at = CURRENT_TIMESTAMP "
                                "WHERE guild_id = %s AND bot_name = %s",
                                (gid, bot_key),
                            )
                        except Exception:
                            pass
                        result["message"] = f"Cleared the queue and current playback for guild {gid} on {bot.display_name}."

                    elif action == "LOOP":
                        mode = _normalize_loop_mode(payload.get("loop_mode") if isinstance(payload, dict) else payload)
                        await self._ensure_music_guild_settings_schema(cur, schema, prefix)
                        await cur.execute(
                            f"INSERT INTO `{schema}`.`{prefix}_guild_settings` (guild_id, loop_mode) VALUES (%s, %s) "
                            f"ON DUPLICATE KEY UPDATE loop_mode = VALUES(loop_mode)",
                            (gid, mode),
                        )
                        result["loop_mode"] = mode
                        result["message"] = f"Loop mode set to {mode} for guild {gid} on {bot.display_name}."

                    elif action == "FILTER":
                        mode = _normalize_filter_mode(payload.get("filter_mode") if isinstance(payload, dict) else payload)
                        await self._ensure_music_guild_settings_schema(cur, schema, prefix)
                        await cur.execute(
                            f"INSERT INTO `{schema}`.`{prefix}_guild_settings` (guild_id, filter_mode) VALUES (%s, %s) "
                            f"ON DUPLICATE KEY UPDATE filter_mode = VALUES(filter_mode)",
                            (gid, mode),
                        )
                        await cur.execute(
                            f"CREATE TABLE IF NOT EXISTS `{schema}`.`{prefix}_swarm_overrides` "
                            "(guild_id BIGINT, bot_name VARCHAR(50), command VARCHAR(20), PRIMARY KEY(guild_id, bot_name))"
                        )
                        await cur.execute(
                            f"REPLACE INTO `{schema}`.`{prefix}_swarm_overrides` (guild_id, bot_name, command) VALUES (%s, %s, %s)",
                            (gid, bot_key, "UPDATE_FILTER"),
                        )
                        result["filter_mode"] = mode
                        result["message"] = f"Filter mode set to {mode} for guild {gid} on {bot.display_name}."

                    elif action == "SHUFFLE":
                        shuffled_count = await self._shuffle_live_queue(cur, schema, prefix, gid, bot_key, manage_transaction=False)
                        result["queue_count"] = shuffled_count
                        result["message"] = f"Shuffled {shuffled_count} queued tracks for guild {gid} on {bot.display_name}."

                    elif action == "SMART_RECOMMEND":
                        if not isinstance(payload, dict):
                            raise ValueError("SMART_RECOMMEND payload must be an object with voice_channel_id")
                        await self._clear_pending_orders(cur, schema, prefix, gid, bot_key)
                        await self._ensure_music_intelligence_schema(cur, schema, prefix)
                        voice_channel_id = _coerce_int(payload.get("voice_channel_id"), "voice_channel_id")
                        text_channel_raw = payload.get("text_channel_id")
                        text_channel_id = _coerce_int(text_channel_raw, "text_channel_id") if text_channel_raw not in (None, "", 0, "0") else 0
                        requester_raw = payload.get("requester_id")
                        requester_id = _coerce_int(requester_raw, "requester_id") if requester_raw not in (None, "", 0, "0") else None
                        shuffled_count = await self._prime_panel_playback_defaults(cur, schema, prefix, gid, bot_key, manage_transaction=False)

                        seed = None
                        reason = "server_favorite"
                        if requester_id:
                            await cur.execute(
                                f"""
                                SELECT title, video_url, score
                                FROM `{schema}`.`{prefix}_user_track_affinity`
                                WHERE guild_id = %s AND user_id = %s AND dislike_count <= like_count
                                ORDER BY score DESC, last_requested DESC
                                LIMIT 1
                                """,
                                (gid, requester_id),
                            )
                            seed = await cur.fetchone()
                            if seed:
                                reason = "personal_taste"
                        if not seed:
                            await cur.execute(
                                f"""
                                SELECT title, video_url,
                                       ((finish_count * 3) + (like_count * 5) + play_count - (skip_count * 2) - (dislike_count * 5)) AS smart_score
                                FROM `{schema}`.`{prefix}_track_intelligence`
                                WHERE guild_id = %s AND dislike_count <= like_count
                                ORDER BY smart_score DESC, updated_at DESC
                                LIMIT 1
                                """,
                                (gid,),
                            )
                            seed = await cur.fetchone()
                        if not seed:
                            raise ValueError("No smart recommendation seed exists for this bot and guild yet")

                        seed_title = str(seed.get("title") or seed.get("video_url") or "").strip()
                        query_text = f"ytmsearch:{_smart_query_from_title(seed_title)} radio"
                        await cur.execute(
                            f"CREATE TABLE IF NOT EXISTS `{schema}`.`{prefix}_swarm_direct_orders` ("
                            "id INT AUTO_INCREMENT PRIMARY KEY, "
                            "bot_name VARCHAR(50), guild_id BIGINT, vc_id BIGINT, text_channel_id BIGINT, "
                            "command VARCHAR(50), data TEXT, attempts INT NOT NULL DEFAULT 0, last_error TEXT NULL)"
                        )
                        await cur.execute(
                            f"INSERT INTO `{schema}`.`{prefix}_swarm_direct_orders` "
                            "(bot_name, guild_id, vc_id, text_channel_id, command, data) "
                            "VALUES (%s, %s, %s, %s, %s, %s)",
                            (bot_key, gid, voice_channel_id, text_channel_id, "PLAY", query_text),
                        )
                        await cur.execute(
                            f"""
                            INSERT INTO `{schema}`.`{prefix}_smart_recommendations`
                            (guild_id, requester_id, seed_title, seed_url, query_text, reason)
                            VALUES (%s, %s, %s, %s, %s, %s)
                            """,
                            (gid, requester_id, seed_title, seed.get("video_url"), query_text, reason),
                        )
                        result["seed_title"] = seed_title
                        result["query_text"] = query_text
                        result["reason"] = reason
                        result["loop_mode"] = "queue"
                        result["shuffled_queue_count"] = shuffled_count
                        result["message"] = f"Queued a smart recommendation for {bot.display_name} in guild {gid} using {seed_title[:120]}."

                    elif action == "PLAY":
                        await self._clear_pending_orders(cur, schema, prefix, gid, bot_key)
                        if not isinstance(payload, dict):
                            raise ValueError("PLAY payload must be an object with source_url and voice_channel_id")

                        source_url = str(payload.get("source_url") or payload.get("query") or "").strip()
                        if not source_url:
                            raise ValueError("Missing source_url for PLAY action")

                        voice_channel_id = _coerce_int(payload.get("voice_channel_id"), "voice_channel_id")
                        text_channel_raw = payload.get("text_channel_id")
                        text_channel_id = _coerce_int(text_channel_raw, "text_channel_id") if text_channel_raw not in (None, "", 0, "0") else 0
                        shuffled_count = await self._prime_panel_playback_defaults(cur, schema, prefix, gid, bot_key, manage_transaction=False)

                        await cur.execute(
                            f"CREATE TABLE IF NOT EXISTS `{schema}`.`{prefix}_swarm_direct_orders` ("
                            "id INT AUTO_INCREMENT PRIMARY KEY, "
                            "bot_name VARCHAR(50), guild_id BIGINT, vc_id BIGINT, text_channel_id BIGINT, "
                            "command VARCHAR(50), data TEXT, attempts INT NOT NULL DEFAULT 0, last_error TEXT NULL)"
                        )
                        await cur.execute(
                            f"CREATE TABLE IF NOT EXISTS `{schema}`.`{prefix}_swarm_overrides` "
                            "(guild_id BIGINT, bot_name VARCHAR(50), command VARCHAR(20), PRIMARY KEY(guild_id, bot_name))"
                        )
                        await cur.execute(
                            f"DELETE FROM `{schema}`.`{prefix}_swarm_overrides` WHERE guild_id = %s AND bot_name = %s",
                            (gid, bot_key),
                        )
                        await cur.execute(
                            f"DELETE FROM `{schema}`.`{prefix}_swarm_direct_orders` WHERE guild_id = %s AND bot_name = %s AND command = %s",
                            (gid, bot_key, action),
                        )
                        await cur.execute(
                            f"INSERT INTO `{schema}`.`{prefix}_swarm_direct_orders` "
                            "(bot_name, guild_id, vc_id, text_channel_id, command, data) "
                            "VALUES (%s, %s, %s, %s, %s, %s)",
                            (bot_key, gid, voice_channel_id, text_channel_id, "PLAY", source_url),
                        )
                        result["loop_mode"] = "queue"
                        result["shuffled_queue_count"] = shuffled_count
                        result["message"] = f"Queued a direct PLAY order for {bot.display_name} in guild {gid}."

                    elif action == "RECOVER":
                        recover_voice_channel_id = 0
                        if isinstance(payload, dict):
                            raw_recover_vc = payload.get("voice_channel_id") or payload.get("vc_id")
                            recover_voice_channel_id = _coerce_int(raw_recover_vc, "voice_channel_id") if raw_recover_vc not in (None, "", 0, "0") else 0
                        await cur.execute(
                            f"CREATE TABLE IF NOT EXISTS `{schema}`.`{prefix}_swarm_direct_orders` ("
                            "id INT AUTO_INCREMENT PRIMARY KEY, "
                            "bot_name VARCHAR(50), guild_id BIGINT, vc_id BIGINT, text_channel_id BIGINT, "
                            "command VARCHAR(50), data TEXT, attempts INT NOT NULL DEFAULT 0, last_error TEXT NULL)"
                        )
                        await cur.execute(
                            f"INSERT INTO `{schema}`.`{prefix}_swarm_direct_orders` "
                            "(bot_name, guild_id, vc_id, text_channel_id, command, data) "
                            "VALUES (%s, %s, %s, %s, %s, %s)",
                            (bot_key, gid, recover_voice_channel_id, 0, "RECOVER", "panel"),
                        )
                        result["message"] = f"Queued a direct RECOVER order for {bot.display_name} in guild {gid}."

                    elif action == "LEAVE":
                        await self._clear_pending_orders(cur, schema, prefix, gid, bot_key)
                        force_leave = False
                        if isinstance(payload, dict):
                            force_leave = bool(payload.get("force"))
                        await cur.execute(
                            f"CREATE TABLE IF NOT EXISTS `{schema}`.`{prefix}_swarm_direct_orders` ("
                            "id INT AUTO_INCREMENT PRIMARY KEY, "
                            "bot_name VARCHAR(50), guild_id BIGINT, vc_id BIGINT, text_channel_id BIGINT, "
                            "command VARCHAR(50), data TEXT, attempts INT NOT NULL DEFAULT 0, last_error TEXT NULL)"
                        )
                        await cur.execute(
                            f"DELETE FROM `{schema}`.`{prefix}_swarm_direct_orders` WHERE guild_id = %s AND bot_name = %s AND command = %s",
                            (gid, bot_key, action),
                        )
                        await cur.execute(
                            f"INSERT INTO `{schema}`.`{prefix}_swarm_direct_orders` "
                            "(bot_name, guild_id, vc_id, text_channel_id, command, data) "
                            "VALUES (%s, %s, %s, %s, %s, %s)",
                            (bot_key, gid, 0, 0, "LEAVE", "force" if force_leave else ""),
                        )
                        result["message"] = f"Queued a direct LEAVE order for {bot.display_name} in guild {gid}."

                    elif action == "SET_HOME":
                        if not isinstance(payload, dict):
                            raise ValueError("SET_HOME payload must be an object with voice_channel_id")

                        voice_channel_id = _coerce_int(payload.get("voice_channel_id"), "voice_channel_id")
                        await cur.execute(
                            f"CREATE TABLE IF NOT EXISTS `{schema}`.`{prefix}_bot_home_channels` "
                            "(guild_id BIGINT, bot_name VARCHAR(50), home_vc_id BIGINT, PRIMARY KEY (guild_id, bot_name))"
                        )
                        await cur.execute(
                            f"REPLACE INTO `{schema}`.`{prefix}_bot_home_channels` (guild_id, bot_name, home_vc_id) VALUES (%s, %s, %s)",
                            (gid, bot_key, voice_channel_id),
                        )
                        result["voice_channel_id"] = voice_channel_id
                        result["message"] = f"Set home channel for {bot.display_name} in guild {gid}."

                    elif action == "SEEK":
                        if not isinstance(payload, dict):
                            raise ValueError("SEEK payload must be an object with position_seconds")
                        position_seconds = max(0, _coerce_int(payload.get("position_seconds"), "position_seconds"))
                        await cur.execute(
                            f"CREATE TABLE IF NOT EXISTS `{schema}`.`{prefix}_swarm_direct_orders` ("
                            "id INT AUTO_INCREMENT PRIMARY KEY, "
                            "bot_name VARCHAR(50), guild_id BIGINT, vc_id BIGINT, text_channel_id BIGINT, "
                            "command VARCHAR(50), data TEXT, attempts INT NOT NULL DEFAULT 0, last_error TEXT NULL, "
                            "claimed_at TIMESTAMP NULL, claim_token VARCHAR(128) NULL, "
                            "created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)"
                        )
                        # Replace any pending SEEK for this bot/guild so rapid scrubbing
                        # doesn't accumulate a queue of stale positions.
                        await cur.execute(
                            f"DELETE FROM `{schema}`.`{prefix}_swarm_direct_orders` "
                            "WHERE guild_id = %s AND bot_name = %s AND command = 'SEEK'",
                            (gid, bot_key),
                        )
                        await cur.execute(
                            f"INSERT INTO `{schema}`.`{prefix}_swarm_direct_orders` "
                            "(bot_name, guild_id, vc_id, text_channel_id, command, data) "
                            "VALUES (%s, %s, %s, %s, %s, %s)",
                            (bot_key, gid, 0, 0, "SEEK", str(position_seconds)),
                        )
                        result["position_seconds"] = position_seconds
                        result["message"] = (
                            f"Seek order queued for {bot.display_name} in guild {gid} "
                            f"at position {position_seconds}s."
                        )

                    else:
                        raise ValueError(f"Unsupported action: {action}")
            
                    await cur.execute("COMMIT")
                except Exception:
                    try:
                        await cur.execute("ROLLBACK")
                    except Exception:
                        pass
                    raise
        self._invalidate_hot_caches()
        return result
