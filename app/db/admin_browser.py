"""Generic database-browser methods: schema/table listing, table data
preview, and truncation. Powers the panel's Database admin view."""

import copy
import time
from datetime import datetime
from typing import Any

import aiomysql

from .helpers import (
    PANEL_SCHEMA_CACHE_TTL_SECONDS,
    PANEL_TABLE_CACHE_TTL_SECONDS,
    PANEL_TABLE_DATA_CACHE_MAX_ITEMS,
    PANEL_TABLE_DATA_CACHE_TTL_SECONDS,
    SYSTEM_SCHEMAS,
)
from .identifiers import _validate_identifier


class AdminBrowserMixin:
    async def _table_exists(self, schema: str, table: str) -> bool:
        schema = _validate_identifier(schema, "schema")
        table = _validate_identifier(table, "table")
        key = (schema, table)
        now = time.monotonic()
        cached = self._table_exists_cache.get(key)
        if cached and cached[0] > now:
            return bool(cached[1])
        row = await self._fetchone(
            """
            SELECT 1 AS table_exists
            FROM information_schema.tables
            WHERE table_schema = %s AND table_name = %s
            LIMIT 1
            """,
            (schema, table),
        )
        exists = bool(row)
        self._table_exists_cache[key] = (now + PANEL_TABLE_CACHE_TTL_SECONDS, exists)
        return exists

    async def ping(self) -> bool:
        try:
            row = await self._fetchone("SELECT 1 AS ok")
            return bool(row and row.get("ok") == 1)
        except Exception:
            return False

    async def list_schemas(self) -> list[str]:
        now = time.monotonic()
        if self._schema_cache and self._schema_cache[0] > now:
            return list(self._schema_cache[1])
        rows = await self._fetchall(
            """
            SELECT schema_name
            FROM information_schema.schemata
            WHERE schema_name NOT IN ('information_schema', 'mysql', 'performance_schema', 'sys')
            ORDER BY schema_name
            """
        )
        schemas = [row["schema_name"] for row in rows]
        self._schema_cache = (time.monotonic() + PANEL_SCHEMA_CACHE_TTL_SECONDS, list(schemas))
        return schemas

    async def list_tables(self, schema: str) -> list[dict[str, Any]]:
        schema = _validate_identifier(schema, "schema")
        now = time.monotonic()
        cached = self._tables_cache.get(schema)
        if cached and cached[0] > now:
            return copy.deepcopy(cached[1])
        if cached:
            self._tables_cache.pop(schema, None)
        rows = await self._fetchall(
            """
            SELECT table_name, table_rows
            FROM information_schema.tables
            WHERE table_schema = %s
            ORDER BY table_name
            """,
            (schema,),
        )
        tables = [
            {"table_name": row["table_name"], "estimated_rows": int(row["table_rows"] or 0)}
            for row in rows
        ]
        self._tables_cache[schema] = (time.monotonic() + PANEL_TABLE_CACHE_TTL_SECONDS, copy.deepcopy(tables))
        return tables

    async def truncate_table(self, schema: str, table: str) -> None:
        schema = _validate_identifier(schema, "schema")
        table = _validate_identifier(table, "table")
        if schema in SYSTEM_SCHEMAS:
            raise ValueError(f"Refusing operation on system schema: {schema}")
        pool = await self._get_pool()
        async with pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute("SET FOREIGN_KEY_CHECKS = 0")
                try:
                    await cur.execute(f"TRUNCATE TABLE `{schema}`.`{table}`")
                finally:
                    await cur.execute("SET FOREIGN_KEY_CHECKS = 1")
        self._invalidate_hot_caches()

    async def truncate_schema(self, schema: str) -> dict[str, Any]:
        schema = _validate_identifier(schema, "schema")
        if schema in SYSTEM_SCHEMAS:
            raise ValueError(f"Refusing operation on system schema: {schema}")
        pool = await self._get_pool()
        tables = await self.list_tables(schema)
        async with pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute("SET FOREIGN_KEY_CHECKS = 0")
                try:
                    for table in tables:
                        table_name = _validate_identifier(table["table_name"], "table")
                        await cur.execute(f"TRUNCATE TABLE `{schema}`.`{table_name}`")
                finally:
                    await cur.execute("SET FOREIGN_KEY_CHECKS = 1")
        self._invalidate_hot_caches()
        return {"schema": schema, "truncated_tables": len(tables), "tables": [t["table_name"] for t in tables]}

    async def get_table_data(self, schema: str, table: str, limit: int = 100) -> dict[str, Any]:
        schema = _validate_identifier(schema, "schema")
        table = _validate_identifier(table, "table")
        if schema in SYSTEM_SCHEMAS:
            raise ValueError(f"Refusing operation on system schema: {schema}")
        safe_limit = max(1, min(int(limit or 100), 500))
        cache_key = (schema, table, safe_limit)
        now = time.monotonic()
        cached = self._table_data_cache.get(cache_key)
        if cached and cached[0] > now:
            self._table_data_cache.move_to_end(cache_key)
            return copy.deepcopy(cached[1])
        if cached:
            self._table_data_cache.pop(cache_key, None)

        pool = await self._get_pool()

        async with pool.acquire() as conn:
            # Use DictCursor so the frontend gets column names alongside the values
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(f"SELECT * FROM `{schema}`.`{table}` LIMIT %s", (safe_limit,))
                rows = await cur.fetchall()
                
                # Sanitize the data for JSON serialization
                processed_rows = []
                for row in rows:
                    processed_row = {}
                    for key, val in row.items():
                        if isinstance(val, datetime):
                            processed_row[key] = val.isoformat()
                        elif isinstance(val, bytes):
                            processed_row[key] = "<binary data>"
                        else:
                            processed_row[key] = val
                    processed_rows.append(processed_row)

                result = {
                    "schema": schema,
                    "table": table,
                    "count": len(processed_rows),
                    "rows": processed_rows
                }
                self._table_data_cache[cache_key] = (time.monotonic() + PANEL_TABLE_DATA_CACHE_TTL_SECONDS, copy.deepcopy(result))
                self._table_data_cache.move_to_end(cache_key)
                while len(self._table_data_cache) > PANEL_TABLE_DATA_CACHE_MAX_ITEMS:
                    self._table_data_cache.popitem(last=False)
                return result

    def _json_value(self, value: Any) -> Any:
        if hasattr(value, "isoformat"):
            return value.isoformat()
        if isinstance(value, bytes):
            return "<binary data>"
        return value

    def _json_row(self, row: dict[str, Any]) -> dict[str, Any]:
        return {key: self._json_value(value) for key, value in row.items()}

