import { useEffect, useRef } from "react";

export function useLiveRefresh(callback, { enabled = true, interval = 20_000, immediate = false } = {}) {
  const callbackRef = useRef(callback);

  useEffect(() => {
    callbackRef.current = callback;
  }, [callback]);

  useEffect(() => {
    if (!enabled || typeof window === "undefined") return undefined;
    let stopped = false;
    let timer = 0;
    let inFlight = false;
    const safeInterval = Math.max(1_000, Number(interval) || 20_000);

    const run = () => {
      if (stopped || inFlight || document.hidden || navigator.onLine === false) return;
      inFlight = true;
      Promise.resolve(callbackRef.current?.())
        .catch(() => {})
        .finally(() => {
          inFlight = false;
        });
    };

    if (immediate) run();
    timer = window.setInterval(run, safeInterval);
    document.addEventListener("visibilitychange", run);
    window.addEventListener("online", run);

    return () => {
      stopped = true;
      window.clearInterval(timer);
      document.removeEventListener("visibilitychange", run);
      window.removeEventListener("online", run);
    };
  }, [enabled, immediate, interval]);
}
