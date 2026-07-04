"""Shared runtime singletons and cross-cutting infrastructure.

Everything here is referenced by bare module-attribute access from routers,
main.py, and background tasks alike — no FastAPI Depends()/app.state wiring
exists in this codebase (see the refactor plan for why). In particular,
``telegram_service`` is reassigned during app startup (see main.py's
``lifespan``); code that needs its *current* value must do
``from app import services`` and read ``services.telegram_service`` rather
than ``from app.services import telegram_service``, which would bind the
startup ``None`` value forever.
"""

import asyncio
import json
import logging
from collections import deque
from datetime import datetime, timezone
from typing import Any

from .config import load_settings
from .db import PanelDatabase
from .diagnostics import RuntimeDiagnosticsService
from .discord_api import DiscordInventoryService
from .telegram import TelegramPollingService

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
action_logger = logging.getLogger("swarm_panel.actions")

settings = load_settings()
db = PanelDatabase(settings)
discord_service = DiscordInventoryService()
diagnostics_service = RuntimeDiagnosticsService(settings, discord_service)
telegram_service: TelegramPollingService | None = None

# --- Live event feed + websocket broadcast primitives -----------------------
# Shared across domains: the bots router pushes control-action events, the
# monitoring router reads recent_feed_events, and lifespan() announces
# startup/shutdown — none of that is monitoring-only despite living near the
# monitoring routes in the pre-split code.

active_connections: list[dict[str, Any]] = []
recent_feed_events: deque[dict[str, str]] = deque(maxlen=100)
WS_SEND_TIMEOUT_SECONDS = 6.0


def _json_default(obj: Any) -> Any:
    if isinstance(obj, datetime):
        return obj.isoformat()
    raise TypeError(f"Object of type {type(obj).__name__} is not JSON serializable")


def _remove_connection(connection: dict[str, Any]) -> None:
    try:
        active_connections.remove(connection)
    except ValueError:
        pass


async def broadcast(data: dict) -> None:
    dead: list[dict[str, Any]] = []
    serialized = json.dumps(data, default=_json_default)
    for connection in list(active_connections):
        ws = connection.get("websocket")
        if ws is None:
            dead.append(connection)
            continue
        try:
            await asyncio.wait_for(ws.send_text(serialized), timeout=WS_SEND_TIMEOUT_SECONDS)
        except Exception:
            dead.append(connection)
    for connection in dead:
        _remove_connection(connection)


def _feed_event(level: str, title: str, description: str, *, source: str = "panel", event_type: str = "feed_event") -> dict[str, str]:
    return {
        "type": event_type,
        "level": str(level or "info")[:24],
        "title": str(title or "")[:160],
        "description": str(description or "")[:2000],
        "source": str(source or "panel")[:48],
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


async def push_feed_event(
    level: str,
    title: str,
    description: str,
    *,
    source: str = "panel",
    event_type: str = "feed_event",
) -> dict[str, str]:
    event = _feed_event(level, title, description, source=source, event_type=event_type)
    recent_feed_events.append(event)
    await broadcast(event)
    return event
