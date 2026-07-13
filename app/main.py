import asyncio
import logging
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, Response
from fastapi.staticfiles import StaticFiles
from starlette.middleware.sessions import SessionMiddleware
from starlette.middleware.trustedhost import TrustedHostMiddleware

from . import services as _services_module
from .auth_deps import _schedule_presence_touch
from .paths import BASE_DIR
from .routers import (
    alerts,
    audit,
    bots,
    databases,
    gallery,
    health,
    ios_bridge,
    lumisound,
    monitoring,
    pages,
    queues,
    session,
    swarm_accounts,
    users,
    websocket,
)
from .security import _ensure_allowed_browser_origin, _request_id_for, _security_headers, _trusted_hosts
from .services import action_logger, db, diagnostics_service, discord_service, recent_feed_events, settings, _feed_event
from .telegram import TelegramPollingService
from .telegram_bridge import _handle_telegram_command, _send_panel_telegram_alert, _telegram_health_watch_loop

background_tasks: list[asyncio.Task] = []

METRICS_HISTORY_CAPTURE_INTERVAL_SECONDS = 300  # 5 minutes


async def _metrics_history_capture_loop() -> None:
    """Periodically samples a handful of key fleet metrics into
    swarm_metrics_history for the Intel page's trend charts."""
    await asyncio.sleep(30)
    while True:
        try:
            await db.capture_metrics_snapshot()
        except asyncio.CancelledError:
            raise
        except Exception:
            logging.getLogger("swarm_panel").exception("Metrics history capture failed.")
        try:
            await asyncio.sleep(METRICS_HISTORY_CAPTURE_INTERVAL_SECONDS)
        except asyncio.CancelledError:
            raise


@asynccontextmanager
async def lifespan(_: FastAPI):
    try:
        await db.connect()
    except Exception:
        logging.getLogger("swarm_panel").exception("Initial DB connection failed at startup; endpoints will retry lazily.")
    await discord_service.connect()
    await diagnostics_service.connect()
    background_tasks.clear()
    # Commands execute directly through /api/bots/control. The old command_queue
    # worker is intentionally not started because no endpoint enqueues work.
    background_tasks.append(asyncio.create_task(_telegram_health_watch_loop(), name="panel-telegram-health-watch"))
    background_tasks.append(asyncio.create_task(_metrics_history_capture_loop(), name="panel-metrics-history-capture"))
    recent_feed_events.append(
        _feed_event(
            "info",
            "Event Feed Ready",
            "SwarmPanel live event feed is online.",
            source="system",
        )
    )
    _services_module.telegram_service = TelegramPollingService(
        token=settings.telegram_bot_token,
        name="SwarmPanel",
        handler=_handle_telegram_command,
        allowed_chat_ids=settings.telegram_allowed_chat_ids,
        allowed_usernames=settings.telegram_allowed_usernames,
        recipient_store_path=BASE_DIR / ".runtime" / "telegram_recipients.json",
        commands=[
            ("status", "Swarm overview: bot states and queue counts"),
            ("bots", "List all bots with their control keys"),
            ("sessions", "List live playback sessions"),
            ("diag", "Full diagnostics: DB, Discord, env"),
            ("ping", "Check the bridge is alive"),
            ("id", "Show your Telegram chat id"),
            ("pause", "Pause: /pause <bot_key> <guild_id>"),
            ("resume", "Resume: /resume <bot_key> <guild_id>"),
            ("skip", "Skip track: /skip <bot_key> <guild_id>"),
            ("stop", "Stop playback: /stop <bot_key> <guild_id>"),
            ("leave", "Disconnect from voice: /leave <bot_key> <guild_id>"),
            ("clear", "Clear queue: /clear <bot_key> <guild_id>"),
            ("shuffle", "Shuffle queue: /shuffle <bot_key> <guild_id>"),
            ("restart", "Restart bot node: /restart <bot_key>"),
            ("help", "Show all commands"),
        ],
    )
    if settings.telegram_polling_enabled:
        await _services_module.telegram_service.start()
        await _send_panel_telegram_alert("startup", "SwarmPanel online", "Telegram bridge and panel health watcher are running.")
    else:
        action_logger.info("SwarmPanel Telegram polling is disabled by PANEL_TELEGRAM_POLLING_ENABLED.")
    yield
    # Stop Telegram first so it can flush before the DB pool closes
    if _services_module.telegram_service is not None:
        try:
            await _services_module.telegram_service.close()
        except Exception:
            logging.getLogger("swarm_panel").exception("Error stopping Telegram service during shutdown.")
        _services_module.telegram_service = None
    # Cancel background tasks and wait for them
    for task in background_tasks:
        task.cancel()
    if background_tasks:
        await asyncio.gather(*background_tasks, return_exceptions=True)
    background_tasks.clear()
    await diagnostics_service.close()
    await discord_service.close()
    await db.close()


app = FastAPI(title="SwarmPanel", version="1.0.0", lifespan=lifespan)
app.add_middleware(TrustedHostMiddleware, allowed_hosts=_trusted_hosts())
if settings.cors_allowed_origins or settings.cors_allow_origin_regex:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_allowed_origins,
        allow_origin_regex=settings.cors_allow_origin_regex or None,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )
app.add_middleware(
    SessionMiddleware,
    secret_key=settings.session_secret,
    max_age=60 * 60 * 12,
    same_site="none",
    https_only=settings.session_https_only,
)
app.mount("/static", StaticFiles(directory=str(BASE_DIR / "static")), name="static")


@app.options("/api/{path:path}", include_in_schema=False)
async def api_preflight(path: str):
    return Response(status_code=200)


@app.middleware("http")
async def browser_origin_and_headers(request: Request, call_next):
    started = time.perf_counter()
    request.state.request_id = _request_id_for(request)
    try:
        if request.method.upper() in {"POST", "PUT", "PATCH", "DELETE"}:
            _ensure_allowed_browser_origin(request)
        _schedule_presence_touch(request)
        response = await call_next(request)
    except HTTPException as exc:
        response = JSONResponse({"detail": exc.detail or "Request blocked"}, status_code=exc.status_code)
    elapsed_ms = (time.perf_counter() - started) * 1000
    response.headers.setdefault("X-Response-Time-ms", f"{elapsed_ms:.2f}")
    response.headers.setdefault("Server-Timing", f"app;dur={elapsed_ms:.2f}")
    _security_headers(request, response)
    return response


@app.exception_handler(HTTPException)
async def http_exception_handler(_: Request, exc: HTTPException):
    return JSONResponse(status_code=exc.status_code, content={"detail": exc.detail})


app.include_router(session.router)
app.include_router(pages.router)
app.include_router(users.router)
app.include_router(swarm_accounts.router)
app.include_router(health.router)
app.include_router(bots.router)
app.include_router(databases.router)
app.include_router(lumisound.router)
app.include_router(gallery.router)
app.include_router(websocket.router)
app.include_router(monitoring.router)
app.include_router(audit.router)
app.include_router(alerts.router)
app.include_router(queues.router)
# Defensive: keep the catch-all ios-bridge proxy included last.
app.include_router(ios_bridge.router)
