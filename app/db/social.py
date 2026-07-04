"""Friends, follows, direct messages, and social-snapshot methods."""

import asyncio
from typing import Any

import aiomysql

from .helpers import ACCOUNT_LOGIN_SCHEMA, ACCOUNT_LOGIN_TABLE, PANEL_DB_QUERY_TIMEOUT_SECONDS, _coerce_int


class SocialMixin:
    async def get_account_social_snapshot(self, account_id: int, viewer_account_id: int | None = None) -> dict[str, Any]:
        target_id = _coerce_int(account_id, "account_id")
        viewer_id = _coerce_int(viewer_account_id, "viewer_account_id") if viewer_account_id else 0
        row = await self._fetchone(
            f"""
            SELECT
              (SELECT COUNT(*) FROM `{ACCOUNT_LOGIN_SCHEMA}`.`account_follows` WHERE followed_account_id=%s) AS follower_count,
              (SELECT COUNT(*) FROM `{ACCOUNT_LOGIN_SCHEMA}`.`account_follows` WHERE follower_account_id=%s) AS following_count,
              (SELECT COUNT(*)
                 FROM `{ACCOUNT_LOGIN_SCHEMA}`.`account_friend_requests`
                WHERE status='accepted' AND (requester_account_id=%s OR addressee_account_id=%s)) AS friend_count,
              EXISTS(
                SELECT 1 FROM `{ACCOUNT_LOGIN_SCHEMA}`.`account_follows`
                WHERE follower_account_id=%s AND followed_account_id=%s
              ) AS followed_by_me
            """,
            (target_id, target_id, target_id, target_id, viewer_id, target_id),
        ) or {}
        friend_status = "none"
        if viewer_id and viewer_id == target_id:
            friend_status = "self"
        elif viewer_id:
            friend_row = await self._fetchone(
                f"""
                SELECT status, requester_account_id
                FROM `{ACCOUNT_LOGIN_SCHEMA}`.`account_friend_requests`
                WHERE (requester_account_id=%s AND addressee_account_id=%s)
                   OR (requester_account_id=%s AND addressee_account_id=%s)
                ORDER BY FIELD(status, 'accepted', 'pending', 'declined', 'cancelled'), created_at DESC
                LIMIT 1
                """,
                (viewer_id, target_id, target_id, viewer_id),
            )
            status = str((friend_row or {}).get("status") or "none")
            if status == "accepted":
                friend_status = "friends"
            elif status == "pending":
                friend_status = "pending_out" if int(friend_row.get("requester_account_id") or 0) == viewer_id else "pending_in"
        return {
            "follower_count": int(row.get("follower_count") or 0),
            "following_count": int(row.get("following_count") or 0),
            "friend_count": int(row.get("friend_count") or 0),
            "followed_by_me": bool(row.get("followed_by_me")),
            "friend_status": friend_status,
        }

    async def get_public_account_profile(self, account_id: int, viewer_account_id: int | None = None) -> dict[str, Any] | None:
        profile = await self.get_account_by_id(account_id)
        if not profile:
            return None
        viewer_id = int(viewer_account_id or 0)
        if not profile.get("public_profile") and int(profile.get("id") or 0) != viewer_id:
            return None
        profile.update(await self.get_account_social_snapshot(int(profile["id"]), viewer_id))
        summaries = await self.get_music_activity_summary_for_guilds([profile["guild_id"]])
        profile["activity"] = summaries.get(profile["guild_id"], self._empty_music_activity_summary())
        return profile

    async def set_account_follow(self, follower_account_id: int, followed_account_id: int, following: bool) -> dict[str, Any]:
        if int(follower_account_id) == int(followed_account_id):
            raise ValueError("You cannot follow yourself.")
        if not await self.get_account_by_id(followed_account_id):
            raise ValueError("Account not found.")
        if following:
            await self._execute(
                f"INSERT IGNORE INTO `{ACCOUNT_LOGIN_SCHEMA}`.`account_follows` (follower_account_id, followed_account_id) VALUES (%s, %s)",
                (_coerce_int(follower_account_id, "follower_account_id"), _coerce_int(followed_account_id, "followed_account_id")),
            )
        else:
            await self._execute(
                f"DELETE FROM `{ACCOUNT_LOGIN_SCHEMA}`.`account_follows` WHERE follower_account_id=%s AND followed_account_id=%s",
                (_coerce_int(follower_account_id, "follower_account_id"), _coerce_int(followed_account_id, "followed_account_id")),
            )
        row = await self._fetchone(
            f"SELECT COUNT(*) AS followers FROM `{ACCOUNT_LOGIN_SCHEMA}`.`account_follows` WHERE followed_account_id=%s",
            (_coerce_int(followed_account_id, "followed_account_id"),),
        )
        return {"account_id": int(followed_account_id), "following": bool(following), "follower_count": int((row or {}).get("followers") or 0)}

    async def send_account_friend_request(self, requester_account_id: int, addressee_account_id: int) -> dict[str, Any]:
        if int(requester_account_id) == int(addressee_account_id):
            raise ValueError("You cannot friend yourself.")
        if not await self.get_account_by_id(addressee_account_id):
            raise ValueError("Account not found.")
        existing = await self._fetchone(
            f"""
            SELECT *
            FROM `{ACCOUNT_LOGIN_SCHEMA}`.`account_friend_requests`
            WHERE (requester_account_id=%s AND addressee_account_id=%s)
               OR (requester_account_id=%s AND addressee_account_id=%s)
            ORDER BY FIELD(status, 'accepted', 'pending', 'declined', 'cancelled'), created_at DESC
            LIMIT 1
            """,
            (requester_account_id, addressee_account_id, addressee_account_id, requester_account_id),
        )
        if existing and existing.get("status") == "accepted":
            return {"status": "friends", "request": self._serialize_social_row(existing)}
        if existing and existing.get("status") == "pending":
            if int(existing.get("requester_account_id") or 0) == int(addressee_account_id):
                await self._execute(
                    f"UPDATE `{ACCOUNT_LOGIN_SCHEMA}`.`account_friend_requests` SET status='accepted', responded_at=CURRENT_TIMESTAMP WHERE id=%s",
                    (existing["id"],),
                )
                existing["status"] = "accepted"
                return {"status": "friends", "request": self._serialize_social_row(existing)}
            return {"status": "pending_out", "request": self._serialize_social_row(existing)}
        if existing:
            await self._execute(
                f"""
                UPDATE `{ACCOUNT_LOGIN_SCHEMA}`.`account_friend_requests`
                SET requester_account_id=%s, addressee_account_id=%s, status='pending', created_at=CURRENT_TIMESTAMP, responded_at=NULL
                WHERE id=%s
                """,
                (requester_account_id, addressee_account_id, existing["id"]),
            )
            request_id = existing["id"]
        else:
            await self._execute(
                f"INSERT INTO `{ACCOUNT_LOGIN_SCHEMA}`.`account_friend_requests` (requester_account_id, addressee_account_id) VALUES (%s, %s)",
                (requester_account_id, addressee_account_id),
            )
            request_id = None
        row = await self._fetchone(
            f"""
            SELECT *
            FROM `{ACCOUNT_LOGIN_SCHEMA}`.`account_friend_requests`
            WHERE (%s IS NULL OR id=%s)
              AND requester_account_id=%s
              AND addressee_account_id=%s
            ORDER BY id DESC
            LIMIT 1
            """,
            (request_id, request_id, requester_account_id, addressee_account_id),
        )
        return {"status": "pending_out", "request": self._serialize_social_row(row or {})}

    async def list_account_friend_requests(self, account_id: int, mode: str = "incoming") -> list[dict[str, Any]]:
        # Both column names are literals from this codebase — never from user input.
        if mode == "outgoing":
            own_col, other_col = "requester_account_id", "addressee_account_id"
        else:
            own_col, other_col = "addressee_account_id", "requester_account_id"
        rows = await self._fetchall(
            f"""
            SELECT fr.*, u.id AS user_id, u.username, u.guild_id, u.display_name, u.avatar_url, u.server_name, u.server_icon_url, u.public_profile, u.last_seen_at
            FROM `{ACCOUNT_LOGIN_SCHEMA}`.`account_friend_requests` fr
            JOIN `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}` u ON u.id=fr.{other_col}
            WHERE fr.{own_col}=%s AND fr.status='pending'
            ORDER BY fr.created_at DESC
            LIMIT 100
            """,
            (_coerce_int(account_id, "account_id"),),
        )
        return [self._serialize_social_row(row) for row in rows]

    async def respond_account_friend_request(self, account_id: int, request_id: int, action: str) -> dict[str, Any] | None:
        status = {"accept": "accepted", "decline": "declined", "cancel": "cancelled"}.get(str(action or "").lower())
        if not status:
            raise ValueError("Action must be accept, decline, or cancel.")
        safe_request_id = _coerce_int(request_id, "request_id")
        safe_account_id = _coerce_int(account_id, "account_id")
        if action == "cancel":
            where = "id=%s AND requester_account_id=%s AND status='pending'"
        else:
            where = "id=%s AND addressee_account_id=%s AND status='pending'"
        row = await self._fetchone(f"SELECT * FROM `{ACCOUNT_LOGIN_SCHEMA}`.`account_friend_requests` WHERE {where}", (safe_request_id, safe_account_id))
        if not row:
            return None
        await self._execute(
            f"UPDATE `{ACCOUNT_LOGIN_SCHEMA}`.`account_friend_requests` SET status=%s, responded_at=CURRENT_TIMESTAMP WHERE id=%s",
            (status, safe_request_id),
        )
        row["status"] = status
        return self._serialize_social_row(row)

    async def list_account_friends(self, account_id: int) -> list[dict[str, Any]]:
        rows = await self._fetchall(
            f"""
            SELECT u.id, u.username, u.guild_id, u.display_name, u.avatar_url, u.bio, u.profile_headline, u.profile_tags,
                   u.profile_links, u.profile_banner_url, u.profile_banner_mode, u.profile_card_style, u.profile_social_mode,
                   u.server_name, u.server_icon_url, u.public_profile, u.last_seen_at,
                   fr.responded_at AS friended_at
            FROM `{ACCOUNT_LOGIN_SCHEMA}`.`account_friend_requests` fr
            JOIN `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}` u
              ON u.id = CASE WHEN fr.requester_account_id=%s THEN fr.addressee_account_id ELSE fr.requester_account_id END
            WHERE fr.status='accepted' AND (fr.requester_account_id=%s OR fr.addressee_account_id=%s)
            ORDER BY fr.responded_at DESC, fr.created_at DESC
            LIMIT 200
            """,
            (account_id, account_id, account_id),
        )
        return [self._serialize_account_profile(row) for row in rows]

    async def send_account_message(self, sender_account_id: int, recipient_account_id: int, body: str) -> dict[str, Any]:
        if int(sender_account_id) == int(recipient_account_id):
            raise ValueError("You cannot message yourself.")
        cleaned = " ".join(str(body or "").split())
        if not cleaned:
            raise ValueError("Message cannot be empty.")
        if len(cleaned) > 2000:
            raise ValueError("Message must be 2000 characters or fewer.")
        if not await self.get_account_by_id(recipient_account_id):
            raise ValueError("Account not found.")
        pool = await self._get_pool()
        async with pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await asyncio.wait_for(
                    cur.execute(
                        f"INSERT INTO `{ACCOUNT_LOGIN_SCHEMA}`.`account_messages` (sender_account_id, recipient_account_id, body) VALUES (%s, %s, %s)",
                        (sender_account_id, recipient_account_id, cleaned),
                    ),
                    timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS,
                )
                last_id = cur.lastrowid
                await asyncio.wait_for(
                    cur.execute(
                        f"""
                        SELECT msg.*, u.username, u.guild_id, u.display_name, u.avatar_url, u.server_name, u.server_icon_url, u.public_profile, u.last_seen_at
                        FROM `{ACCOUNT_LOGIN_SCHEMA}`.`account_messages` msg
                        JOIN `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}` u ON u.id=msg.sender_account_id
                        WHERE msg.id=%s
                        LIMIT 1
                        """,
                        (last_id,),
                    ),
                    timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS,
                )
                message = await asyncio.wait_for(cur.fetchone(), timeout=PANEL_DB_QUERY_TIMEOUT_SECONDS)
        return self._serialize_social_row(message or {})

    async def list_account_message_threads(self, account_id: int) -> list[dict[str, Any]]:
        rows = await self._fetchall(
            f"""
            SELECT
              other_user.id, other_user.id AS account_id, other_user.username, other_user.guild_id,
              other_user.display_name, other_user.avatar_url, other_user.server_name, other_user.server_icon_url, other_user.public_profile, other_user.last_seen_at,
              latest.id AS last_message_id, latest.body AS last_message, latest.created_at AS last_message_at,
              latest.sender_account_id AS last_sender_account_id, unread.unread_count
            FROM (
              SELECT CASE WHEN sender_account_id=%s THEN recipient_account_id ELSE sender_account_id END AS other_id, MAX(id) AS last_id
              FROM `{ACCOUNT_LOGIN_SCHEMA}`.`account_messages`
              WHERE sender_account_id=%s OR recipient_account_id=%s
              GROUP BY other_id
            ) threads
            JOIN `{ACCOUNT_LOGIN_SCHEMA}`.`account_messages` latest ON latest.id=threads.last_id
            JOIN `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}` other_user ON other_user.id=threads.other_id
            LEFT JOIN (
              SELECT sender_account_id AS other_id, COUNT(*) AS unread_count
              FROM `{ACCOUNT_LOGIN_SCHEMA}`.`account_messages`
              WHERE recipient_account_id=%s AND read_at IS NULL
              GROUP BY sender_account_id
            ) unread ON unread.other_id=threads.other_id
            ORDER BY latest.created_at DESC
            LIMIT 100
            """,
            (account_id, account_id, account_id, account_id),
        )
        return [self._serialize_social_row(row) for row in rows]

    async def list_account_messages(self, account_id: int, other_account_id: int, limit: int = 80) -> list[dict[str, Any]]:
        if int(account_id) == int(other_account_id):
            raise ValueError("Pick another account to view messages.")
        if not await self.get_account_by_id(other_account_id):
            raise ValueError("Account not found.")
        await self._execute(
            f"""
            UPDATE `{ACCOUNT_LOGIN_SCHEMA}`.`account_messages`
            SET read_at=COALESCE(read_at, CURRENT_TIMESTAMP)
            WHERE sender_account_id=%s AND recipient_account_id=%s AND read_at IS NULL
            """,
            (other_account_id, account_id),
        )
        rows = await self._fetchall(
            f"""
            SELECT msg.*, u.username, u.guild_id, u.display_name, u.avatar_url, u.server_name, u.server_icon_url, u.public_profile, u.last_seen_at
            FROM `{ACCOUNT_LOGIN_SCHEMA}`.`account_messages` msg
            JOIN `{ACCOUNT_LOGIN_SCHEMA}`.`{ACCOUNT_LOGIN_TABLE}` u ON u.id=msg.sender_account_id
            WHERE (msg.sender_account_id=%s AND msg.recipient_account_id=%s)
               OR (msg.sender_account_id=%s AND msg.recipient_account_id=%s)
            ORDER BY msg.created_at DESC, msg.id DESC
            LIMIT %s
            """,
            (account_id, other_account_id, other_account_id, account_id, max(1, min(limit, 200))),
        )
        rows = list(rows)
        rows.reverse()
        return [self._serialize_social_row(row) for row in rows]

    def _serialize_social_row(self, row: dict[str, Any]) -> dict[str, Any]:
        item = dict(row or {})
        if "last_seen_at" in item:
            item["is_online"] = self._is_recently_seen(item.get("last_seen_at"))
        for key, value in list(item.items()):
            if hasattr(value, "isoformat"):
                item[key] = value.isoformat()
        if "public_profile" in item:
            item["public_profile"] = bool(item.get("public_profile"))
        if "unread_count" in item:
            item["unread_count"] = int(item.get("unread_count") or 0)
        return item
