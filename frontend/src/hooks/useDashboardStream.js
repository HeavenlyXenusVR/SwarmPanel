import { useEffect, useRef } from "react";
import { resolveWebSocketUrl, readToken, forceRefreshRemoteOrigin } from "../api.js";

const RETRY_DELAYS_MS = [1_000, 2_000, 4_000, 8_000];

export function useDashboardStream({ enabled = true, onSnapshot, onError } = {}) {
  const snapshotRef = useRef(onSnapshot);
  const errorRef = useRef(onError);

  useEffect(() => {
    snapshotRef.current = onSnapshot;
  }, [onSnapshot]);

  useEffect(() => {
    errorRef.current = onError;
  }, [onError]);

  useEffect(() => {
    if (!enabled || typeof window === "undefined") return undefined;
    let closed = false;
    let socket = null;
    let retryTimer = 0;
    let retryIndex = 0;

    const clearRetry = () => {
      if (retryTimer) {
        window.clearTimeout(retryTimer);
        retryTimer = 0;
      }
    };

    const scheduleReconnect = () => {
      if (closed || document.hidden || navigator.onLine === false) return;
      clearRetry();
      const delay = RETRY_DELAYS_MS[Math.min(retryIndex, RETRY_DELAYS_MS.length - 1)];
      retryIndex += 1;
      retryTimer = window.setTimeout(() => {
        retryTimer = 0;
        // Invalidate the cached tunnel URL before reconnecting — the WS may
        // have dropped because the Cloudflare tunnel rotated to a new subdomain.
        forceRefreshRemoteOrigin();
        connect();
      }, delay);
    };

    const handleMessage = (event) => {
      try {
        const payload = JSON.parse(event.data);
        if (payload?.type === "ping") {
          // Reply to server keepalive pings so the connection stays alive through
          // Cloudflare/proxy tunnels that close idle connections after ~100 s.
          if (socket && socket.readyState === window.WebSocket.OPEN) {
            socket.send(JSON.stringify({ type: "pong" }));
          }
          return;
        }
        if (payload?.type === "dashboard_snapshot" && payload.data) {
          retryIndex = 0;
          snapshotRef.current?.(payload.data);
        } else if (payload?.type === "dashboard_snapshot_error" && payload.error) {
          errorRef.current?.(payload.error);
        }
      } catch (_error) {
        // Ignore malformed messages and wait for the next snapshot.
      }
    };

    const connect = async () => {
      if (closed || document.hidden || navigator.onLine === false) return;
      try {
        const url = await resolveWebSocketUrl("/ws");
        if (closed) return;
        socket = new window.WebSocket(url);
        socket.addEventListener("open", () => {
          retryIndex = 0;
          // Send API token as the first frame so it stays out of server access logs.
          // Session-cookie users don't need this; the server accepts both auth paths.
          const token = readToken();
          if (token) {
            socket.send(JSON.stringify({ type: "auth", token }));
          }
        });
        socket.addEventListener("message", handleMessage);
        socket.addEventListener("error", () => {
          errorRef.current?.("Live dashboard stream hit a transport error.");
        });
        socket.addEventListener("close", () => {
          socket = null;
          scheduleReconnect();
        });
      } catch (error) {
        errorRef.current?.(error?.message || "Live dashboard stream could not connect.");
        scheduleReconnect();
      }
    };

    const handleVisibility = () => {
      if (document.hidden) {
        clearRetry();
        if (socket && socket.readyState === window.WebSocket.OPEN) socket.close(1000, "hidden");
        return;
      }
      if (!socket || socket.readyState === window.WebSocket.CLOSED) connect();
    };

    const handleOnline = () => {
      retryIndex = 0;
      if (!socket || socket.readyState === window.WebSocket.CLOSED) connect();
    };

    connect();
    document.addEventListener("visibilitychange", handleVisibility);
    window.addEventListener("online", handleOnline);

    return () => {
      closed = true;
      clearRetry();
      document.removeEventListener("visibilitychange", handleVisibility);
      window.removeEventListener("online", handleOnline);
      if (socket && socket.readyState < window.WebSocket.CLOSING) socket.close(1000, "cleanup");
    };
  }, [enabled]);
}
