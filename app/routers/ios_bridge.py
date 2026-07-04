"""Reverse proxy forwarding /ios-bridge/* to the ios_bridge service on port
7333 (no authentication required; the bridge handles its own auth)."""

import os

import httpx as _httpx
from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse, Response

router = APIRouter()

_IOS_BRIDGE_BASE = os.getenv("IOS_BRIDGE_BASE_URL", "http://127.0.0.1:8002")


@router.api_route(
    "/ios-bridge/{path:path}",
    methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"],
    include_in_schema=False,
)
async def proxy_ios_bridge(path: str, request: Request) -> Response:
    url = f"{_IOS_BRIDGE_BASE}/{path}"
    params = dict(request.query_params)
    body = await request.body()
    forward_headers = {
        k: v
        for k, v in request.headers.items()
        if k.lower() not in {"host", "content-length", "transfer-encoding"}
    }
    try:
        async with _httpx.AsyncClient(timeout=30.0) as client:
            resp = await client.request(
                method=request.method,
                url=url,
                params=params,
                headers=forward_headers,
                content=body,
            )
        return Response(
            content=resp.content,
            status_code=resp.status_code,
            headers={k: v for k, v in resp.headers.items() if k.lower() != "transfer-encoding"},
            media_type=resp.headers.get("content-type"),
        )
    except _httpx.ConnectError:
        return JSONResponse({"error": "ios-bridge is offline"}, status_code=503)
    except _httpx.TimeoutException:
        return JSONResponse({"error": "ios-bridge timed out"}, status_code=504)
