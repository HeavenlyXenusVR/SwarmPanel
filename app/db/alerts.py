"""Configurable alert rules (e.g. bot offline, queue stuck) evaluated
periodically by the Telegram health-watch loop. CRUD backs the admin
Alert Rules management UI."""

import asyncio
from typing import Any

from .helpers import ACCOUNT_LOGIN_SCHEMA, PANEL_DB_QUERY_TIMEOUT_SECONDS, logger

ALERT_RULES_TABLE = "swarm_alert_rules"
VALID_ALERT_RULE_TYPES = {"bot_offline", "queue_stuck", "stale_metrics", "recovery_pending"}


class AlertsMixin:
    async def _ensure_alert_rules_schema(self, cur) -> None:
        await asyncio.wait_for(cur.execute(
            f"""
            CREATE TABLE IF NOT EXISTS `{ACCOUNT_LOGIN_SCHEMA}`.`{ALERT_RULES_TABLE}` (
                id INT AUTO_INCREMENT PRIMARY KEY,
                rule_type VARCHAR(40) NOT NULL,
                threshold_minutes INT NOT NULL DEFAULT 5,
                enabled BOOLEAN NOT NULL DEFAULT TRUE,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                KEY idx_swarm_alert_rules_enabled (enabled)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
            """
        ), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
        for column_name, definition in (
            ("escalation_minutes", "INT NULL"),
            ("escalate_email", "BOOLEAN NOT NULL DEFAULT FALSE"),
        ):
            try:
                await asyncio.wait_for(cur.execute(
                    f"ALTER TABLE `{ACCOUNT_LOGIN_SCHEMA}`.`{ALERT_RULES_TABLE}` ADD COLUMN `{column_name}` {definition}"
                ), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
            except Exception:
                pass

    async def list_alert_rules(self) -> list[dict[str, Any]]:
        rows = await self._fetchall(
            f"""
            SELECT id, rule_type, threshold_minutes, enabled, escalation_minutes, escalate_email, created_at
            FROM `{ACCOUNT_LOGIN_SCHEMA}`.`{ALERT_RULES_TABLE}`
            ORDER BY created_at DESC, id DESC
            """
        )
        return [self._json_row(row) for row in rows]

    async def get_alert_rule(self, rule_id: int) -> dict[str, Any] | None:
        row = await self._fetchone(
            f"SELECT id, rule_type, threshold_minutes, enabled, escalation_minutes, escalate_email, created_at "
            f"FROM `{ACCOUNT_LOGIN_SCHEMA}`.`{ALERT_RULES_TABLE}` WHERE id = %s",
            (int(rule_id),),
        )
        return self._json_row(row) if row else None

    async def create_alert_rule(
        self,
        rule_type: str,
        threshold_minutes: int,
        enabled: bool = True,
        escalation_minutes: int | None = None,
        escalate_email: bool = False,
    ) -> dict[str, Any]:
        rule_type = str(rule_type or "").strip().lower()
        if rule_type not in VALID_ALERT_RULE_TYPES:
            raise ValueError(f"Unsupported rule_type: {rule_type!r}. Expected one of: {', '.join(sorted(VALID_ALERT_RULE_TYPES))}")
        threshold = max(1, min(int(threshold_minutes or 5), 1440))
        safe_escalation = max(1, min(int(escalation_minutes), 10080)) if escalation_minutes else None
        await self._execute(
            f"""
            INSERT INTO `{ACCOUNT_LOGIN_SCHEMA}`.`{ALERT_RULES_TABLE}`
                (rule_type, threshold_minutes, enabled, escalation_minutes, escalate_email)
            VALUES (%s, %s, %s, %s, %s)
            """,
            (rule_type, threshold, 1 if enabled else 0, safe_escalation, 1 if escalate_email else 0),
        )
        row = await self._fetchone(
            f"SELECT id, rule_type, threshold_minutes, enabled, escalation_minutes, escalate_email, created_at "
            f"FROM `{ACCOUNT_LOGIN_SCHEMA}`.`{ALERT_RULES_TABLE}` ORDER BY id DESC LIMIT 1"
        )
        return self._json_row(row) if row else {}

    async def update_alert_rule(self, rule_id: int, updates: dict[str, Any]) -> dict[str, Any] | None:
        allowed = {"rule_type", "threshold_minutes", "enabled", "escalation_minutes", "escalate_email"}
        unknown = set(updates) - allowed
        if unknown:
            raise ValueError(f"Unsupported alert rule fields: {', '.join(sorted(unknown))}")
        cleaned: dict[str, Any] = {}
        if "rule_type" in updates:
            rule_type = str(updates["rule_type"] or "").strip().lower()
            if rule_type not in VALID_ALERT_RULE_TYPES:
                raise ValueError(f"Unsupported rule_type: {rule_type!r}")
            cleaned["rule_type"] = rule_type
        if "threshold_minutes" in updates:
            cleaned["threshold_minutes"] = max(1, min(int(updates["threshold_minutes"] or 5), 1440))
        if "enabled" in updates:
            cleaned["enabled"] = 1 if updates["enabled"] else 0
        if "escalation_minutes" in updates:
            value = updates["escalation_minutes"]
            cleaned["escalation_minutes"] = max(1, min(int(value), 10080)) if value else None
        if "escalate_email" in updates:
            cleaned["escalate_email"] = 1 if updates["escalate_email"] else 0
        if cleaned:
            assignments = ", ".join(f"`{key}` = %s" for key in cleaned)
            await self._execute(
                f"UPDATE `{ACCOUNT_LOGIN_SCHEMA}`.`{ALERT_RULES_TABLE}` SET {assignments} WHERE id = %s",
                (*cleaned.values(), int(rule_id)),
            )
        row = await self._fetchone(
            f"SELECT id, rule_type, threshold_minutes, enabled, escalation_minutes, escalate_email, created_at "
            f"FROM `{ACCOUNT_LOGIN_SCHEMA}`.`{ALERT_RULES_TABLE}` WHERE id = %s",
            (int(rule_id),),
        )
        return self._json_row(row) if row else None

    async def delete_alert_rule(self, rule_id: int) -> None:
        await self._execute(
            f"DELETE FROM `{ACCOUNT_LOGIN_SCHEMA}`.`{ALERT_RULES_TABLE}` WHERE id = %s",
            (int(rule_id),),
        )

    async def list_enabled_alert_rules(self) -> list[dict[str, Any]]:
        try:
            rows = await self._fetchall(
                f"""
                SELECT id, rule_type, threshold_minutes, enabled, escalation_minutes, escalate_email
                FROM `{ACCOUNT_LOGIN_SCHEMA}`.`{ALERT_RULES_TABLE}`
                WHERE enabled = 1
                """
            )
            return [self._json_row(row) for row in rows]
        except Exception as exc:
            logger.warning("Failed to list enabled alert rules: %s", exc)
            return []
