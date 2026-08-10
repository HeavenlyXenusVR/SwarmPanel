// SwarmPanel vanilla-JS runtime -- replaces the React app's client-side
// behavior (hooks/useDashboardStream.js, useLiveRefresh.js, Shell.jsx's
// mobile nav + notifications bell, and various per-page widgets). No
// framework, no build step: this file is served as-is by static.lua.
//
// Loaded from <head> (see html.lua's layout()) so every function/global
// defined below exists before any page-specific inline <script> later in
// the body runs. That means everything in this top section must be safe to
// define before the DOM exists -- no top-level querySelector calls here.
// Anything that actually touches the DOM at *definition* time (not just
// when later called) is pushed down into the DOMContentLoaded block at the
// bottom instead.
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
// Rich table cell formatting for the generic schema-table browsers
// (Databases, Gallery Admin) -- table-number/table-mono/table-cell-* had CSS
// (tabular-nums for numbers, monospace + wrap-anywhere for id/hash-looking
// values) but every raw-table renderer just String()'d every cell the same
// way, so a UUID and a display name looked identical.
// ---------------------------------------------------------------------------
const SWARM_MONO_COLUMN_RE = /(^id$|_id$|_hash$|_token$|_uuid$|^uuid$)/i;
function swarmTableCell(colName, rawValue) {
  const text = String(rawValue ?? "").replace(/</g, "&lt;");
  if (rawValue !== null && rawValue !== "" && !Number.isNaN(Number(rawValue)) && typeof rawValue !== "boolean") {
    return `<td class="table-cell-number"><span class="table-number">${text}</span></td>`;
  }
  if (SWARM_MONO_COLUMN_RE.test(colName)) {
    return `<td class="table-cell-mono"><span class="table-mono">${text}</span></td>`;
  }
  return `<td>${text}</td>`;
}
window.swarmTableCell = swarmTableCell;

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

// The backend hands over position_observed_at as a raw Postgres
// "YYYY-MM-DD HH:MM:SS[.ffffff]" string (UTC, no offset marker) via the
// data-observed-at attribute. That format is NOT what it looks like to
// parseFloat() -- parseFloat("2026-08-02 20:40:05...") reads "2026" and
// stops at the first "-", so every counter was computing its elapsed time
// against the literal number 2026 instead of a real timestamp, producing
// an astronomically large (~56-year) delta that got clamped straight to
// the track's duration -- every playback counter showed the end of the
// track regardless of actual position. Convert to ISO-8601 with an
// explicit "Z" first so Date.parse() treats it as UTC correctly.
function parseSqlTimestampSeconds(raw) {
  if (!raw) return 0;
  let iso = raw.indexOf("T") === -1 ? raw.replace(" ", "T") : raw;
  // Some rows already carry a Postgres-style "+00" (or "+00:00") offset
  // suffix instead of the bare "YYYY-MM-DD HH:MM:SS" this was written for;
  // blindly appending "Z" onto those produced an invalid string like
  // "...+00Z" that Date.parse() rejects, so the counter never ticks at all
  // (basePos is used as-is forever). Only append "Z" when there's no
  // existing offset/zone marker already at the end.
  if (!/(?:Z|[+-]\d\d(?::?\d\d)?)$/.test(iso)) iso += "Z";
  const ms = Date.parse(iso);
  return Number.isFinite(ms) ? ms / 1000 : 0;
}

function tickPlaybackCounters() {
  document.querySelectorAll("[data-playback-counter]").forEach((el) => {
    const playing = el.getAttribute("data-playing") === "true";
    const basePos = parseFloat(el.getAttribute("data-position") || "0");
    const observedAt = parseSqlTimestampSeconds(el.getAttribute("data-observed-at"));
    const duration = parseFloat(el.getAttribute("data-duration") || "0");
    let pos = basePos;
    if (playing && observedAt) pos = basePos + (Date.now() / 1000 - observedAt);
    pos = Math.max(0, duration ? Math.min(pos, duration) : pos);
    const label = el.querySelector("[data-playback-label]");
    if (label) label.textContent = formatDuration(pos) + (duration ? " / " + formatDuration(duration) : "");
    const pct = duration ? Math.min(100, (pos / duration) * 100) : 0;
    const bar = el.querySelector("[data-playback-bar]");
    if (bar && duration) bar.style.width = pct + "%";
    const thumb = el.querySelector("[data-seek-thumb]");
    if (thumb && duration) thumb.style.left = pct + "%";
    const current = el.querySelector("[data-seek-current]");
    if (current) current.textContent = formatDuration(pos);
    const total = el.querySelector("[data-seek-duration]");
    if (total) total.textContent = duration ? formatDuration(duration) : "--:--";
  });
}
setInterval(tickPlaybackCounters, 1000);

window.swarmSelectedIds = function (table) {
  return Array.from(table.querySelectorAll("[data-select-row]:checked")).map((b) => b.value);
};

// ---------------------------------------------------------------------------
// Everything below touches the DOM at init time, so it has to wait for the
// document to actually be parsed -- unlike the pure function/global
// definitions above, none of this is safe to run from <head>.
// ---------------------------------------------------------------------------
document.addEventListener("DOMContentLoaded", () => {
  tickPlaybackCounters();

  // Mobile nav sheet (mirrors Shell.jsx's mobileNavOpen state)
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

  // Admin-mode toggle (mirrors ctx.switchAdminMode)
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

  // Drag-to-seek bar (mirrors swarm.jsx's BotSeekBar). Element contract:
  // <div data-seek-bar data-bot-key="..." data-guild-id="..." data-duration="240">
  //   <div data-playback-bar></div>
  // </div>
  // Posts SEEK via /api/bots/control on release. Uses event delegation
  // (document-level mousedown) so it also works for seek bars added to the
  // page later via innerHTML, not just ones present at DOMContentLoaded.
  document.addEventListener("mousedown", (e) => {
    const bar = e.target.closest("[data-seek-bar]");
    if (!bar) return;
    const duration = parseFloat(bar.getAttribute("data-duration") || "0");
    if (!duration) return;
    // CSS's hover/active thumb-reveal rule is keyed off .bot-seek-seeking
    // (static/app.css), not .dragging -- the thumb never actually got shown
    // while dragging before this matched the class name up.
    bar.classList.add("bot-seek-seeking");
    function fractionFromEvent(evt) {
      const rect = bar.getBoundingClientRect();
      return Math.min(1, Math.max(0, (evt.clientX - rect.left) / rect.width));
    }
    function onMove(evt) {
      const frac = fractionFromEvent(evt);
      const pct = frac * 100 + "%";
      const fill = bar.querySelector("[data-playback-bar]");
      if (fill) fill.style.width = pct;
      const thumb = bar.querySelector("[data-seek-thumb]");
      if (thumb) thumb.style.left = pct;
      const current = bar.parentElement && bar.parentElement.querySelector("[data-seek-current]");
      if (current) current.textContent = formatDuration(frac * duration);
    }
    function onUp(evt) {
      document.removeEventListener("mousemove", onMove);
      document.removeEventListener("mouseup", onUp);
      bar.classList.remove("bot-seek-seeking");
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

  // Generic copy-to-clipboard button. Element contract:
  // <button data-copy-target="#some-input-or-element-id">Copy</button>
  // Delegated so it works for buttons added dynamically after
  // DOMContentLoaded too.
  document.addEventListener("click", (e) => {
    const btn = e.target.closest("[data-copy-target]");
    if (!btn) return;
    const target = document.querySelector(btn.getAttribute("data-copy-target"));
    if (!target) return;
    const text = "value" in target ? target.value : target.textContent;
    navigator.clipboard.writeText(text || "").then(
      () => swarmToast("Copied.", "success"),
      () => swarmToast("Copy failed.", "error")
    );
  });

  // Debounced search input helper. Element contract:
  // <input data-debounced-search>, dispatches a "swarm:search" CustomEvent
  // with {detail:{query}} on the input after 220ms. Delegated so inputs
  // added dynamically after DOMContentLoaded still work.
  document.addEventListener("input", (e) => {
    if (!e.target.matches("[data-debounced-search]")) return;
    const input = e.target;
    clearTimeout(input._swarmSearchTimer);
    input._swarmSearchTimer = setTimeout(() => {
      input.dispatchEvent(new CustomEvent("swarm:search", { detail: { query: input.value }, bubbles: true }));
    }, 220);
  });

  // Bulk-select table helper (mirrors DataTable's selection support).
  // Delegated (change events bubble) so it works for tables rendered
  // dynamically via innerHTML after a swarmFetch, not just ones present at
  // DOMContentLoaded -- most of the admin tables that use this are exactly
  // that case.
  document.addEventListener("change", (e) => {
    const table = e.target.closest("table");
    if (!table) return;
    if (e.target.matches("[data-select-all]")) {
      table.querySelectorAll("[data-select-row]").forEach((b) => { b.checked = e.target.checked; });
    }
    if (e.target.matches("[data-select-all], [data-select-row]")) {
      const bar = document.querySelector("[data-bulk-actions]");
      if (bar) {
        const anyChecked = Array.from(table.querySelectorAll("[data-select-row]")).some((b) => b.checked);
        bar.hidden = !anyChecked;
      }
    }
  });

  // Notifications bell (mirrors Shell.jsx's notifications dropdown; backend
  // was fully wired via social.lua/routes.lua's /api/notifications* -- this
  // was the only piece missing).
  (function initNotifications() {
    const btn = document.getElementById("notif-bell-btn");
    const dropdown = document.getElementById("notif-dropdown");
    const backdrop = document.getElementById("notif-backdrop");
    const badge = document.getElementById("notif-badge");
    const list = document.getElementById("notif-list");
    const markAllBtn = document.getElementById("notif-mark-all");
    if (!btn || !dropdown || !backdrop || !badge || !list) return;

    function setOpen(open) {
      dropdown.hidden = !open;
      backdrop.hidden = !open;
      btn.setAttribute("aria-expanded", open ? "true" : "false");
      if (open) loadNotifications();
    }
    btn.addEventListener("click", () => setOpen(dropdown.hidden));
    backdrop.addEventListener("click", () => setOpen(false));

    function timeAgo(iso) {
      const ts = Date.parse(iso);
      if (Number.isNaN(ts)) return "";
      const seconds = Math.max(0, Math.floor((Date.now() - ts) / 1000));
      if (seconds < 60) return seconds + "s ago";
      if (seconds < 3600) return Math.floor(seconds / 60) + "m ago";
      if (seconds < 86400) return Math.floor(seconds / 3600) + "h ago";
      return Math.floor(seconds / 86400) + "d ago";
    }

    async function refreshUnreadCount() {
      try {
        const res = await swarmFetch("/api/notifications/unread-count");
        const count = res.unread_count || 0;
        badge.hidden = count <= 0;
        badge.textContent = count > 99 ? "99+" : String(count);
        btn.classList.toggle("has-unread", count > 0);
      } catch { /* ignore */ }
    }

    async function loadNotifications() {
      try {
        const res = await swarmFetch("/api/notifications?limit=30");
        const items = res.notifications || [];
        list.innerHTML = items.length ? items.map((n) => `
          <li>
            <button type="button" class="notifications-item${n.read_at ? "" : " unread"}" data-notif-id="${n.id}" data-notif-link="${(n.link_path || "").replace(/"/g, "&quot;")}">
              <span class="notifications-item-title">${(n.title || "").replace(/</g, "&lt;")}</span>
              ${n.body ? `<span class="notifications-item-body">${n.body.replace(/</g, "&lt;")}</span>` : ""}
              <span class="notifications-item-time">${timeAgo(n.created_at)}</span>
            </button>
          </li>`).join("") : '<li class="notifications-empty">No notifications yet.</li>';
      } catch {
        list.innerHTML = '<li class="notifications-empty">Failed to load notifications.</li>';
      }
    }

    list.addEventListener("click", async (e) => {
      const item = e.target.closest("[data-notif-id]");
      if (!item) return;
      const id = item.getAttribute("data-notif-id");
      const link = item.getAttribute("data-notif-link");
      try { await swarmFetch(`/api/notifications/${id}/read`, { method: "POST" }); } catch { /* ignore */ }
      refreshUnreadCount();
      if (link) window.location = link;
    });

    if (markAllBtn) {
      markAllBtn.addEventListener("click", async () => {
        try { await swarmFetch("/api/notifications/read-all", { method: "POST" }); } catch { /* ignore */ }
        loadNotifications();
        refreshUnreadCount();
      });
    }

    swarmLiveRefresh(refreshUnreadCount, 30000);
  })();
});
