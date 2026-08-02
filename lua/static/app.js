// SwarmPanel vanilla-JS runtime -- replaces the React app's client-side
// behavior (hooks/useDashboardStream.js, useLiveRefresh.js, Shell.jsx's
// mobile nav + notifications bell, and various per-page widgets). No
// framework, no build step: this file is served as-is by static.lua.
"use strict";

// ---------------------------------------------------------------------------
// Toast (mirrors App.jsx's ctx.showToast)
// ---------------------------------------------------------------------------
let toastTimer = null;
function swarmToast(message, kind) {
  const el = document.getElementById("toast");
  if (!el) return;
  el.textContent = message;
  el.className = "toast show" + (kind ? " toast-" + kind : "");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.className = "toast"; }, 3600);
}
window.swarmToast = swarmToast;

// ---------------------------------------------------------------------------
// Mobile nav sheet (mirrors Shell.jsx's mobileNavOpen state)
// ---------------------------------------------------------------------------
(function initMobileNav() {
  const toggle = document.querySelector("[data-mobile-nav-toggle]");
  const sheet = document.querySelector("[data-mobile-nav-sheet]");
  const backdrop = document.querySelector("[data-mobile-nav-backdrop]");
  const closeBtn = document.querySelector("[data-mobile-nav-close]");
  if (!toggle || !sheet || !backdrop) return;
  function setOpen(open) {
    sheet.classList.toggle("open", open);
    backdrop.classList.toggle("open", open);
    toggle.classList.toggle("active", open);
    document.body.style.overflow = open ? "hidden" : "";
  }
  toggle.addEventListener("click", (e) => { e.preventDefault(); setOpen(!sheet.classList.contains("open")); });
  backdrop.addEventListener("click", () => setOpen(false));
  if (closeBtn) closeBtn.addEventListener("click", () => setOpen(false));
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") setOpen(false); });
})();

// ---------------------------------------------------------------------------
// Admin-mode toggle (mirrors ctx.switchAdminMode)
// ---------------------------------------------------------------------------
(function initAdminToggle() {
  const btn = document.querySelector("[data-admin-toggle]");
  if (!btn) return;
  btn.addEventListener("click", async () => {
    const enabled = btn.getAttribute("data-admin-toggle") === "1";
    try {
      const res = await fetch("/api/session/admin-mode", {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: "Bearer " + window.SWARM_TOKEN },
        body: JSON.stringify({ enabled }),
      });
      if (!res.ok) throw new Error("request failed");
      window.location.reload();
    } catch {
      swarmToast("Could not switch admin mode.", "error");
    }
  });
})();

// ---------------------------------------------------------------------------
// Generic authenticated fetch helper for page-specific inline scripts.
// ---------------------------------------------------------------------------
async function swarmFetch(path, opts) {
  opts = opts || {};
  const headers = Object.assign({}, opts.headers || {});
  if (window.SWARM_TOKEN) headers.Authorization = "Bearer " + window.SWARM_TOKEN;
  if (opts.body && !headers["Content-Type"]) headers["Content-Type"] = "application/json";
  const res = await fetch(path, Object.assign({}, opts, { headers }));
  if (!res.ok) {
    let detail = res.statusText;
    try { detail = (await res.json()).detail || detail; } catch { /* non-JSON error body */ }
    throw new Error(detail);
  }
  const ct = res.headers.get("content-type") || "";
  return ct.includes("application/json") ? res.json() : res.text();
}
window.swarmFetch = swarmFetch;

// ---------------------------------------------------------------------------
// Visibility/online-aware polling helper (mirrors hooks/useLiveRefresh.js)
// ---------------------------------------------------------------------------
function swarmLiveRefresh(fn, intervalMs) {
  let timer = null;
  let inFlight = false;
  async function tick() {
    if (document.hidden || navigator.onLine === false || inFlight) return;
    inFlight = true;
    try { await fn(); } catch { /* individual pollers handle their own errors */ }
    inFlight = false;
  }
  function start() {
    stop();
    timer = setInterval(tick, intervalMs);
    tick();
  }
  function stop() {
    if (timer) clearInterval(timer);
    timer = null;
  }
  document.addEventListener("visibilitychange", () => { if (!document.hidden) tick(); });
  window.addEventListener("online", tick);
  start();
  return { stop, start, tick };
}
window.swarmLiveRefresh = swarmLiveRefresh;

// ---------------------------------------------------------------------------
// Dashboard WebSocket client (mirrors hooks/useDashboardStream.js). Auth is
// the same {type:"auth", token} first-frame protocol the server already
// implements (routes.lua GET /ws) -- token comes from window.SWARM_TOKEN,
// inlined server-side into the page for exactly this purpose.
// ---------------------------------------------------------------------------
function swarmDashboardStream(onMessage) {
  let ws = null;
  let attempt = 0;
  let closedByUs = false;

  function connect() {
    if (!window.SWARM_TOKEN) return;
    const proto = window.location.protocol === "https:" ? "wss:" : "ws:";
    ws = new WebSocket(proto + "//" + window.location.host + "/ws");
    ws.addEventListener("open", () => {
      attempt = 0;
      ws.send(JSON.stringify({ type: "auth", token: window.SWARM_TOKEN }));
    });
    ws.addEventListener("message", (event) => {
      let msg;
      try { msg = JSON.parse(event.data); } catch { return; }
      if (msg.type === "ping") { ws.send(JSON.stringify({ type: "pong" })); return; }
      onMessage(msg);
    });
    ws.addEventListener("close", () => {
      if (closedByUs || document.hidden) return;
      const delay = Math.min(8000, 1000 * Math.pow(2, attempt));
      attempt += 1;
      setTimeout(() => { if (!document.hidden) connect(); }, delay);
    });
    ws.addEventListener("error", () => { try { ws.close(); } catch { /* already closing */ } });
  }

  document.addEventListener("visibilitychange", () => {
    if (document.hidden) return;
    if (!ws || ws.readyState === WebSocket.CLOSED) connect();
  });
  window.addEventListener("online", () => {
    if (!ws || ws.readyState === WebSocket.CLOSED) connect();
  });

  connect();
  return { close() { closedByUs = true; if (ws) ws.close(); } };
}
window.swarmDashboardStream = swarmDashboardStream;

// ---------------------------------------------------------------------------
// Live playback position readout (mirrors swarm.jsx's PlaybackCounter):
// ticks locally every 1s from a server-reported position_seconds +
// position_observed_at, so the number/bar advances smoothly between polls.
// Element contract: <span data-playback-counter data-position="123"
//   data-observed-at="1785600000" data-duration="240" data-playing="true">
// ---------------------------------------------------------------------------
function formatDuration(totalSeconds) {
  totalSeconds = Math.max(0, Math.floor(totalSeconds || 0));
  const m = Math.floor(totalSeconds / 60);
  const s = totalSeconds % 60;
  return m + ":" + String(s).padStart(2, "0");
}
window.swarmFormatDuration = formatDuration;

function tickPlaybackCounters() {
  document.querySelectorAll("[data-playback-counter]").forEach((el) => {
    const playing = el.getAttribute("data-playing") === "true";
    const basePos = parseFloat(el.getAttribute("data-position") || "0");
    const observedAt = parseFloat(el.getAttribute("data-observed-at") || "0");
    const duration = parseFloat(el.getAttribute("data-duration") || "0");
    let pos = basePos;
    if (playing && observedAt) pos = basePos + (Date.now() / 1000 - observedAt);
    pos = Math.max(0, duration ? Math.min(pos, duration) : pos);
    const label = el.querySelector("[data-playback-label]");
    if (label) label.textContent = formatDuration(pos) + (duration ? " / " + formatDuration(duration) : "");
    const bar = el.querySelector("[data-playback-bar]");
    if (bar && duration) bar.style.width = Math.min(100, (pos / duration) * 100) + "%";
  });
}
setInterval(tickPlaybackCounters, 1000);
document.addEventListener("DOMContentLoaded", tickPlaybackCounters);

// ---------------------------------------------------------------------------
// Drag-to-seek bar (mirrors swarm.jsx's BotSeekBar). Element contract:
// <div data-seek-bar data-bot-key="..." data-guild-id="..." data-duration="240">
//   <div data-playback-bar></div>
// </div>
// Posts SEEK via /api/bots/control on release.
// ---------------------------------------------------------------------------
(function initSeekBars() {
  document.addEventListener("mousedown", (e) => {
    const bar = e.target.closest("[data-seek-bar]");
    if (!bar) return;
    const duration = parseFloat(bar.getAttribute("data-duration") || "0");
    if (!duration) return;
    bar.classList.add("dragging");
    function fractionFromEvent(evt) {
      const rect = bar.getBoundingClientRect();
      return Math.min(1, Math.max(0, (evt.clientX - rect.left) / rect.width));
    }
    function onMove(evt) {
      const frac = fractionFromEvent(evt);
      const fill = bar.querySelector("[data-playback-bar]");
      if (fill) fill.style.width = frac * 100 + "%";
    }
    function onUp(evt) {
      document.removeEventListener("mousemove", onMove);
      document.removeEventListener("mouseup", onUp);
      bar.classList.remove("dragging");
      const frac = fractionFromEvent(evt);
      const seconds = Math.round(frac * duration);
      swarmFetch("/api/bots/control", {
        method: "POST",
        body: JSON.stringify({
          bot_key: bar.getAttribute("data-bot-key"),
          guild_id: bar.getAttribute("data-guild-id"),
          action: "SEEK",
          payload: { position_seconds: seconds },
        }),
      }).catch(() => swarmToast("Seek failed.", "error"));
    }
    document.addEventListener("mousemove", onMove);
    document.addEventListener("mouseup", onUp);
  });
})();

// ---------------------------------------------------------------------------
// Debounced search input helper. Element contract:
// <input data-debounced-search data-search-target="#results">, dispatches a
// "swarm:search" CustomEvent with {detail:{query}} on the input after 220ms.
// ---------------------------------------------------------------------------
(function initDebouncedSearch() {
  document.querySelectorAll("[data-debounced-search]").forEach((input) => {
    let timer = null;
    input.addEventListener("input", () => {
      clearTimeout(timer);
      timer = setTimeout(() => {
        input.dispatchEvent(new CustomEvent("swarm:search", { detail: { query: input.value }, bubbles: true }));
      }, 220);
    });
  });
})();

// ---------------------------------------------------------------------------
// Bulk-select table helper (mirrors DataTable's selection support). Element
// contract: a table with [data-select-all] checkbox in <thead>, and
// [data-select-row] checkboxes in <tbody>; toggles a
// [data-bulk-actions][hidden] bar and exposes window.swarmSelectedIds(table).
// ---------------------------------------------------------------------------
(function initBulkSelect() {
  document.querySelectorAll("[data-select-all]").forEach((selectAll) => {
    const table = selectAll.closest("table");
    if (!table) return;
    const rowBoxes = () => table.querySelectorAll("[data-select-row]");
    const bar = document.querySelector(selectAll.getAttribute("data-bulk-actions-target") || "[data-bulk-actions]");
    function refreshBar() {
      const anyChecked = Array.from(rowBoxes()).some((b) => b.checked);
      if (bar) bar.hidden = !anyChecked;
    }
    selectAll.addEventListener("change", () => {
      rowBoxes().forEach((b) => { b.checked = selectAll.checked; });
      refreshBar();
    });
    table.addEventListener("change", (e) => {
      if (e.target.matches("[data-select-row]")) refreshBar();
    });
  });
})();
window.swarmSelectedIds = function (table) {
  return Array.from(table.querySelectorAll("[data-select-row]:checked")).map((b) => b.value);
};

// ---------------------------------------------------------------------------
// Remote-origin/tunnel discovery is intentionally NOT ported: the Lua-
// rendered UI is always served same-origin by the backend itself (no
// separate static hosting), so there is no tunnel-origin indirection to
// resolve.
// ---------------------------------------------------------------------------
