"""Account login, registration, verification, password, and admin-CRUD
methods for the accountlogins schema."""

import asyncio
import json
import secrets
from datetime import datetime, timezone
from typing import Any

import aiomysql

from .helpers import (
    ACCOUNT_GUILD_LOCK_TABLE,
    ACCOUNT_LOGIN_SCHEMA,
    ACCOUNT_LOGIN_TABLE,
    ACCOUNT_PROFILE_FIELDS,
    PANEL_DB_QUERY_TIMEOUT_SECONDS,
    _account_password_hash,
    _coerce_int,
    _normalize_account_password,
    _normalize_account_username,
    _normalize_email,
    _verification_token_hash,
    _verify_password_hash,
)
from .identifiers import _validate_identifier


class AccountsMixin:
    async def register_account_login(
        self,
        username: str,
        guild_id: str | int,
        password: str,
        email: str | None = None,
        verification_webhook_url: str | None = None,
        verification_webhook_channel_id: str | None = None,
        verification_webhook_name: str | None = None,
        webhook_verification_code: str | None = None,
    ) -> dict[str, Any]:
        username = _normalize_account_username(username)
        gid = _coerce_int(guild_id, "guild_id")
        if gid <= 0:
            raise ValueError("Guild ID must be a positive integer.")
        normalized_password = _normalize_account_password(password)
        password_hash = _account_password_hash(normalized_password)
        email = _normalize_email(email)
        webhook_url = str(verification_webhook_url or "").strip() or None
        webhook_channel_id = str(verification_webhook_channel_id or "").strip() or None
        webhook_name = str(verification_webhook_name or "").strip()[:120] or None
        code_hash = _verification_token_hash(webhook_verification_code) if webhook_url and webhook_verification_code else None
        pool = await self._get_pool()
        async with pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await asyncio.wait_for(conn.begin(), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
                try:
                    await asyncio.wait_for(cur.execute(
                        f"""
                        SELECT username, guild_id, email
                        FROM `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
                        WHERE username = %s OR guild_id = %s OR (%s IS NOT NULL AND email = %s)
                        LIMIT 1
                        """,
                        (username, gid, email, email),
                    ), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
                    existing = await asyncio.wait_for(cur.fetchone(), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
                    if existing:
                        if existing.get("username") == username:
                            raise ValueError("That username is already registered.")
                        if email and existing.get("email") == email:
                            raise ValueError("That email is already registered.")
                        raise ValueError("That guild ID is already registered to another account.")

                    await asyncio.wait_for(cur.execute(
                        f"""
                        INSERT INTO `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_GUILD_LOCK_TABLE}` (guild_id, username)
                        VALUES (%s, %s)
                        """,
                        (gid, username),
                    ), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
                    await asyncio.wait_for(cur.execute(
                        f"""
                        INSERT INTO `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}` (
                            username, guild_id, password_hash, email,
                            verification_webhook_url, verification_webhook_channel_id, verification_webhook_name,
                            webhook_verification_code_hash, webhook_verification_sent_at
                        )
                        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, CASE WHEN %s IS NULL THEN NULL ELSE CURRENT_TIMESTAMP END)
                        """,
                        (
                            username,
                            gid,
                            password_hash,
                            email,
                            webhook_url,
                            webhook_channel_id,
                            webhook_name,
                            code_hash,
                            code_hash,
                        ),
                    ), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
                    await asyncio.wait_for(conn.commit(), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
                except ValueError:
                    await asyncio.wait_for(conn.rollback(), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
                    raise
                except Exception as exc:
                    await asyncio.wait_for(conn.rollback(), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
                    message = str(exc).lower()
                    if "duplicate" in message or "1062" in message:
                        if "guild_locks" in message or str(gid) in message:
                            raise ValueError("That guild ID is already registered to another account.") from exc
                        if email and "email" in message:
                            raise ValueError("That email is already registered.") from exc
                        raise ValueError("That username is already registered.") from exc
                    raise
        return {
            "username": username,
            "guild_id": str(gid),
            "email": email,
            "verification_webhook_url": webhook_url,
            "verification_webhook_channel_id": webhook_channel_id,
            "verification_webhook_name": webhook_name,
        }

    async def update_account_verification_webhook(
        self,
        username: str,
        guild_id: str | int,
        webhook_url: str | None,
        webhook_channel_id: str | None = None,
        webhook_name: str | None = None,
    ) -> dict[str, Any] | None:
        username = _normalize_account_username(username)
        gid = _coerce_int(guild_id, "guild_id")
        normalized_url = str(webhook_url or "").strip() or None
        normalized_channel_id = str(webhook_channel_id or "").strip() or None
        normalized_name = str(webhook_name or "").strip()[:120] or None
        current = await self._fetchone(
            f"""
            SELECT verification_webhook_url, verification_webhook_channel_id, verification_webhook_name
            FROM `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
            WHERE username = %s AND guild_id = %s
            LIMIT 1
            """,
            (username, gid),
        )
        if not current:
            return None
        same_url = str(current.get("verification_webhook_url") or "").strip() == str(normalized_url or "")
        same_channel = str(current.get("verification_webhook_channel_id") or "").strip() == str(normalized_channel_id or "")
        same_name = str(current.get("verification_webhook_name") or "").strip() == str(normalized_name or "")
        if same_url and same_channel and same_name:
            return await self.get_account_profile(username, gid)
        await self._execute(
            f"""
            UPDATE `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
            SET verification_webhook_url = %s,
                verification_webhook_channel_id = %s,
                verification_webhook_name = %s,
                webhook_verified_at = NULL,
                webhook_verification_code_hash = NULL,
                webhook_verification_sent_at = NULL
            WHERE username = %s AND guild_id = %s
            """,
            (normalized_url, normalized_channel_id, normalized_name, username, gid),
        )
        return await self.get_account_profile(username, gid)

    async def issue_account_webhook_verification_code(
        self,
        username: str,
        guild_id: str | int,
        code: str,
    ) -> dict[str, Any] | None:
        username = _normalize_account_username(username)
        gid = _coerce_int(guild_id, "guild_id")
        code_hash = _verification_token_hash(code)
        await self._execute(
            f"""
            UPDATE `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
            SET webhook_verification_code_hash = %s,
                webhook_verification_sent_at = CURRENT_TIMESTAMP
            WHERE username = %s
              AND guild_id = %s
              AND verification_webhook_url IS NOT NULL
              AND verification_webhook_url != ''
              AND webhook_verified_at IS NULL
            """,
            (code_hash, username, gid),
        )
        return await self.get_account_profile(username, gid)

    async def verify_account_email_by_token(self, token: str, max_age_seconds: int) -> dict[str, Any] | None:
        token_hash = _verification_token_hash(token)
        row = await self._fetchone(
            f"""
            SELECT username, guild_id
            FROM `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
            WHERE email_verification_token_hash = %s
              AND email_verification_sent_at IS NOT NULL
              AND email_verification_sent_at >= TIMESTAMPADD(SECOND, -%s, CURRENT_TIMESTAMP)
            LIMIT 1
            """,
            (token_hash, max(1, int(max_age_seconds or 1))),
        )
        if not row:
            return None
        await self._execute(
            f"""
            UPDATE `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
            SET email_verified_at = CURRENT_TIMESTAMP,
                email_verification_token_hash = NULL,
                email_verification_code_hash = NULL,
                email_verification_sent_at = NULL
            WHERE username = %s AND guild_id = %s
            """,
            (row["username"], row["guild_id"]),
        )
        return {"username": row["username"], "guild_id": str(row["guild_id"])}

    async def issue_account_email_verification_token(
        self,
        username: str,
        guild_id: str | int,
        token: str,
        code: str,
    ) -> dict[str, Any] | None:
        username = _normalize_account_username(username)
        gid = _coerce_int(guild_id, "guild_id")
        token_hash = _verification_token_hash(token)
        code_hash = _verification_token_hash(code)
        await self._execute(
            f"""
            UPDATE `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
            SET email_verification_token_hash = %s,
                email_verification_code_hash = %s,
                email_verification_sent_at = CURRENT_TIMESTAMP
            WHERE username = %s AND guild_id = %s AND email IS NOT NULL AND email_verified_at IS NULL
            """,
            (token_hash, code_hash, username, gid),
        )
        return await self.get_account_profile(username, gid)

    async def update_account_email(self, username: str, guild_id: str | int, email: str | None) -> dict[str, Any] | None:
        username = _normalize_account_username(username)
        gid = _coerce_int(guild_id, "guild_id")
        normalized = _normalize_email(email)
        current = await self._fetchone(
            f"""
            SELECT email
            FROM `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
            WHERE username = %s AND guild_id = %s
            LIMIT 1
            """,
            (username, gid),
        )
        if not current:
            return None
        if _normalize_email(current.get("email")) == normalized:
            return await self.get_account_profile(username, gid)
        try:
            await self._execute(
                f"""
                UPDATE `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
                SET email = %s,
                    email_verified_at = NULL,
                    email_verification_token_hash = NULL,
                    email_verification_code_hash = NULL,
                    email_verification_sent_at = NULL
                WHERE username = %s AND guild_id = %s
                """,
                (normalized, username, gid),
            )
        except Exception as exc:
            message = str(exc).lower()
            if "duplicate" in message or "1062" in message:
                raise ValueError("That email is already registered.") from exc
            raise
        return await self.get_account_profile(username, gid)

    async def verify_account_webhook_code(
        self,
        username: str,
        guild_id: str | int,
        code: str,
        max_age_seconds: int,
    ) -> dict[str, Any] | None:
        username = _normalize_account_username(username)
        gid = _coerce_int(guild_id, "guild_id")
        code_hash = _verification_token_hash(code)
        row = await self._fetchone(
            f"""
            SELECT username, guild_id
            FROM `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
            WHERE username = %s
              AND guild_id = %s
              AND verification_webhook_url IS NOT NULL
              AND verification_webhook_url != ''
              AND webhook_verification_code_hash = %s
              AND webhook_verification_sent_at IS NOT NULL
              AND webhook_verification_sent_at >= TIMESTAMPADD(SECOND, -%s, CURRENT_TIMESTAMP)
            LIMIT 1
            """,
            (username, gid, code_hash, max(1, int(max_age_seconds or 1))),
        )
        if not row:
            return None
        await self._execute(
            f"""
            UPDATE `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
            SET webhook_verified_at = CURRENT_TIMESTAMP,
                webhook_verification_code_hash = NULL,
                webhook_verification_sent_at = NULL
            WHERE username = %s AND guild_id = %s
            """,
            (username, gid),
        )
        return await self.get_account_profile(username, gid)

    async def verify_account_email_code(
        self,
        username: str,
        guild_id: str | int,
        code: str,
        max_age_seconds: int,
    ) -> dict[str, Any] | None:
        username = _normalize_account_username(username)
        gid = _coerce_int(guild_id, "guild_id")
        token_hash = _verification_token_hash(code)
        row = await self._fetchone(
            f"""
            SELECT username, guild_id
            FROM `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
            WHERE username = %s
              AND guild_id = %s
              AND email IS NOT NULL
              AND email_verification_code_hash = %s
              AND email_verification_sent_at IS NOT NULL
              AND email_verification_sent_at >= TIMESTAMPADD(SECOND, -%s, CURRENT_TIMESTAMP)
            LIMIT 1
            """,
            (username, gid, token_hash, max(1, int(max_age_seconds or 1))),
        )
        if not row:
            return None
        await self._execute(
            f"""
            UPDATE `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
            SET email_verified_at = CURRENT_TIMESTAMP,
                email_verification_token_hash = NULL,
                email_verification_code_hash = NULL,
                email_verification_sent_at = NULL
            WHERE username = %s AND guild_id = %s
            """,
            (username, gid),
        )
        return await self.get_account_profile(username, gid)

    async def authenticate_account_login(self, username: str, password: str) -> dict[str, Any] | None:
        username = _normalize_account_username(username)
        secret = str(password or "")
        if not secret:
            return None
        row = await self._fetchone(
            f"""
            SELECT username, guild_id, email, email_verified_at, password_hash
            FROM `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
            WHERE username = %s
            LIMIT 1
            """,
            (username,),
        )
        if not row:
            return None
        password_hash = row.get("password_hash")
        password_ok = _verify_password_hash(secret, password_hash) if password_hash else False
        legacy_ok = False
        if not password_ok and not password_hash:
            legacy_ok = secrets.compare_digest(str(row.get("guild_id") or ""), secret.strip())
        if not password_ok and not legacy_ok:
            return None
        await self._execute(
            f"""
            UPDATE `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
            SET last_login_at = CURRENT_TIMESTAMP, last_seen_at = CURRENT_TIMESTAMP
            WHERE username = %s AND guild_id = %s
            """,
            (username, row["guild_id"]),
        )
        return {
            "username": row["username"],
            "guild_id": str(row["guild_id"]),
            "email": row.get("email"),
            "email_verified": bool(row.get("email_verified_at")),
            "has_password": bool(password_hash),
            "used_legacy_login": legacy_ok,
        }

    async def touch_account_seen(self, username: str, guild_id: str | int, min_interval_seconds: int = 30) -> None:
        username = _normalize_account_username(username)
        gid = _coerce_int(guild_id, "guild_id")
        min_interval = max(0, int(min_interval_seconds or 0))
        if min_interval:
            await self._execute(
                f"""
                UPDATE `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
                SET last_seen_at = CURRENT_TIMESTAMP
                WHERE username = %s
                  AND guild_id = %s
                  AND (
                    last_seen_at IS NULL
                    OR last_seen_at < TIMESTAMPADD(SECOND, -%s, CURRENT_TIMESTAMP)
                  )
                """,
                (username, gid, min_interval),
            )
        else:
            await self._execute(
                f"""
                UPDATE `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
                SET last_seen_at = CURRENT_TIMESTAMP
                WHERE username = %s AND guild_id = %s
                """,
                (username, gid),
            )

    async def get_account_guild_id_for_username(self, username: str) -> str | None:
        username = _normalize_account_username(username)
        row = await self._fetchone(
            f"""
            SELECT guild_id
            FROM `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
            WHERE username = %s
            LIMIT 1
            """,
            (username,),
        )
        return str(row["guild_id"]) if row and row.get("guild_id") is not None else None

    def _serialize_account_profile(self, row: dict[str, Any]) -> dict[str, Any]:
        profile = dict(row)
        if profile.get("guild_id") is not None:
            profile["guild_id"] = str(profile["guild_id"])
        profile["display_name"] = profile.get("display_name") or profile.get("username")
        profile["public_profile"] = bool(profile.get("public_profile"))
        profile["webhook_verified"] = bool(profile.get("webhook_verified_at"))
        profile["verification_verified"] = bool(profile.get("webhook_verified_at") or profile.get("email_verified_at"))
        profile["verification_pending"] = bool(profile.get("verification_webhook_url")) and not profile["verification_verified"]
        profile["verification_webhook_configured"] = bool(profile.get("verification_webhook_url"))
        profile["email_verified"] = profile["verification_verified"]
        profile["has_password"] = bool(profile.get("password_hash"))
        profile["is_online"] = self._is_recently_seen(profile.get("last_seen_at"))
        profile.pop("password_hash", None)
        preferences = profile.get("panel_preferences")
        if isinstance(preferences, str):
            try:
                preferences = json.loads(preferences)
            except Exception:
                preferences = {}
        elif not isinstance(preferences, dict):
            preferences = {}
        profile["panel_preferences"] = preferences
        for key in ("profile_tags", "profile_links"):
            value = profile.get(key)
            if isinstance(value, str):
                try:
                    value = json.loads(value)
                except Exception:
                    value = []
            if not isinstance(value, list):
                value = []
            profile[key] = value
        for key in (
            "created_at",
            "last_login_at",
            "last_seen_at",
            "updated_at",
            "email_verified_at",
            "email_verification_sent_at",
            "webhook_verified_at",
            "webhook_verification_sent_at",
        ):
            value = profile.get(key)
            if hasattr(value, "isoformat"):
                profile[key] = value.isoformat()
        return profile

    _PRIVATE_ACCOUNT_FIELDS = (
        "email",
        "email_verified_at",
        "email_verification_sent_at",
        "verification_webhook_url",
        "verification_webhook_channel_id",
        "verification_webhook_name",
        "webhook_verified_at",
        "webhook_verification_sent_at",
    )

    def _strip_private_account_fields(self, profile: dict[str, Any]) -> dict[str, Any]:
        """Remove the account owner's email and Discord verification webhook
        (which can post into their server) before a profile is shown to anyone
        other than its owner. Callers already compute the safe derived booleans
        (email_verified, webhook_verified, verification_*) in
        _serialize_account_profile before this runs."""
        for key in self._PRIVATE_ACCOUNT_FIELDS:
            profile.pop(key, None)
        return profile

    @staticmethod
    def _is_recently_seen(value: Any, *, window_seconds: int = 180) -> bool:
        if not value:
            return False
        try:
            if isinstance(value, str):
                seen_at = datetime.fromisoformat(value.replace("Z", "+00:00"))
            else:
                seen_at = value
            if getattr(seen_at, "tzinfo", None) is None:
                seen_at = seen_at.replace(tzinfo=timezone.utc)
            return (datetime.now(timezone.utc) - seen_at.astimezone(timezone.utc)).total_seconds() <= window_seconds
        except Exception:
            return False

    async def get_account_profile(self, username: str, guild_id: str | int) -> dict[str, Any] | None:
        username = _normalize_account_username(username)
        gid = _coerce_int(guild_id, "guild_id")
        row = await self._fetchone(
            f"""
            SELECT id, username, guild_id, email, email_verified_at,
                   verification_webhook_url, verification_webhook_channel_id, verification_webhook_name,
                   webhook_verified_at, webhook_verification_sent_at,
                   password_hash, display_name, avatar_url, bio,
                   profile_headline, profile_tags, profile_links, profile_banner_url, profile_banner_mode, profile_card_style, profile_social_mode,
                   favorite_bot, theme_accent,
                   public_profile, server_invite_url, server_name, server_icon_url,
                   panel_preferences, profile_quote, profile_layout_mode, profile_header_style, profile_border_accent,
                   created_at, last_login_at, last_seen_at, updated_at
            FROM `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
            WHERE username = %s AND guild_id = %s
            LIMIT 1
            """,
            (username, gid),
        )
        return self._serialize_account_profile(row) if row else None

    async def update_account_profile(self, username: str, guild_id: str | int, updates: dict[str, Any]) -> dict[str, Any] | None:
        username = _normalize_account_username(username)
        gid = _coerce_int(guild_id, "guild_id")
        safe_updates = {
            key: value
            for key, value in updates.items()
            if key in ACCOUNT_PROFILE_FIELDS and key != "updated_at"
        }
        if safe_updates:
            assignments = ", ".join(f"`{_validate_identifier(key, 'account profile column')}` = %s" for key in safe_updates)
            await self._execute(
                f"""
                UPDATE `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
                SET {assignments}
                WHERE username = %s AND guild_id = %s
                """,
                (*safe_updates.values(), username, gid),
            )
        return await self.get_account_profile(username, gid)

    async def update_account_panel_preferences(
        self,
        username: str,
        guild_id: str | int,
        preferences: dict[str, Any],
    ) -> dict[str, Any] | None:
        username = _normalize_account_username(username)
        gid = _coerce_int(guild_id, "guild_id")
        await self._execute(
            f"""
            UPDATE `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
            SET panel_preferences = %s
            WHERE username = %s AND guild_id = %s
            """,
            (json.dumps(preferences, separators=(",", ":")), username, gid),
        )
        return await self.get_account_profile(username, gid)

    async def get_account_admin(self, account_id: int) -> dict[str, Any] | None:
        row = await self._fetchone(
            f"""
            SELECT id, username, guild_id, email, email_verified_at, email_verification_sent_at,
                   verification_webhook_url, verification_webhook_channel_id, verification_webhook_name,
                   webhook_verified_at, webhook_verification_sent_at,
                   password_hash,
                   display_name, avatar_url, bio, profile_headline, profile_tags, profile_links, profile_banner_url, profile_banner_mode,
                   profile_card_style, profile_social_mode, favorite_bot, theme_accent, public_profile,
                   server_invite_url, server_name, server_icon_url, panel_preferences,
                   profile_quote, profile_layout_mode, profile_header_style, profile_border_accent,
                   created_at, last_login_at, last_seen_at, updated_at
            FROM `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
            WHERE id = %s
            LIMIT 1
            """,
            (_coerce_int(account_id, "account_id"),),
        )
        return self._serialize_account_profile(row) if row else None

    async def get_account_admin_data(self, query: str = "", limit: int = 100) -> dict[str, Any]:
        normalized_query = str(query or "").strip()
        safe_limit = max(1, min(200, int(limit or 100)))
        like = f"%{normalized_query}%"
        summary_row = await self._fetchone(
            f"""
            SELECT
                COUNT(*) AS total_accounts,
                SUM(CASE WHEN email IS NOT NULL THEN 1 ELSE 0 END) AS accounts_with_email,
                SUM(CASE WHEN webhook_verified_at IS NOT NULL OR email_verified_at IS NOT NULL THEN 1 ELSE 0 END) AS verified_emails,
                SUM(CASE WHEN verification_webhook_url IS NOT NULL AND verification_webhook_url != '' AND webhook_verified_at IS NULL AND email_verified_at IS NULL THEN 1 ELSE 0 END) AS pending_emails,
                SUM(CASE WHEN public_profile = 1 THEN 1 ELSE 0 END) AS public_profiles,
                SUM(CASE WHEN password_hash IS NOT NULL AND password_hash != '' THEN 1 ELSE 0 END) AS passwords_set
            FROM `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
            """,
        ) or {}
        rows = await self._fetchall(
            f"""
            SELECT id, username, guild_id, email, email_verified_at, email_verification_sent_at,
                   verification_webhook_url, verification_webhook_channel_id, verification_webhook_name,
                   webhook_verified_at, webhook_verification_sent_at,
                   password_hash,
                   display_name, favorite_bot, public_profile, server_name,
                   created_at, last_login_at, last_seen_at, updated_at
            FROM `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
            WHERE (
                %s = ''
                OR username LIKE %s
                OR CAST(guild_id AS CHAR) LIKE %s
                OR COALESCE(email, '') LIKE %s
                OR COALESCE(display_name, '') LIKE %s
                OR COALESCE(server_name, '') LIKE %s
            )
            ORDER BY COALESCE(updated_at, created_at) DESC, username ASC
            LIMIT %s
            """,
            (normalized_query, like, like, like, like, like, safe_limit),
        )
        return {
            "summary": {
                "total_accounts": int(summary_row.get("total_accounts") or 0),
                "accounts_with_email": int(summary_row.get("accounts_with_email") or 0),
                "verified_emails": int(summary_row.get("verified_emails") or 0),
                "pending_emails": int(summary_row.get("pending_emails") or 0),
                "public_profiles": int(summary_row.get("public_profiles") or 0),
                "passwords_set": int(summary_row.get("passwords_set") or 0),
            },
            "users": [self._serialize_account_profile(row) for row in rows],
            "query": normalized_query,
            "limit": safe_limit,
        }

    async def update_account_admin(self, account_id: int, updates: dict[str, Any]) -> dict[str, Any] | None:
        safe_account_id = _coerce_int(account_id, "account_id")
        allowed = {"username", "guild_id", "email", "display_name", "public_profile", "server_name"}
        cleaned: dict[str, Any] = {}
        if "username" in updates:
            cleaned["username"] = _normalize_account_username(updates.get("username"))
        if "guild_id" in updates:
            cleaned["guild_id"] = _coerce_int(updates.get("guild_id"), "guild_id")
        if "email" in updates:
            email = _normalize_email(updates.get("email"))
            cleaned["email"] = email
            cleaned["email_verified_at"] = None
            cleaned["email_verification_token_hash"] = None
            cleaned["email_verification_code_hash"] = None
            cleaned["email_verification_sent_at"] = None
        if "display_name" in updates:
            cleaned["display_name"] = str(updates.get("display_name") or "").strip()[:80] or None
        if "public_profile" in updates:
            cleaned["public_profile"] = 1 if updates.get("public_profile") else 0
        if "server_name" in updates:
            cleaned["server_name"] = str(updates.get("server_name") or "").strip()[:120] or None
        unknown = set(updates) - allowed
        if unknown:
            raise ValueError(f"Unsupported account fields: {', '.join(sorted(unknown))}")

        pool = await self._get_pool()
        async with pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await asyncio.wait_for(conn.begin(), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
                try:
                    await asyncio.wait_for(cur.execute(
                        f"""
                        SELECT id, username, guild_id, email
                        FROM `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
                        WHERE id = %s
                        LIMIT 1
                        """,
                        (safe_account_id,),
                    ), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
                    current = await asyncio.wait_for(cur.fetchone(), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
                    if not current:
                        raise ValueError("SwarmPanel account not found.")

                    if "email" in updates and _normalize_email(current.get("email")) == cleaned.get("email"):
                        cleaned.pop("email", None)
                        cleaned.pop("email_verified_at", None)
                        cleaned.pop("email_verification_token_hash", None)
                        cleaned.pop("email_verification_code_hash", None)
                        cleaned.pop("email_verification_sent_at", None)

                    next_username = cleaned.get("username", current["username"])
                    next_guild_id = cleaned.get("guild_id", current["guild_id"])
                    next_email = cleaned["email"] if "email" in cleaned else current.get("email")

                    await asyncio.wait_for(cur.execute(
                        f"""
                        SELECT id, username, guild_id, email
                        FROM `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
                        WHERE id != %s AND (
                            username = %s
                            OR guild_id = %s
                            OR (%s IS NOT NULL AND email = %s)
                        )
                        LIMIT 1
                        """,
                        (safe_account_id, next_username, next_guild_id, next_email, next_email),
                    ), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
                    conflict = await asyncio.wait_for(cur.fetchone(), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
                    if conflict:
                        if conflict.get("username") == next_username:
                            raise ValueError("That username is already registered.")
                        if next_email and conflict.get("email") == next_email:
                            raise ValueError("That email is already registered.")
                        raise ValueError("That guild ID is already registered to another account.")

                    if cleaned:
                        assignments = ", ".join(
                            f"`{_validate_identifier(key, 'account column')}` = %s" for key in cleaned
                        )
                        await asyncio.wait_for(cur.execute(
                            f"""
                            UPDATE `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
                            SET {assignments}
                            WHERE id = %s
                            """,
                            (*cleaned.values(), safe_account_id),
                        ), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)

                    if next_guild_id != current["guild_id"]:
                        await asyncio.wait_for(cur.execute(
                            f"DELETE FROM `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_GUILD_LOCK_TABLE}` WHERE guild_id = %s",
                            (current["guild_id"],),
                        ), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
                        await asyncio.wait_for(cur.execute(
                            f"""
                            INSERT INTO `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_GUILD_LOCK_TABLE}` (guild_id, username)
                            VALUES (%s, %s)
                            """,
                            (next_guild_id, next_username),
                        ), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
                    elif next_username != current["username"]:
                        await asyncio.wait_for(cur.execute(
                            f"""
                            UPDATE `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_GUILD_LOCK_TABLE}`
                            SET username = %s
                            WHERE guild_id = %s
                            """,
                            (next_username, next_guild_id),
                        ), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)

                    await asyncio.wait_for(conn.commit(), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
                except ValueError:
                    await asyncio.wait_for(conn.rollback(), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
                    raise
                except Exception as exc:
                    await asyncio.wait_for(conn.rollback(), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
                    message = str(exc).lower()
                    if "duplicate" in message or "1062" in message:
                        if next_email and "email" in message:
                            raise ValueError("That email is already registered.") from exc
                        if "guild" in message:
                            raise ValueError("That guild ID is already registered to another account.") from exc
                        raise ValueError("That username is already registered.") from exc
                    raise
        return await self.get_account_admin(safe_account_id)

    async def delete_account_admin(self, account_id: int) -> None:
        safe_account_id = _coerce_int(account_id, "account_id")
        pool = await self._get_pool()
        async with pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await asyncio.wait_for(conn.begin(), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
                try:
                    await asyncio.wait_for(cur.execute(
                        f"""
                        SELECT guild_id
                        FROM `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
                        WHERE id = %s
                        LIMIT 1
                        """,
                        (safe_account_id,),
                    ), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
                    current = await asyncio.wait_for(cur.fetchone(), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
                    if not current:
                        raise ValueError("SwarmPanel account not found.")
                    await asyncio.wait_for(cur.execute(
                        f"DELETE FROM `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}` WHERE id = %s",
                        (safe_account_id,),
                    ), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
                    await asyncio.wait_for(cur.execute(
                        f"DELETE FROM `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_GUILD_LOCK_TABLE}` WHERE guild_id = %s",
                        (current["guild_id"],),
                    ), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
                    await asyncio.wait_for(conn.commit(), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
                except ValueError:
                    await asyncio.wait_for(conn.rollback(), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
                    raise
                except Exception:
                    await asyncio.wait_for(conn.rollback(), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
                    raise

    async def set_account_webhook_verified_admin(self, account_id: int, verified: bool) -> dict[str, Any] | None:
        await self._execute(
            f"""
            UPDATE `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
            SET webhook_verified_at = CASE WHEN %s THEN CURRENT_TIMESTAMP ELSE NULL END,
                email_verified_at = CASE WHEN %s THEN email_verified_at ELSE NULL END,
                email_verification_token_hash = CASE WHEN %s THEN email_verification_token_hash ELSE NULL END,
                email_verification_code_hash = CASE WHEN %s THEN email_verification_code_hash ELSE NULL END,
                email_verification_sent_at = CASE WHEN %s THEN email_verification_sent_at ELSE NULL END,
                webhook_verification_code_hash = CASE WHEN %s THEN NULL ELSE webhook_verification_code_hash END,
                webhook_verification_sent_at = CASE WHEN %s THEN NULL ELSE webhook_verification_sent_at END
            WHERE id = %s
            """,
            (
                1 if verified else 0,
                1 if verified else 0,
                1 if verified else 0,
                1 if verified else 0,
                1 if verified else 0,
                1 if verified else 0,
                1 if verified else 0,
                _coerce_int(account_id, "account_id"),
            ),
        )
        return await self.get_account_admin(account_id)

    async def update_account_password(self, username: str, guild_id: str | int, current_password: str, new_password: str) -> dict[str, Any] | None:
        username = _normalize_account_username(username)
        gid = _coerce_int(guild_id, "guild_id")
        next_password = _normalize_account_password(new_password, "New password")
        row = await self._fetchone(
            f"""
            SELECT username, guild_id, password_hash
            FROM `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
            WHERE username = %s AND guild_id = %s
            LIMIT 1
            """,
            (username, gid),
        )
        if not row:
            return None
        stored_hash = row.get("password_hash")
        current_secret = str(current_password or "")
        valid_current = _verify_password_hash(current_secret, stored_hash) if stored_hash else secrets.compare_digest(str(gid), current_secret.strip())
        if not valid_current:
            raise ValueError("Current password is incorrect.")
        await self._execute(
            f"""
            UPDATE `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
            SET password_hash = %s
            WHERE username = %s AND guild_id = %s
            """,
            (_account_password_hash(next_password), username, gid),
        )
        return await self.get_account_profile(username, gid)

    async def reset_account_password_admin(self, account_id: int, new_password: str) -> dict[str, Any] | None:
        safe_account_id = _coerce_int(account_id, "account_id")
        normalized_password = _normalize_account_password(new_password, "Password")
        await self._execute(
            f"""
            UPDATE `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
            SET password_hash = %s
            WHERE id = %s
            """,
            (_account_password_hash(normalized_password), safe_account_id),
        )
        return await self.get_account_admin(safe_account_id)

    async def issue_account_webhook_verification_code_by_id(
        self,
        account_id: int,
        code: str,
    ) -> dict[str, Any] | None:
        code_hash = _verification_token_hash(code)
        await self._execute(
            f"""
            UPDATE `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
            SET webhook_verification_code_hash = %s,
                webhook_verification_sent_at = CURRENT_TIMESTAMP
            WHERE id = %s
              AND verification_webhook_url IS NOT NULL
              AND verification_webhook_url != ''
              AND webhook_verified_at IS NULL
            """,
            (code_hash, _coerce_int(account_id, "account_id")),
        )
        return await self.get_account_admin(account_id)

    async def search_account_profiles(self, query: str = "", limit: int = 24, viewer_account_id: int | None = None, guild_id: str | None = None) -> list[dict[str, Any]]:
        normalized_query = str(query or "").strip()
        safe_limit = max(1, min(50, int(limit or 24)))
        like = f"%{normalized_query}%"
        viewer_id = int(viewer_account_id or 0)
        # guild_id filter: parameterize the value; use a compile-time flag to toggle the clause
        # rather than string-interpolating the clause itself.
        guild_filter_enabled = bool(guild_id and str(guild_id).strip())
        safe_guild_id = _coerce_int(guild_id, "guild_id") if guild_filter_enabled else None
        params: list[Any] = [viewer_id, normalized_query, like, like, like, like]
        if guild_filter_enabled:
            params.append(safe_guild_id)
        params.append(safe_limit)
        guild_clause = "AND guild_id = %s" if guild_filter_enabled else ""
        rows = await self._fetchall(
            f"""
            SELECT id, username, guild_id, email, email_verified_at,
                   verification_webhook_url, verification_webhook_channel_id, verification_webhook_name,
                   webhook_verified_at, webhook_verification_sent_at,
                   display_name, avatar_url, bio,
                   profile_headline, profile_tags, profile_links, profile_banner_url, profile_banner_mode, profile_card_style, profile_social_mode,
                   favorite_bot, theme_accent,
                   public_profile, server_invite_url, server_name, server_icon_url,
                   profile_quote, profile_layout_mode, profile_header_style, profile_border_accent,
                   created_at, last_login_at, last_seen_at, updated_at,
                   EXISTS(
                     SELECT 1
                     FROM `{ACCOUNT_LOGIN_SCHEMA}`.`account_follows` mine
                     WHERE mine.follower_account_id=%s AND mine.followed_account_id=u.id
                   ) AS followed_by_me
            FROM `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}` u
            WHERE public_profile = 1
              {guild_clause}
              AND (
                  %s = ''
                  OR username LIKE %s
                  OR COALESCE(display_name, '') LIKE %s
                  OR COALESCE(server_name, '') LIKE %s
                  OR COALESCE(favorite_bot, '') LIKE %s
              )
            ORDER BY COALESCE(updated_at, created_at) DESC, username ASC
            LIMIT %s
            """,
            tuple(params),
        )
        profiles = [self._strip_private_account_fields(self._serialize_account_profile(row)) for row in rows]
        social_snapshots = await asyncio.gather(
            *(self.get_account_social_snapshot(int(profile["id"]), viewer_id) for profile in profiles)
        ) if profiles else []
        for profile, social_snapshot in zip(profiles, social_snapshots):
            profile.update(social_snapshot)
        summaries = await self.get_music_activity_summary_for_guilds([profile["guild_id"] for profile in profiles])
        for profile in profiles:
            profile["activity"] = summaries.get(profile["guild_id"], self._empty_music_activity_summary())
        return profiles

    async def get_account_by_id(self, account_id: int) -> dict[str, Any] | None:
        row = await self._fetchone(
            f"""
            SELECT id, username, guild_id, email, email_verified_at,
                   verification_webhook_url, verification_webhook_channel_id, verification_webhook_name,
                   webhook_verified_at, webhook_verification_sent_at,
                   display_name, avatar_url, bio,
                   profile_headline, profile_tags, profile_links, profile_banner_url, profile_banner_mode, profile_card_style, profile_social_mode,
                   favorite_bot, theme_accent,
                   public_profile, server_invite_url, server_name, server_icon_url, panel_preferences,
                   created_at, last_login_at, last_seen_at, updated_at
            FROM `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}`
            WHERE id=%s
            LIMIT 1
            """,
            (_coerce_int(account_id, "account_id"),),
        )
        return self._serialize_account_profile(row) if row else None
