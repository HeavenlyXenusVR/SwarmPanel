"""Panel-wide admin audit log: who did what destructive/administrative
action, when, and against which target. Backs the /audit-log admin page."""

import asyncio
from typing import Any

from .helpers import ACCOUNT_LOGIN_SCHEMA, PANEL_DB_QUERY_TIMEOUT_SECONDS, logger

AUDIT_LOG_TABLE = "swarm_audit_log"


class AuditMixin:
    async def _ensure_audit_log_schema(self, cur) -> None:
        await asyncio.wait_for(cur.execute(
            f"""
            CREATE TABLE IF NOT EXISTS `{ACCOUNT_LOGIN_SCHEMA}`.`{AUDIT_LOG_TABLE}` (
                id INT AUTO_INCREMENT PRIMARY KEY,
                actor_username VARCHAR(80) NOT NULL,
                actor_user_id VARCHAR(80) NULL,
                action VARCHAR(80) NOT NULL,
                target_type VARCHAR(40) NULL,
                target_id VARCHAR(80) NULL,
                details TEXT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                KEY idx_swarm_audit_log_created_at (created_at),
                KEY idx_swarm_audit_log_action (action, created_at)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
            """
        ), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)

    async def record_audit_log(
        self,
        actor: str,
        action: str,
        *,
        target_type: str | None = None,
        target_id: str | int | None = None,
        details: str | None = None,
        actor_user_id: str | int | None = None,
    ) -> None:
        """Best-effort audit trail write. Never raises — a failed audit-log
        insert must not block or fail the destructive action it's recording."""
        try:
            await self._execute(
                f"""
                INSERT INTO `{ACCOUNT_LOGIN_SCHEMA}`.`{AUDIT_LOG_TABLE}`
                    (actor_username, actor_user_id, action, target_type, target_id, details)
                VALUES (%s, %s, %s, %s, %s, %s)
                """,
                (
                    str(actor or "unknown")[:80],
                    str(actor_user_id) if actor_user_id not in (None, "") else None,
                    str(action or "")[:80],
                    str(target_type)[:40] if target_type else None,
                    str(target_id)[:80] if target_id not in (None, "") else None,
                    str(details)[:4000] if details else None,
                ),
            )
        except Exception as exc:
            logger.warning("Failed to record audit log entry action=%s: %s", action, exc)

    async def list_audit_log(
        self,
        limit: int = 100,
        offset: int = 0,
        action_filter: str | None = None,
    ) -> dict[str, Any]:
        safe_limit = max(1, min(int(limit or 100), 500))
        safe_offset = max(0, int(offset or 0))
        where = ""
        params: tuple[Any, ...] = ()
        if action_filter:
            where = "WHERE action = %s"
            params = (str(action_filter)[:80],)
        rows = await self._fetchall(
            f"""
            SELECT id, actor_username, actor_user_id, action, target_type, target_id, details, created_at
            FROM `{ACCOUNT_LOGIN_SCHEMA}`.`{AUDIT_LOG_TABLE}`
            {where}
            ORDER BY created_at DESC, id DESC
            LIMIT %s OFFSET %s
            """,
            (*params, safe_limit, safe_offset),
        )
        total_row = await self._fetchone(
            f"SELECT COUNT(*) AS count FROM `{ACCOUNT_LOGIN_SCHEMA}`.`{AUDIT_LOG_TABLE}` {where}",
            params,
        )
        return {
            "entries": [self._json_row(row) for row in rows],
            "total": int((total_row or {}).get("count") or 0),
        }
