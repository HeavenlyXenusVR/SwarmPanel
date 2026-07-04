"""Fleet-wide stability/metrics snapshots and recent-event feeds (Aria
Medic events, bot error events) shown on the Dashboard and Medic pages."""

import asyncio
from datetime import datetime, timezone
from typing import Any

import aiomysql

from ..bots import MUSIC_BOTS, BotDefinition
from .helpers import logger


class MetricsMixin:
    async def get_stability_snapshot(self) -> dict[str, Any]:
        """Return Aria recovery/degraded-mode status plus bot metric freshness."""
        metrics_result: dict[str, Any] = {}
        try:
            metrics_result = await self.get_metrics_snapshot()
        except Exception as exc:
            logger.warning("get_stability_snapshot: metrics unavailable: %s", exc)
        snapshot: dict[str, Any] = {"cooldowns": [], "recent_repairs": [], "metrics": metrics_result, "status": "ok"}
        try:
            pool = await self._get_pool()
            async with pool.acquire() as conn:
                async with conn.cursor(aiomysql.DictCursor) as cur:
                    try:
                        await cur.execute("""
                            SELECT scope_key, scope_type, guild_id, bot_name, reason,
                                   TIMESTAMPDIFF(SECOND, NOW(), cooldown_until) AS remaining_seconds,
                                   cooldown_until, updated_at
                            FROM discord_aria.aria_swarm_recovery_cooldowns
                            WHERE cooldown_until > NOW()
                            ORDER BY cooldown_until DESC
                            LIMIT 50
                        """)
                        snapshot["cooldowns"] = await cur.fetchall()
                    except Exception as exc:
                        snapshot["cooldowns_error"] = str(exc)
                    try:
                        await cur.execute("""
                            SELECT issue_type, repair_action, repair_scope, success, confidence, details, error_text, created_at
                            FROM discord_aria.aria_repair_journal
                            ORDER BY created_at DESC
                            LIMIT 50
                        """)
                        snapshot["recent_repairs"] = await cur.fetchall()
                    except Exception as exc:
                        snapshot["repairs_error"] = str(exc)
        except Exception as exc:
            snapshot["status"] = "error"
            snapshot["error"] = str(exc)
        return snapshot

    async def get_metrics_snapshot(self) -> dict[str, Any]:
        """Aggregate bot-written voice persistence and runtime metrics for the panel."""
        pool = await self._get_pool()

        async def _fetch_bot_metrics(bot: BotDefinition) -> dict[str, Any]:
            schema = bot.db_schema
            prefix = bot.table_prefix
            bot_metrics: list[dict[str, Any]] = []
            error: str | None = None
            try:
                async with pool.acquire() as conn:
                    async with conn.cursor(aiomysql.DictCursor) as cur:
                        await cur.execute(
                            f"""
                            SELECT
                                m.guild_id,
                                m.voice_connected,
                                m.connected_channel_id,
                                m.player_connected,
                                m.player_playing,
                                m.player_paused,
                                m.queue_count,
                                m.backup_queue_count,
                                m.is_playing_db,
                                m.is_paused_db,
                                m.position_seconds,
                                m.recovery_pending,
                                m.lavalink_ready,
                                m.last_error,
                                TIMESTAMPDIFF(SECOND, m.updated_at, NOW()) AS metrics_age_seconds,
                                v.last_channel_id,
                                v.connected_channel_id AS voice_state_connected_channel_id,
                                v.desired_connected,
                                v.reconnect_attempts,
                                v.last_error AS voice_last_error,
                                TIMESTAMPDIFF(SECOND, v.last_seen_at, NOW()) AS voice_age_seconds
                            FROM `{schema}`.`{prefix}_metrics` m
                            LEFT JOIN `{schema}`.`{prefix}_voice_state` v
                              ON v.guild_id = m.guild_id AND v.bot_name = m.bot_name
                            WHERE m.bot_name = %s
                            ORDER BY m.updated_at DESC
                            LIMIT 200
                            """,
                            (bot.key,),
                        )
                        rows = list(await cur.fetchall() or [])
                for row in rows:
                    age = int(row.get("metrics_age_seconds") or 0)
                    stale = age > 45
                    item = {
                        "guild_id": str(row.get("guild_id")),
                        "voice_connected": bool(row.get("voice_connected")),
                        "connected_channel_id": str(row.get("connected_channel_id") or row.get("voice_state_connected_channel_id") or ""),
                        "last_channel_id": str(row.get("last_channel_id") or ""),
                        "desired_connected": bool(row.get("desired_connected")),
                        "player_connected": bool(row.get("player_connected")),
                        "player_playing": bool(row.get("player_playing")),
                        "player_paused": bool(row.get("player_paused")),
                        "queue_count": int(row.get("queue_count") or 0),
                        "backup_queue_count": int(row.get("backup_queue_count") or 0),
                        "is_playing_db": bool(row.get("is_playing_db")),
                        "is_paused_db": bool(row.get("is_paused_db")),
                        "position_seconds": int(row.get("position_seconds") or 0),
                        "recovery_pending": bool(row.get("recovery_pending")),
                        "lavalink_ready": bool(row.get("lavalink_ready")),
                        "reconnect_attempts": int(row.get("reconnect_attempts") or 0),
                        "metrics_age_seconds": age,
                        "voice_age_seconds": int(row.get("voice_age_seconds") or 0),
                        "stale": stale,
                        "last_error": row.get("last_error") or row.get("voice_last_error"),
                    }
                    bot_metrics.append(item)
            except Exception as exc:
                msg = str(exc)
                if "doesn't exist" in msg or "1146" in msg:
                    error = None
                else:
                    error = msg

            return {
                "key": bot.key,
                "display_name": bot.display_name,
                "schema": schema,
                "metrics": bot_metrics,
                "error": error,
                "status": "error" if error else ("stale" if any(m["stale"] for m in bot_metrics) else "ok"),
            }

        bot_results = await asyncio.gather(*(_fetch_bot_metrics(bot) for bot in MUSIC_BOTS), return_exceptions=True)

        bots: list[dict[str, Any]] = []
        totals = {
            "bots": 0,
            "guilds": 0,
            "voice_connected": 0,
            "playing": 0,
            "paused": 0,
            "queued_tracks": 0,
            "backup_tracks": 0,
            "recovering": 0,
            "lavalink_ready": 0,
            "stale_metrics": 0,
        }

        for i, result in enumerate(bot_results):
            if isinstance(result, BaseException):
                bot = MUSIC_BOTS[i]
                bots.append({
                    "key": bot.key,
                    "display_name": bot.display_name,
                    "schema": bot.db_schema,
                    "metrics": [],
                    "error": str(result),
                    "status": "error",
                })
            else:
                bots.append(result)
                for item in result["metrics"]:
                    totals["guilds"] += 1
                    totals["voice_connected"] += int(item["voice_connected"])
                    totals["playing"] += int(item["player_playing"])
                    totals["paused"] += int(item["player_paused"])
                    totals["queued_tracks"] += item["queue_count"]
                    totals["backup_tracks"] += item["backup_queue_count"]
                    totals["recovering"] += int(item["recovery_pending"])
                    totals["lavalink_ready"] += int(item["lavalink_ready"])
                    totals["stale_metrics"] += int(item["stale"])
            totals["bots"] += 1

        return {
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "totals": totals,
            "bots": bots,
        }


    async def get_recent_aria_medic_events(self, limit: int = 25) -> list[dict[str, Any]]:
        pool = await self._get_pool()

        bounded_limit = max(1, min(int(limit), 50))
        events: list[dict[str, Any]] = []
        async with pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                try:
                    await cur.execute(
                        "SELECT event_type, bot_name, guild_id, severity, created_at FROM `discord_aria`.`aria_swarm_events` ORDER BY created_at DESC, id DESC LIMIT %s",
                        (bounded_limit,),
                    )
                    for row in list(await cur.fetchall() or []):
                        event_type = str(row.get("event_type") or "aria_event")
                        bot_name = str(row.get("bot_name") or "aria")
                        guild_id = row.get("guild_id")
                        severity = str(row.get("severity") or "info").lower()
                        level = "error" if severity in {"critical", "error"} else ("warning" if severity in {"warning", "recoverable", "degraded"} else "info")
                        desc = event_type.replace("_", " ")
                        if bot_name:
                            desc += f" | bot={bot_name}"
                        if guild_id not in (None, "", 0, "0"):
                            desc += f" | guild={guild_id}"
                        events.append({
                            "type": "aria_medic_event",
                            "level": level,
                            "title": "Aria Medic Event",
                            "description": desc,
                            "source": "aria",
                            "timestamp": row.get("created_at").isoformat() if row.get("created_at") else datetime.now(timezone.utc).isoformat(),
                        })
                except Exception:
                    pass
                try:
                    await cur.execute(
                        "SELECT target_name, action_name, issue_type, success, execution_mode, created_at FROM `discord_aria`.`aria_infra_history` ORDER BY created_at DESC, id DESC LIMIT %s",
                        (max(3, min(10, bounded_limit // 2 + 1)),),
                    )
                    for row in list(await cur.fetchall() or []):
                        level = "info" if int(row.get("success") or 0) else ("warning" if str(row.get("execution_mode") or "") == "planned" else "error")
                        events.append({
                            "type": "aria_infra_event",
                            "level": level,
                            "title": "Aria Infra Action",
                            "description": f"{row.get('action_name') or 'action'} -> {row.get('target_name') or 'target'} | {row.get('issue_type') or 'issue'} | mode={row.get('execution_mode') or 'unknown'}",
                            "source": "aria",
                            "timestamp": row.get("created_at").isoformat() if row.get("created_at") else datetime.now(timezone.utc).isoformat(),
                        })
                except Exception:
                    pass
        events.sort(key=lambda item: item.get("timestamp") or "")
        return events[-bounded_limit:]


    async def get_recent_bot_error_events(self, limit: int = 50) -> list[dict[str, Any]]:
        pool = await self._get_pool()

        per_bot_limit = max(3, min(25, int(limit // max(len(MUSIC_BOTS), 1)) + 2))
        events: list[dict[str, Any]] = []
        async with pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                for bot in MUSIC_BOTS:
                    schema = bot.db_schema
                    if not schema or not bot.table_prefix:
                        continue
                    table_name = f"{bot.table_prefix}_error_events"
                    try:
                        await cur.execute(
                            f"""
                            SELECT id, bot_name, guild_id, error_level, error_type, title, description, traceback_text, created_at
                            FROM `{schema}`.`{table_name}`
                            ORDER BY created_at DESC, id DESC
                            LIMIT %s
                            """,
                            (per_bot_limit,),
                        )
                        rows = list(await cur.fetchall() or [])
                    except Exception:
                        continue

                    for row in rows:
                        created_at = row.get("created_at")
                        timestamp = created_at.astimezone(timezone.utc).isoformat() if hasattr(created_at, 'astimezone') else datetime.now(timezone.utc).isoformat()
                        description = (row.get("description") or "").strip()
                        traceback_text = (row.get("traceback_text") or "").strip()
                        if traceback_text:
                            description = (description + "\n\n" + traceback_text).strip()
                        events.append(
                            {
                                "type": "bot_error",
                                "level": (row.get("error_level") or "error").lower(),
                                "title": row.get("title") or f"{bot.display_name} Error",
                                "description": description,
                                "source": bot.key,
                                "timestamp": timestamp,
                                "bot_key": bot.key,
                                "guild_id": str(row.get("guild_id")) if row.get("guild_id") is not None else None,
                                "error_type": row.get("error_type") or "runtime",
                            }
                        )

        events.sort(key=lambda item: item.get("timestamp") or "")
        return events[-max(1, min(int(limit), 100)):]

