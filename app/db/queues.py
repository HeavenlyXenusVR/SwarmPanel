"""Saved queues/playlists: lets a guild snapshot its current live queue under
a name and replay it later. Panel-level metadata only — replay itself is
done by the caller re-issuing PLAY control actions, not by this mixin."""

import asyncio
import json
from typing import Any

from .helpers import ACCOUNT_LOGIN_SCHEMA, PANEL_DB_QUERY_TIMEOUT_SECONDS, logger

SAVED_QUEUES_TABLE = "swarm_saved_queues"
MAX_SAVED_QUEUE_ITEMS = 200


class QueuesMixin:
    async def _ensure_saved_queues_schema(self, cur) -> None:
        await asyncio.wait_for(cur.execute(
            f"""
            CREATE TABLE IF NOT EXISTS `{ACCOUNT_LOGIN_SCHEMA}`.`{SAVED_QUEUES_TABLE}` (
                id INT AUTO_INCREMENT PRIMARY KEY,
                guild_id BIGINT NOT NULL,
                bot_key VARCHAR(50) NOT NULL,
                name VARCHAR(120) NOT NULL,
                created_by_username VARCHAR(80) NOT NULL,
                items JSON NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                KEY idx_swarm_saved_queues_guild_bot (guild_id, bot_key, created_at)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
            """
        ), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)

    def _saved_queue_row(self, row: dict[str, Any]) -> dict[str, Any]:
        parsed = self._json_row(row)
        items = parsed.get("items")
        if isinstance(items, str):
            try:
                parsed["items"] = json.loads(items)
            except (TypeError, ValueError):
                parsed["items"] = []
        return parsed

    async def list_saved_queues(self, guild_id: str | int, bot_key: str | None = None) -> list[dict[str, Any]]:
        where = "WHERE guild_id = %s"
        params: tuple[Any, ...] = (int(guild_id),)
        if bot_key:
            where += " AND bot_key = %s"
            params = (*params, str(bot_key).strip().lower())
        rows = await self._fetchall(
            f"""
            SELECT id, guild_id, bot_key, name, created_by_username, items, created_at
            FROM `{ACCOUNT_LOGIN_SCHEMA}`.`{SAVED_QUEUES_TABLE}`
            {where}
            ORDER BY created_at DESC, id DESC
            """,
            params,
        )
        return [self._saved_queue_row(row) for row in rows]

    async def create_saved_queue(
        self,
        guild_id: str | int,
        bot_key: str,
        name: str,
        created_by: str,
        items: list[dict[str, Any]],
    ) -> dict[str, Any]:
        safe_name = str(name or "").strip()[:120] or "Saved Queue"
        safe_items = [
            {
                "title": str(item.get("title") or "")[:400] or None,
                "video_url": str(item.get("video_url") or "")[:1000],
                "requester_id": item.get("requester_id"),
            }
            for item in (items or [])
            if str(item.get("video_url") or "").strip()
        ][:MAX_SAVED_QUEUE_ITEMS]
        if not safe_items:
            raise ValueError("A saved queue needs at least one track with a video_url.")
        await self._execute(
            f"""
            INSERT INTO `{ACCOUNT_LOGIN_SCHEMA}`.`{SAVED_QUEUES_TABLE}`
                (guild_id, bot_key, name, created_by_username, items)
            VALUES (%s, %s, %s, %s, %s)
            """,
            (int(guild_id), str(bot_key).strip().lower(), safe_name, str(created_by or "unknown")[:80], json.dumps(safe_items)),
        )
        row = await self._fetchone(
            f"""
            SELECT id, guild_id, bot_key, name, created_by_username, items, created_at
            FROM `{ACCOUNT_LOGIN_SCHEMA}`.`{SAVED_QUEUES_TABLE}` ORDER BY id DESC LIMIT 1
            """
        )
        return self._saved_queue_row(row) if row else {}

    async def delete_saved_queue(self, queue_id: int, guild_id: str | int) -> None:
        try:
            await self._execute(
                f"DELETE FROM `{ACCOUNT_LOGIN_SCHEMA}`.`{SAVED_QUEUES_TABLE}` WHERE id = %s AND guild_id = %s",
                (int(queue_id), int(guild_id)),
            )
        except Exception as exc:
            logger.warning("Failed to delete saved queue id=%s: %s", queue_id, exc)
            raise
