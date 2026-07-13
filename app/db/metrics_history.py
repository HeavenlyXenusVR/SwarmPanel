"""Time-series capture of key fleet metrics, sampled periodically by a
background task and queried by the Intel page for trend charts."""

import asyncio
from datetime import datetime, timezone
from typing import Any

from .helpers import ACCOUNT_LOGIN_SCHEMA, PANEL_DB_QUERY_TIMEOUT_SECONDS, logger

METRICS_HISTORY_TABLE = "swarm_metrics_history"


class MetricsHistoryMixin:
    async def _ensure_metrics_history_schema(self, cur) -> None:
        await asyncio.wait_for(cur.execute(
            f"""
            CREATE TABLE IF NOT EXISTS `{ACCOUNT_LOGIN_SCHEMA}`.`{METRICS_HISTORY_TABLE}` (
                id BIGINT AUTO_INCREMENT PRIMARY KEY,
                captured_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                metric_key VARCHAR(60) NOT NULL,
                metric_value DOUBLE NOT NULL,
                guild_id BIGINT NULL,
                KEY idx_swarm_metrics_history_key_time (metric_key, captured_at)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
            """
        ), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)

    async def record_metric_sample(self, metric_key: str, metric_value: float, guild_id: int | None = None) -> None:
        try:
            await self._execute(
                f"""
                INSERT INTO `{ACCOUNT_LOGIN_SCHEMA}`.`{METRICS_HISTORY_TABLE}` (metric_key, metric_value, guild_id)
                VALUES (%s, %s, %s)
                """,
                (str(metric_key)[:60], float(metric_value), int(guild_id) if guild_id not in (None, "") else None),
            )
        except Exception as exc:
            logger.warning("Failed to record metric sample %s: %s", metric_key, exc)

    async def capture_metrics_snapshot(self) -> None:
        """Sample a handful of key fleet metrics into swarm_metrics_history.
        Best-effort: any single failed read must not block the others."""
        try:
            snapshot = await self.get_metrics_snapshot()
        except Exception as exc:
            logger.warning("capture_metrics_snapshot: metrics snapshot unavailable: %s", exc)
            return
        totals = snapshot.get("totals") or {}
        samples = {
            "active_bots": totals.get("bots"),
            "voice_connected": totals.get("voice_connected"),
            "playing": totals.get("playing"),
            "queued_tracks": totals.get("queued_tracks"),
            "backup_tracks": totals.get("backup_tracks"),
            "connected_guilds": totals.get("guilds"),
            "stale_metrics": totals.get("stale_metrics"),
        }
        for key, value in samples.items():
            if value is None:
                continue
            await self.record_metric_sample(key, float(value))

    async def get_metrics_history(self, metric: str, hours: int = 24) -> list[dict[str, Any]]:
        safe_hours = max(1, min(int(hours or 24), 24 * 30))
        rows = await self._fetchall(
            f"""
            SELECT captured_at, metric_value, guild_id
            FROM `{ACCOUNT_LOGIN_SCHEMA}`.`{METRICS_HISTORY_TABLE}`
            WHERE metric_key = %s AND captured_at > (UTC_TIMESTAMP() - INTERVAL %s HOUR)
            ORDER BY captured_at ASC
            """,
            (str(metric)[:60], safe_hours),
        )
        return [self._json_row(row) for row in rows]

    async def get_metric_anomalies(self, metric: str, hours: int = 24, z_threshold: float = 2.5) -> list[dict[str, Any]]:
        """Flag points in the same window get_metrics_history() returns whose
        value deviates from the window's mean by more than z_threshold
        standard deviations. Pure Python over the already-small result set —
        no new SQL aggregate needed, and no ML: this is a simple statistical
        outlier check, good enough to flag "this looks abnormal" for a human
        to look at, not a forecasting model."""
        points = await self.get_metrics_history(metric, hours)
        values = [float(point["metric_value"]) for point in points]
        if len(values) < 5:
            return []
        mean = sum(values) / len(values)
        variance = sum((value - mean) ** 2 for value in values) / len(values)
        stddev = variance ** 0.5
        if stddev == 0:
            return []
        anomalies = []
        for point in points:
            value = float(point["metric_value"])
            z_score = abs(value - mean) / stddev
            if z_score > z_threshold:
                anomalies.append({**point, "mean": round(mean, 2), "z_score": round(z_score, 2)})
        return anomalies
