"""Connection-pool management, low-level query execution, and startup schema
bootstrapping — shared by every other mixin via ``self.``. Also owns all 9
cache dicts and the single ``_invalidate_hot_caches()`` used across domains,
since cache invalidation is a cross-cutting concern (e.g. ``control_bot()``
in BotsMixin invalidates the gallery/dashboard caches too) that can't be
split per-domain without duplicating state."""

import asyncio
from collections import OrderedDict
from typing import Any

import aiohttp
import aiomysql

from ..bots import MUSIC_BOTS
from ..config import Settings
from .helpers import (
    ACCOUNT_GUILD_LOCK_TABLE,
    ACCOUNT_LOGIN_SCHEMA,
    ACCOUNT_LOGIN_TABLE,
    ACCOUNT_AUTH_COLUMNS,
    ACCOUNT_PROFILE_COLUMNS,
    GUILD_SETTINGS_COLUMNS,
    PANEL_DB_CONNECT_TIMEOUT_SECONDS,
    PANEL_DB_POOL_MAX_SIZE,
    PANEL_DB_POOL_MIN_SIZE,
    PANEL_DB_POOL_RECYCLE_SECONDS,
    PANEL_DB_QUERY_TIMEOUT_SECONDS,
    logger,
)
from .identifiers import _validate_identifier


class CoreMixin:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.pool: aiomysql.Pool | None = None
        self.http_session: aiohttp.ClientSession | None = None
        self.thumbnail_cache: dict[str, tuple[float, str | None]] = {}
        self._connect_lock = asyncio.Lock()
        self._table_exists_cache: dict[tuple[str, str], tuple[float, bool]] = {}
        self._dashboard_cache: tuple[float, dict[str, Any]] | None = None
        self._schema_cache: tuple[float, list[str]] | None = None
        self._tables_cache: dict[str, tuple[float, list[dict[str, Any]]]] = {}
        self._table_data_cache: OrderedDict[tuple[str, str, int], tuple[float, dict[str, Any]]] = OrderedDict()
        self._image_gallery_admin_cache: dict[int, tuple[float, dict[str, Any]]] = {}
        self._lumisound_admin_cache: dict[int, tuple[float, dict[str, Any]]] = {}
        self._music_intelligence_cache: dict[tuple[str | None, str | None, int], tuple[float, dict[str, Any]]] = {}
        self._music_activity_cache: dict[tuple[int, ...], tuple[float, dict[str, dict[str, Any]]]] = {}

    def _invalidate_hot_caches(self) -> None:
        self._dashboard_cache = None
        self._table_exists_cache.clear()
        self._schema_cache = None
        self._tables_cache.clear()
        self._table_data_cache.clear()
        self._image_gallery_admin_cache.clear()
        self._music_intelligence_cache.clear()
        self._music_activity_cache.clear()

    async def _run_with_timeout(self, awaitable, timeout: float | None = None):
        return await asyncio.wait_for(awaitable, timeout=timeout or PANEL_DB_QUERY_TIMEOUT_SECONDS)

    async def _ensure_schema_exists(self, schema_name: str) -> None:
        schema_name = _validate_identifier(schema_name, "schema")
        conn = await aiomysql.connect(
            host=self.settings.db_host,
            port=self.settings.db_port,
            user=self.settings.db_user,
            password=self.settings.db_password,
            autocommit=True,
            connect_timeout=PANEL_DB_CONNECT_TIMEOUT_SECONDS,
        )
        try:
            async with conn.cursor() as cur:
                await cur.execute(
                    """
                    SELECT 1
                    FROM information_schema.schemata
                    WHERE schema_name = %s
                    LIMIT 1
                    """,
                    (schema_name,),
                )
                if not await cur.fetchone():
                    await cur.execute(f"CREATE DATABASE `{schema_name}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci")
        finally:
            conn.close()

    async def connect(self) -> None:
        async with self._connect_lock:
            if not self.pool or getattr(self.pool, "closed", False):
                # Create core schemas before the pool opens. Music bot schemas are
                # checked best-effort so one new/missing worker DB cannot brick
                # login, session checks, or the public panel shell.
                core_startup_schemas = {self.settings.db_default_schema, "discord_aria", ACCOUNT_LOGIN_SCHEMA}
                for schema in sorted(core_startup_schemas):
                    await self._ensure_schema_exists(schema)

                music_startup_schemas = {bot.db_schema for bot in MUSIC_BOTS if bot.db_schema}
                for schema in sorted(music_startup_schemas - core_startup_schemas):
                    try:
                        await self._ensure_schema_exists(schema)
                    except Exception as exc:
                        logger.warning(
                            "Music bot schema %s is not available during startup; continuing so login stays online: %s",
                            schema,
                            exc,
                        )
                self.pool = await aiomysql.create_pool(
                    host=self.settings.db_host,
                    port=self.settings.db_port,
                    user=self.settings.db_user,
                    password=self.settings.db_password,
                    db=self.settings.db_default_schema,
                    autocommit=True,
                    init_command="SET time_zone = '+00:00'",
                    minsize=PANEL_DB_POOL_MIN_SIZE,
                    maxsize=PANEL_DB_POOL_MAX_SIZE,
                    connect_timeout=PANEL_DB_CONNECT_TIMEOUT_SECONDS,
                    pool_recycle=PANEL_DB_POOL_RECYCLE_SECONDS,
                )
                self._invalidate_hot_caches()
            await self._ensure_startup_schema()
            if not self.http_session or self.http_session.closed:
                timeout = aiohttp.ClientTimeout(total=10, connect=5)
                connector = aiohttp.TCPConnector(limit=16, ttl_dns_cache=300)
                self.http_session = aiohttp.ClientSession(timeout=timeout, connector=connector)

    async def _ensure_startup_schema(self) -> None:
        """Create low-churn panel/Aria support tables once at startup.

        Dashboard polling must never execute DDL. Running this from connect() keeps
        the hot dashboard path read-only and avoids repeated metadata locks.
        """
        if not self.pool:
            raise RuntimeError("Database pool not initialized")
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                async def table_exists(schema: str, table: str) -> bool:
                    await asyncio.wait_for(cur.execute(
                        """
                        SELECT 1
                        FROM information_schema.tables
                        WHERE table_schema = %s AND table_name = %s
                        LIMIT 1
                        """,
                        (schema, table),
                    ), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
                    return bool(await asyncio.wait_for(cur.fetchone(), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS))

                try:
                    if not await table_exists("discord_aria", "aria_interactions"):
                        await asyncio.wait_for(cur.execute(
                            """
                            CREATE TABLE `discord_aria`.`aria_interactions` (
                                id INT AUTO_INCREMENT PRIMARY KEY,
                                guild_id BIGINT NULL,
                                channel_id BIGINT NULL,
                                user_id BIGINT NULL,
                                user_name VARCHAR(150) NULL,
                                interaction_type VARCHAR(32) NOT NULL DEFAULT 'chat',
                                prompt_text TEXT,
                                response_text TEXT,
                                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                            )
                            """
                        ), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
                except Exception as exc:
                    logger.warning("Could not ensure discord_aria.aria_interactions: %s", exc)
                try:
                    if not await table_exists(ACCOUNT_LOGIN_SCHEMA, ACCOUNT_LOGIN_TABLE):
                        await asyncio.wait_for(cur.execute(
                            f"""
                            CREATE TABLE `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}` (
                                id INT AUTO_INCREMENT PRIMARY KEY,
                                username VARCHAR(80) NOT NULL UNIQUE,
                                guild_id BIGINT NOT NULL,
                                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                                last_login_at TIMESTAMP NULL DEFAULT NULL,
                                last_seen_at TIMESTAMP NULL DEFAULT NULL,
                                INDEX idx_accountlogins_guild_id (guild_id)
                            )
                            """
                        ), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
                except Exception as exc:
                    logger.warning("Could not ensure accountlogins.users: %s", exc)
                try:
                    if not await table_exists(ACCOUNT_LOGIN_SCHEMA, ACCOUNT_GUILD_LOCK_TABLE):
                        await asyncio.wait_for(cur.execute(
                            f"""
                            CREATE TABLE `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_GUILD_LOCK_TABLE}` (
                                guild_id BIGINT NOT NULL PRIMARY KEY,
                                username VARCHAR(80) NOT NULL,
                                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                            )
                            """
                        ), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
                    await asyncio.wait_for(cur.execute(
                        f"""
                        INSERT IGNORE INTO `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_GUILD_LOCK_TABLE}` (guild_id, username)
                        SELECT users.guild_id, users.username
                        FROM (
                            SELECT guild_id, MIN(username) AS username
                            FROM `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
                            GROUP BY guild_id
                        ) AS users
                        LEFT JOIN `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_GUILD_LOCK_TABLE}` locks
                          ON locks.guild_id = users.guild_id
                        WHERE locks.guild_id IS NULL
                        """
                    ), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
                except Exception as exc:
                    logger.warning("Could not ensure accountlogins.guild_locks: %s", exc)
                try:
                    await self._ensure_account_profile_schema(cur)
                except Exception as exc:
                    logger.warning("Could not ensure account profile columns: %s", exc)
                try:
                    await self._ensure_account_social_schema(cur)
                except Exception as exc:
                    logger.warning("Could not ensure account social tables: %s", exc)
                try:
                    await self._ensure_audit_log_schema(cur)
                except Exception as exc:
                    logger.warning("Could not ensure swarm_audit_log table: %s", exc)

    async def close(self) -> None:
        if self.pool:
            self.pool.close()
            await self.pool.wait_closed()
            self.pool = None
        if self.http_session:
            await self.http_session.close()
            self.http_session = None

    async def _ensure_connected(self) -> None:
        if not self.pool or getattr(self.pool, "closed", False):
            await self.connect()

    async def _get_pool(self) -> aiomysql.Pool:
        await self._ensure_connected()
        if not self.pool:
            raise RuntimeError("Database pool not initialized")
        return self.pool

    async def _fetchall(self, query: str, params: tuple[Any, ...] = (), dict_cursor: bool = True):
        pool = await self._get_pool()
        async with pool.acquire() as conn:
            cursor_cls = aiomysql.DictCursor if dict_cursor else None
            cursor_context = conn.cursor(cursor_cls) if cursor_cls else conn.cursor()
            async with cursor_context as cur:
                await self._run_with_timeout(cur.execute(query, params))
                return await self._run_with_timeout(cur.fetchall())

    async def _fetchone(self, query: str, params: tuple[Any, ...] = (), dict_cursor: bool = True):
        pool = await self._get_pool()
        async with pool.acquire() as conn:
            cursor_cls = aiomysql.DictCursor if dict_cursor else None
            cursor_context = conn.cursor(cursor_cls) if cursor_cls else conn.cursor()
            async with cursor_context as cur:
                await self._run_with_timeout(cur.execute(query, params))
                return await self._run_with_timeout(cur.fetchone())

    async def _execute(self, query: str, params: tuple[Any, ...] = ()) -> int:
        pool = await self._get_pool()
        async with pool.acquire() as conn:
            async with conn.cursor() as cur:
                await self._run_with_timeout(cur.execute(query, params))
                return cur.rowcount

    async def _ensure_music_guild_settings_schema(self, cur, schema: str, prefix: str) -> None:
        schema = _validate_identifier(schema, "schema")
        prefix = _validate_identifier(prefix, "table prefix")
        await asyncio.wait_for(cur.execute(
            f"CREATE TABLE IF NOT EXISTS `{schema}`.`{prefix}_guild_settings` "
            "(guild_id BIGINT PRIMARY KEY)"
        ), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
        for column_name, definition in GUILD_SETTINGS_COLUMNS:
            try:
                safe_column = _validate_identifier(column_name, "column name")
                # definition contains only known safe literals from GUILD_SETTINGS_COLUMNS
                await asyncio.wait_for(cur.execute(
                    f"ALTER TABLE `{schema}`.`{prefix}_guild_settings` "
                    f"ADD COLUMN `{safe_column}` {definition}"
                ), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
            except Exception:
                pass

    async def _ensure_music_intelligence_schema(self, cur, schema: str, prefix: str) -> None:
        schema = _validate_identifier(schema, "schema")
        prefix = _validate_identifier(prefix, "table prefix")
        await cur.execute(
            f"CREATE TABLE IF NOT EXISTS `{schema}`.`{prefix}_track_intelligence` ("
            "guild_id BIGINT NOT NULL, url_key VARCHAR(64) NOT NULL, video_url TEXT, title TEXT, "
            "queued_count INT NOT NULL DEFAULT 0, play_count INT NOT NULL DEFAULT 0, finish_count INT NOT NULL DEFAULT 0, "
            "skip_count INT NOT NULL DEFAULT 0, like_count INT NOT NULL DEFAULT 0, dislike_count INT NOT NULL DEFAULT 0, "
            "total_listen_seconds INT NOT NULL DEFAULT 0, last_requester_id BIGINT DEFAULT NULL, source VARCHAR(40) DEFAULT 'unknown', "
            "first_seen TIMESTAMP DEFAULT CURRENT_TIMESTAMP, last_queued TIMESTAMP NULL DEFAULT NULL, last_played TIMESTAMP NULL DEFAULT NULL, "
            "updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, PRIMARY KEY (guild_id, url_key))"
        )
        await cur.execute(
            f"CREATE TABLE IF NOT EXISTS `{schema}`.`{prefix}_user_track_affinity` ("
            "guild_id BIGINT NOT NULL, user_id BIGINT NOT NULL, url_key VARCHAR(64) NOT NULL, video_url TEXT, title TEXT, "
            "queued_count INT NOT NULL DEFAULT 0, play_count INT NOT NULL DEFAULT 0, finish_count INT NOT NULL DEFAULT 0, "
            "skip_count INT NOT NULL DEFAULT 0, like_count INT NOT NULL DEFAULT 0, dislike_count INT NOT NULL DEFAULT 0, "
            "score FLOAT NOT NULL DEFAULT 0, last_requested TIMESTAMP NULL DEFAULT NULL, "
            "updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, PRIMARY KEY (guild_id, user_id, url_key))"
        )
        await cur.execute(
            f"CREATE TABLE IF NOT EXISTS `{schema}`.`{prefix}_smart_recommendations` ("
            "id INT AUTO_INCREMENT PRIMARY KEY, guild_id BIGINT NOT NULL, requester_id BIGINT DEFAULT NULL, "
            "seed_title TEXT, seed_url TEXT, query_text TEXT, chosen_url TEXT, chosen_title TEXT, "
            "reason VARCHAR(80), accepted BOOLEAN DEFAULT TRUE, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)"
        )
        for stmt in (
            f"CREATE INDEX {prefix}_track_intelligence_recent_idx ON `{schema}`.`{prefix}_track_intelligence` (guild_id, last_played)",
            f"CREATE INDEX {prefix}_track_intelligence_requester_idx ON `{schema}`.`{prefix}_track_intelligence` (guild_id, last_requester_id, last_played)",
            f"CREATE INDEX {prefix}_user_affinity_recent_idx ON `{schema}`.`{prefix}_user_track_affinity` (guild_id, user_id, last_requested)",
            f"CREATE INDEX {prefix}_smart_recommendations_recent_idx ON `{schema}`.`{prefix}_smart_recommendations` (guild_id, created_at)",
        ):
            try:
                await cur.execute(stmt)
            except Exception:
                pass

    async def _ensure_account_profile_schema(self, cur) -> None:
        for column_name, definition in (*ACCOUNT_AUTH_COLUMNS, *ACCOUNT_PROFILE_COLUMNS):
            try:
                safe_column = _validate_identifier(column_name, "account profile column")
                await asyncio.wait_for(cur.execute(
                    f"ALTER TABLE `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}` "
                    f"ADD COLUMN `{safe_column}` {definition}"
                ), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
            except Exception:
                pass
        for index_name, columns in (
            ("idx_accountlogins_public_username", "`public_profile`, `username`"),
            ("idx_accountlogins_server_name", "`server_name`"),
            ("idx_accountlogins_last_seen", "`last_seen_at`"),
        ):
            try:
                safe_index = _validate_identifier(index_name, "account profile index")
                await asyncio.wait_for(cur.execute(
                    f"CREATE INDEX `{safe_index}` ON `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}` ({columns})"
                ), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
            except Exception:
                pass
        try:
            await asyncio.wait_for(cur.execute(
                f"CREATE UNIQUE INDEX `uniq_accountlogins_email` ON `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}` (`email`)"
            ), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
        except Exception:
            pass

    async def _ensure_account_social_schema(self, cur) -> None:
        await asyncio.wait_for(cur.execute(
            f"""
            CREATE TABLE IF NOT EXISTS `{ACCOUNT_LOGIN_SCHEMA}`.`account_follows` (
                follower_account_id INT NOT NULL,
                followed_account_id INT NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (follower_account_id, followed_account_id),
                KEY idx_account_follows_followed (followed_account_id, created_at),
                CONSTRAINT fk_account_follows_follower FOREIGN KEY (follower_account_id) REFERENCES `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`(id) ON DELETE CASCADE,
                CONSTRAINT fk_account_follows_followed FOREIGN KEY (followed_account_id) REFERENCES `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`(id) ON DELETE CASCADE,
                CONSTRAINT chk_account_no_self_follow CHECK (follower_account_id <> followed_account_id)
            )
            """
        ), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
        await asyncio.wait_for(cur.execute(
            f"""
            CREATE TABLE IF NOT EXISTS `{ACCOUNT_LOGIN_SCHEMA}`.`account_friend_requests` (
                id INT AUTO_INCREMENT PRIMARY KEY,
                requester_account_id INT NOT NULL,
                addressee_account_id INT NOT NULL,
                status ENUM('pending','accepted','declined','cancelled') NOT NULL DEFAULT 'pending',
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                responded_at TIMESTAMP NULL DEFAULT NULL,
                UNIQUE KEY uniq_account_friend_pair (requester_account_id, addressee_account_id),
                KEY idx_account_friend_addressee (addressee_account_id, status, created_at),
                KEY idx_account_friend_requester (requester_account_id, status, created_at),
                CONSTRAINT fk_account_friend_requester FOREIGN KEY (requester_account_id) REFERENCES `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`(id) ON DELETE CASCADE,
                CONSTRAINT fk_account_friend_addressee FOREIGN KEY (addressee_account_id) REFERENCES `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`(id) ON DELETE CASCADE,
                CONSTRAINT chk_account_no_self_friend CHECK (requester_account_id <> addressee_account_id)
            )
            """
        ), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
        await asyncio.wait_for(cur.execute(
            f"""
            CREATE TABLE IF NOT EXISTS `{ACCOUNT_LOGIN_SCHEMA}`.`account_messages` (
                id BIGINT AUTO_INCREMENT PRIMARY KEY,
                sender_account_id INT NOT NULL,
                recipient_account_id INT NOT NULL,
                body VARCHAR(2000) NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                read_at TIMESTAMP NULL DEFAULT NULL,
                KEY idx_account_messages_sender (sender_account_id, created_at),
                KEY idx_account_messages_recipient (recipient_account_id, read_at, created_at),
                KEY idx_account_messages_thread (sender_account_id, recipient_account_id, created_at),
                CONSTRAINT fk_account_messages_sender FOREIGN KEY (sender_account_id) REFERENCES `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`(id) ON DELETE CASCADE,
                CONSTRAINT fk_account_messages_recipient FOREIGN KEY (recipient_account_id) REFERENCES `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`(id) ON DELETE CASCADE,
                CONSTRAINT chk_account_no_self_message CHECK (sender_account_id <> recipient_account_id)
            )
            """
        ), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
