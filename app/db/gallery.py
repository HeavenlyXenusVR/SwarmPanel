"""Image Gallery admin methods (separate app, same MySQL server) — user
moderation, media moderation, and report handling."""

import copy
import time
from typing import Any

import aiomysql

from .helpers import (
    PANEL_IMAGE_GALLERY_ADMIN_CACHE_TTL_SECONDS,
    _coerce_int,
    _gallery_password_hash,
    _normalize_email,
    _verification_token_hash,
)
from .identifiers import _validate_identifier


class GalleryMixin:
    async def get_image_gallery_admin_data(self, limit: int = 50) -> dict[str, Any]:
        schema = _validate_identifier(self.settings.image_gallery_schema, "image gallery schema")
        safe_limit = max(1, min(int(limit or 50), 200))
        now = time.monotonic()
        cached = self._image_gallery_admin_cache.get(safe_limit)
        if cached and cached[0] > now:
            return copy.deepcopy(cached[1])
        if cached:
            self._image_gallery_admin_cache.pop(safe_limit, None)
        pool = await self._get_pool()
        async with pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                summary: dict[str, Any] = {"schema": schema}
                for key, table in (
                    ("users", "users"),
                    ("media", "media_items"),
                    ("comments", "media_comments"),
                    ("reports_open", "media_reports"),
                    ("collections", "media_collections"),
                ):
                    if key == "reports_open":
                        await cur.execute(f"SELECT COUNT(*) AS count FROM `{schema}`.`{table}` WHERE status='open'")
                    else:
                        await cur.execute(f"SELECT COUNT(*) AS count FROM `{schema}`.`{table}`")
                    row = await cur.fetchone() or {}
                    summary[key] = int(row.get("count") or 0)

                await cur.execute(
                    f"""
                    SELECT u.id, u.username, u.display_name, u.email, u.email_verified_at,
                           u.email_verification_sent_at, u.public_profile, u.show_liked_count,
                           u.birthdate, u.age_verified_at, u.adult_content_consent,
                           u.created_at, u.last_login_at,
                           COUNT(DISTINCT m.id) AS media_count,
                           COUNT(DISTINCT c.id) AS comment_count,
                           COUNT(DISTINCT b.media_id) AS bookmark_count,
                           COUNT(DISTINCT col.id) AS collection_count
                    FROM `{schema}`.`users` u
                    LEFT JOIN `{schema}`.`media_items` m ON m.user_id = u.id
                    LEFT JOIN `{schema}`.`media_comments` c ON c.user_id = u.id
                    LEFT JOIN `{schema}`.`media_bookmarks` b ON b.user_id = u.id
                    LEFT JOIN `{schema}`.`media_collections` col ON col.user_id = u.id
                    GROUP BY u.id
                    ORDER BY u.created_at DESC
                    LIMIT %s
                    """,
                    (safe_limit,),
                )
                users = [self._json_row(row) for row in await cur.fetchall()]

                await cur.execute(
                    f"""
                    SELECT c.id, c.media_id, c.user_id, c.body, c.created_at,
                           u.username, u.display_name,
                           m.title AS media_title
                    FROM `{schema}`.`media_comments` c
                    JOIN `{schema}`.`users` u ON u.id = c.user_id
                    JOIN `{schema}`.`media_items` m ON m.id = c.media_id
                    ORDER BY c.created_at DESC
                    LIMIT %s
                    """,
                    (safe_limit,),
                )
                comments = [self._json_row(row) for row in await cur.fetchall()]

                await cur.execute(
                    f"""
                    SELECT m.id, m.user_id, m.title, m.media_kind, m.file_size, m.views, m.downloads,
                           m.is_adult, m.moderation_status, m.moderation_reason, m.created_at, u.username
                    FROM `{schema}`.`media_items` m
                    JOIN `{schema}`.`users` u ON u.id = m.user_id
                    ORDER BY m.created_at DESC
                    LIMIT %s
                    """,
                    (safe_limit,),
                )
                media = [self._json_row(row) for row in await cur.fetchall()]

                await cur.execute(
                    f"""
                    SELECT r.id, r.media_id, r.user_id, r.reason, r.details, r.status, r.created_at,
                           u.username, u.display_name, m.title AS media_title
                    FROM `{schema}`.`media_reports` r
                    JOIN `{schema}`.`users` u ON u.id = r.user_id
                    JOIN `{schema}`.`media_items` m ON m.id = r.media_id
                    ORDER BY FIELD(r.status, 'open', 'reviewed', 'dismissed'), r.created_at DESC
                    LIMIT %s
                    """,
                    (safe_limit,),
                )
                reports = [self._json_row(row) for row in await cur.fetchall()]

                await cur.execute(
                    f"""
                    SELECT c.id, c.name, c.slug, c.media_kind, c.created_at,
                           COUNT(m.id) AS media_count
                    FROM `{schema}`.`categories` c
                    LEFT JOIN `{schema}`.`media_items` m ON m.category_id = c.id
                    GROUP BY c.id
                    ORDER BY c.name ASC
                    """
                )
                categories = [self._json_row(row) for row in await cur.fetchall()]

                await cur.execute(
                    f"""
                    SELECT col.id, col.user_id, col.name, col.is_public, col.created_at, u.username,
                           COUNT(ci.media_id) AS item_count
                    FROM `{schema}`.`media_collections` col
                    JOIN `{schema}`.`users` u ON u.id = col.user_id
                    LEFT JOIN `{schema}`.`media_collection_items` ci ON ci.collection_id = col.id
                    GROUP BY col.id
                    ORDER BY col.created_at DESC
                    LIMIT %s
                    """,
                    (safe_limit,),
                )
                collections = [self._json_row(row) for row in await cur.fetchall()]
        result = {
            "schema": schema,
            "summary": summary,
            "users": users,
            "comments": comments,
            "media": media,
            "reports": reports,
            "categories": categories,
            "collections": collections,
        }
        self._image_gallery_admin_cache[safe_limit] = (time.monotonic() + PANEL_IMAGE_GALLERY_ADMIN_CACHE_TTL_SECONDS, copy.deepcopy(result))
        return result

    async def get_image_gallery_user_admin(self, user_id: int) -> dict[str, Any] | None:
        schema = _validate_identifier(self.settings.image_gallery_schema, "image gallery schema")
        row = await self._fetchone(
            f"""
            SELECT id, username, display_name, email, email_verified_at, email_verification_sent_at,
                   public_profile, show_liked_count, birthdate, age_verified_at, adult_content_consent,
                   created_at, last_login_at
            FROM `{schema}`.`users`
            WHERE id = %s
            LIMIT 1
            """,
            (_coerce_int(user_id, "user_id"),),
        )
        return self._json_row(row) if row else None

    async def delete_image_gallery_user(self, user_id: int) -> None:
        schema = _validate_identifier(self.settings.image_gallery_schema, "image gallery schema")
        await self._execute(f"DELETE FROM `{schema}`.`users` WHERE id = %s", (_coerce_int(user_id, "user_id"),))
        self._invalidate_hot_caches()

    async def delete_image_gallery_comment(self, comment_id: int) -> None:
        schema = _validate_identifier(self.settings.image_gallery_schema, "image gallery schema")
        await self._execute(f"DELETE FROM `{schema}`.`media_comments` WHERE id = %s", (_coerce_int(comment_id, "comment_id"),))
        self._invalidate_hot_caches()

    async def reset_image_gallery_user_password(self, user_id: int, new_password: str) -> None:
        if len(str(new_password or "")) < 8:
            raise ValueError("Password must be at least 8 characters.")
        schema = _validate_identifier(self.settings.image_gallery_schema, "image gallery schema")
        password_hash = _gallery_password_hash(new_password)
        await self._execute(
            f"UPDATE `{schema}`.`users` SET password_hash = %s WHERE id = %s",
            (password_hash, _coerce_int(user_id, "user_id")),
        )
        self._invalidate_hot_caches()

    async def update_image_gallery_user(self, user_id: int, updates: dict[str, Any]) -> dict[str, Any] | None:
        schema = _validate_identifier(self.settings.image_gallery_schema, "image gallery schema")
        allowed = {
            "username",
            "display_name",
            "email",
            "public_profile",
            "show_liked_count",
            "adult_content_consent",
        }
        cleaned: dict[str, Any] = {}
        if "username" in updates:
            cleaned["username"] = str(updates["username"] or "").strip()[:40]
            if not cleaned["username"]:
                raise ValueError("Username cannot be empty.")
        if "display_name" in updates:
            cleaned["display_name"] = str(updates["display_name"] or "").strip()[:80] or None
        if "email" in updates:
            email = _normalize_email(updates.get("email"))
            cleaned["email"] = email
            if email:
                cleaned["email_verified_at"] = None
                cleaned["email_verification_token_hash"] = None
                cleaned["email_verification_sent_at"] = None
        for key in ("public_profile", "show_liked_count", "adult_content_consent"):
            if key in updates:
                cleaned[key] = 1 if updates.get(key) else 0
        unknown = set(updates) - allowed
        if unknown:
            raise ValueError(f"Unsupported user fields: {', '.join(sorted(unknown))}")
        if cleaned:
            assignments = ", ".join(f"`{_validate_identifier(key, 'gallery user column')}` = %s" for key in cleaned)
            await self._execute(
                f"UPDATE `{schema}`.`users` SET {assignments} WHERE id = %s",
                (*cleaned.values(), _coerce_int(user_id, "user_id")),
            )
            self._invalidate_hot_caches()
        return await self.get_image_gallery_user_admin(user_id)

    async def set_image_gallery_email_verified(self, user_id: int, verified: bool) -> dict[str, Any] | None:
        schema = _validate_identifier(self.settings.image_gallery_schema, "image gallery schema")
        await self._execute(
            f"""
            UPDATE `{schema}`.`users`
            SET email_verified_at = CASE WHEN %s THEN CURRENT_TIMESTAMP ELSE NULL END,
                email_verification_token_hash = CASE WHEN %s THEN NULL ELSE email_verification_token_hash END
            WHERE id = %s
            """,
            (1 if verified else 0, 1 if verified else 0, _coerce_int(user_id, "user_id")),
        )
        self._invalidate_hot_caches()
        return await self.get_image_gallery_user_admin(user_id)

    async def set_image_gallery_age_verified(self, user_id: int, verified: bool) -> dict[str, Any] | None:
        schema = _validate_identifier(self.settings.image_gallery_schema, "image gallery schema")
        await self._execute(
            f"""
            UPDATE `{schema}`.`users`
            SET age_verified_at = CASE WHEN %s THEN CURRENT_TIMESTAMP ELSE NULL END,
                adult_content_consent = %s
            WHERE id = %s
            """,
            (1 if verified else 0, 1 if verified else 0, _coerce_int(user_id, "user_id")),
        )
        self._invalidate_hot_caches()
        return await self.get_image_gallery_user_admin(user_id)

    async def issue_image_gallery_email_verification_token(self, user_id: int, token: str) -> dict[str, Any] | None:
        schema = _validate_identifier(self.settings.image_gallery_schema, "image gallery schema")
        token_hash = _verification_token_hash(token)
        await self._execute(
            f"""
            UPDATE `{schema}`.`users`
            SET email_verification_token_hash = %s, email_verification_sent_at = CURRENT_TIMESTAMP
            WHERE id = %s AND email IS NOT NULL AND email_verified_at IS NULL
            """,
            (token_hash, _coerce_int(user_id, "user_id")),
        )
        self._invalidate_hot_caches()
        return await self.get_image_gallery_user_admin(user_id)

    async def update_image_gallery_media(self, media_id: int, updates: dict[str, Any]) -> dict[str, Any] | None:
        schema = _validate_identifier(self.settings.image_gallery_schema, "image gallery schema")
        allowed = {"title", "is_adult", "moderation_status", "moderation_reason"}
        cleaned: dict[str, Any] = {}
        if "title" in updates:
            title = str(updates["title"] or "").strip()[:160]
            if not title:
                raise ValueError("Media title cannot be empty.")
            cleaned["title"] = title
        if "is_adult" in updates:
            cleaned["is_adult"] = 1 if updates.get("is_adult") else 0
            cleaned["adult_marked_by_user"] = 1 if updates.get("is_adult") else 0
        if "moderation_status" in updates:
            status = str(updates["moderation_status"] or "").strip().lower()
            if status not in {"clear", "review", "blocked"}:
                raise ValueError("Moderation status must be clear, review, or blocked.")
            cleaned["moderation_status"] = status
        if "moderation_reason" in updates:
            cleaned["moderation_reason"] = str(updates["moderation_reason"] or "").strip()[:300] or None
        unknown = set(updates) - allowed
        if unknown:
            raise ValueError(f"Unsupported media fields: {', '.join(sorted(unknown))}")
        if cleaned:
            assignments = ", ".join(f"`{_validate_identifier(key, 'gallery media column')}` = %s" for key in cleaned)
            await self._execute(
                f"UPDATE `{schema}`.`media_items` SET {assignments}, moderated_at=CURRENT_TIMESTAMP WHERE id = %s",
                (*cleaned.values(), _coerce_int(media_id, "media_id")),
            )
            self._invalidate_hot_caches()
        row = await self._fetchone(f"SELECT * FROM `{schema}`.`media_items` WHERE id = %s", (_coerce_int(media_id, "media_id"),))
        return self._json_row(row) if row else None

    async def delete_image_gallery_media(self, media_id: int) -> None:
        schema = _validate_identifier(self.settings.image_gallery_schema, "image gallery schema")
        await self._execute(f"DELETE FROM `{schema}`.`media_items` WHERE id = %s", (_coerce_int(media_id, "media_id"),))
        self._invalidate_hot_caches()

    async def update_image_gallery_report_status(self, report_id: int, status: str) -> None:
        schema = _validate_identifier(self.settings.image_gallery_schema, "image gallery schema")
        status = str(status or "").strip().lower()
        if status not in {"open", "reviewed", "dismissed"}:
            raise ValueError("Report status must be open, reviewed, or dismissed.")
        await self._execute(
            f"UPDATE `{schema}`.`media_reports` SET status = %s WHERE id = %s",
            (status, _coerce_int(report_id, "report_id")),
        )
        self._invalidate_hot_caches()

