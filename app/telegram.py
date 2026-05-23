from __future__ import annotations

import asyncio
import json
import logging
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Any


logger = logging.getLogger("swarm_panel.telegram")


TelegramHandler = Callable[[dict[str, Any]], Awaitable[str | None]]


class TelegramTransientError(RuntimeError):
    pass


class TelegramRetryAfter(TelegramTransientError):
    def __init__(self, retry_after: int, message: str = "Telegram rate limited") -> None:
        super().__init__(message)
        self.retry_after = retry_after



@dataclass
class TelegramServiceStatus:
    enabled: bool
    running: bool
    bot_username: str = ""
    allowed_chat_count: int = 0
    last_error: str = ""
    last_update_at: float = 0.0


class TelegramPollingService:
    def __init__(
        self,
        *,
        token: str,
        name: str,
        handler: TelegramHandler,
        allowed_chat_ids: set[int] | None = None,
        allowed_usernames: set[str] | None = None,
        recipient_store_path: str | Path | None = None,
        commands: list[tuple[str, str]] | None = None,
        poll_timeout_seconds: int = 25,
    ) -> None:
        self.token = str(token or "").strip()
        self.name = name
        self.handler = handler
        self.allowed_chat_ids = set(allowed_chat_ids or set())
        self.allowed_usernames = {self._normalize_username(username) for username in (allowed_usernames or set()) if self._normalize_username(username)}
        self.recipient_store_path = Path(recipient_store_path) if recipient_store_path else None
        self.commands = list(commands or [])
        self.poll_timeout_seconds = max(5, int(poll_timeout_seconds or 25))
        self._task: asyncio.Task[Any] | None = None
        self._closing = asyncio.Event()
        self._offset: int | None = None
        self.status = TelegramServiceStatus(
            enabled=bool(self.token),
            running=False,
            allowed_chat_count=len(self.allowed_chat_ids),
        )
        self._learned_chat_ids: set[int] = set()
        self._load_learned_recipients()
        self.status.allowed_chat_count = len(self.alert_chat_ids())

    async def start(self) -> None:
        if not self.token or (self._task and not self._task.done()):
            return
        try:
            info = await self._api("getMe", timeout=12)
            bot = info.get("result") or {}
            self.status.bot_username = str(bot.get("username") or "")
            await self._api("deleteWebhook", {"drop_pending_updates": "false"}, timeout=12)
            if self.commands:
                await self._api(
                    "setMyCommands",
                    {"commands": json.dumps([{"command": key, "description": desc} for key, desc in self.commands])},
                    timeout=12,
                )
            logger.info("%s Telegram bridge connected as @%s.", self.name, self.status.bot_username or "unknown")
        except Exception as exc:
            self.status.last_error = str(exc)[:240]
            logger.warning("%s Telegram bridge could not verify token yet: %s", self.name, exc)
        self._closing.clear()
        self._task = asyncio.create_task(self._poll_loop(), name=f"{self.name}-telegram")

    async def close(self) -> None:
        self._closing.set()
        if self._task and not self._task.done():
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
        self._task = None
        self.status.running = False

    async def send_message(self, chat_id: int | str, text: str) -> None:
        payload = str(text or "").strip()
        if not payload:
            return
        for chunk in self._chunks(payload, 3900):
            await self._api(
                "sendMessage",
                {"chat_id": str(chat_id), "text": chunk, "disable_web_page_preview": "true"},
                timeout=15,
            )

    def alert_chat_ids(self) -> set[int]:
        return set(self.allowed_chat_ids) | set(self._learned_chat_ids)

    def snapshot(self) -> dict[str, Any]:
        return {
            "enabled": self.status.enabled,
            "running": self.status.running,
            "bot_username": self.status.bot_username,
            "allowed_chat_count": len(self.alert_chat_ids()),
            "allowed_username_count": len(self.allowed_usernames),
            "last_error": self.status.last_error,
            "last_update_at": self.status.last_update_at,
        }

    async def _poll_loop(self) -> None:
        self.status.running = True
        while not self._closing.is_set():
            try:
                params: dict[str, Any] = {"timeout": self.poll_timeout_seconds, "allowed_updates": json.dumps(["message"])}
                if self._offset is not None:
                    params["offset"] = self._offset
                payload = await self._api("getUpdates", params, timeout=self.poll_timeout_seconds + 10)
                for update in payload.get("result") or []:
                    update_id = int(update.get("update_id") or 0)
                    self._offset = max(self._offset or 0, update_id + 1)
                    await self._handle_update(update)
                self.status.last_error = ""
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                self.status.last_error = str(exc)[:240]
                logger.warning("%s Telegram polling error: %s", self.name, exc)
                await asyncio.sleep(5)
        self.status.running = False

    async def _handle_update(self, update: dict[str, Any]) -> None:
        message = update.get("message") or {}
        chat_id = (message.get("chat") or {}).get("id")
        text = str(message.get("text") or "").strip()
        if chat_id is None or not text:
            return
        try:
            normalized_chat_id = int(chat_id)
        except (TypeError, ValueError):
            return
        self.status.last_update_at = time.time()
        from_user = message.get("from") or {}
        username = self._normalize_username(from_user.get("username"))
        if not self._is_allowed_chat(normalized_chat_id, username):
            logger.warning("%s Telegram rejected unauthorized chat_id=%s username=@%s", self.name, normalized_chat_id, username or "")
            await self.send_message(normalized_chat_id, "This Telegram chat is not allowed for this service.")
            return
        self._learn_recipient(normalized_chat_id, username)
        try:
            reply = await self.handler({"chat_id": normalized_chat_id, "text": text, "message": message, "update": update})
            if reply:
                await self.send_message(normalized_chat_id, reply)
        except Exception as exc:
            logger.exception("%s Telegram handler failed: %s", self.name, exc)
            await self.send_message(normalized_chat_id, "Telegram command failed. Check SwarmPanel logs for details.")

    async def _api(self, method: str, params: dict[str, Any] | None = None, *, timeout: int = 20) -> dict[str, Any]:
        last_error: Exception | None = None
        for attempt in range(3):
            try:
                return await asyncio.to_thread(self._api_sync, method, params or {}, timeout)
            except TelegramRetryAfter as exc:
                last_error = exc
                await asyncio.sleep(min(max(exc.retry_after, 1), 30))
            except TelegramTransientError as exc:
                last_error = exc
                await asyncio.sleep(1.5 * (attempt + 1))
        if last_error:
            raise last_error
        raise RuntimeError(f"Telegram {method} failed")

    def _api_sync(self, method: str, params: dict[str, Any], timeout: int) -> dict[str, Any]:
        url = f"https://api.telegram.org/bot{self.token}/{method}"
        data = urllib.parse.urlencode(params).encode("utf-8") if params else None
        request = urllib.request.Request(url, data=data, method="POST" if data else "GET")
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")[:1000]
            try:
                payload = json.loads(body)
            except json.JSONDecodeError:
                payload = {"ok": False, "description": f"HTTP {exc.code}"}
            description = str(payload.get("description") or f"HTTP {exc.code}")
            if exc.code == 429:
                retry_after = int(((payload.get("parameters") or {}).get("retry_after") or 5))
                raise TelegramRetryAfter(retry_after, description)
            if exc.code >= 500:
                raise TelegramTransientError(description)
            raise RuntimeError(description)
        except urllib.error.URLError as exc:
            raise TelegramTransientError(str(exc.reason)[:240]) from exc
        except TimeoutError as exc:
            raise TelegramTransientError("Telegram API request timed out") from exc
        if not payload.get("ok"):
            description = str(payload.get("description") or f"Telegram {method} failed")
            retry_after = (payload.get("parameters") or {}).get("retry_after")
            if retry_after:
                raise TelegramRetryAfter(int(retry_after), description)
            raise RuntimeError(description)
        return payload

    def _is_allowed_chat(self, chat_id: int, username: str) -> bool:
        if chat_id in self.allowed_chat_ids or chat_id in self._learned_chat_ids:
            return True
        if username and username in self.allowed_usernames:
            return True
        return False

    def _learn_recipient(self, chat_id: int, username: str) -> None:
        if not username or username not in self.allowed_usernames:
            return
        if chat_id in self._learned_chat_ids:
            return
        self._learned_chat_ids.add(chat_id)
        self.status.allowed_chat_count = len(self.alert_chat_ids())
        self._save_learned_recipients()
        logger.info("%s Telegram learned allowed recipient @%s as chat_id=%s", self.name, username, chat_id)

    def _load_learned_recipients(self) -> None:
        if not self.recipient_store_path or not self.recipient_store_path.exists():
            return
        try:
            payload = json.loads(self.recipient_store_path.read_text(encoding="utf-8"))
            for item in payload.get("recipients") or []:
                username = self._normalize_username(item.get("username"))
                chat_id = int(item.get("chat_id"))
                if username in self.allowed_usernames:
                    self._learned_chat_ids.add(chat_id)
        except Exception as exc:
            logger.warning("%s Telegram could not load learned recipients: %s", self.name, exc)

    def _save_learned_recipients(self) -> None:
        if not self.recipient_store_path:
            return
        try:
            self.recipient_store_path.parent.mkdir(parents=True, exist_ok=True)
            existing: list[dict[str, Any]] = []
            if self.recipient_store_path.exists():
                try:
                    existing = list((json.loads(self.recipient_store_path.read_text(encoding="utf-8")).get("recipients") or []))
                except Exception:
                    existing = []
            by_chat: dict[int, dict[str, Any]] = {}
            for item in existing:
                try:
                    chat_id = int(item.get("chat_id"))
                except Exception:
                    continue
                username = self._normalize_username(item.get("username"))
                if username in self.allowed_usernames:
                    by_chat[chat_id] = {"chat_id": chat_id, "username": username, "updated_at": item.get("updated_at") or time.time()}
            for chat_id in self._learned_chat_ids:
                by_chat[chat_id] = {"chat_id": chat_id, "username": next(iter(self.allowed_usernames), ""), "updated_at": time.time()}
            self.recipient_store_path.write_text(json.dumps({"recipients": list(by_chat.values())}, indent=2), encoding="utf-8")
        except Exception as exc:
            logger.warning("%s Telegram could not save learned recipients: %s", self.name, exc)

    @staticmethod
    def _normalize_username(username: Any) -> str:
        return str(username or "").strip().lstrip("@").lower()

    @staticmethod
    def _chunks(text: str, limit: int) -> list[str]:
        chunks: list[str] = []
        remaining = text
        while remaining:
            chunks.append(remaining[:limit])
            remaining = remaining[limit:]
        return chunks[:8]
