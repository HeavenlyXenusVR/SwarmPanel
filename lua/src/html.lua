-- Server-rendered HTML helpers for the Lua-only SwarmPanel UI (replaces the
-- React/Vite frontend). No templating engine is vendored (see the backend
-- audit) so this is plain Lua string-building with an explicit escaping
-- helper -- every value interpolated into HTML from user/DB data MUST go
-- through esc()/attr() or it's an XSS hole.

local M = {}

local function cjson_encode_safe(v)
  local ok, cjson = pcall(require, "cjson.safe")
  if not ok then return tostring(v) end
  local encoded = cjson.encode(v)
  return encoded or tostring(v)
end

local ESCAPE_MAP = {
  ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;",
  ['"'] = "&quot;", ["'"] = "&#39;",
}

-- HTML-escapes a value for use in element text content or (quoted)
-- attribute values. nil/false/number all coerce to string first.
function M.esc(v)
  if v == nil then return "" end
  if type(v) == "boolean" then v = tostring(v) end
  return (tostring(v):gsub('[&<>"\']', ESCAPE_MAP))
end

-- Builds a double-quoted, escaped HTML attribute: attr("href", url) -> ' href="..."'
-- Returns "" (not even a space) when value is nil/false/empty, so optional
-- attributes can be spliced in without conditional string-building at call
-- sites: ("<a" .. attr("href", url) .. ">")
function M.attr(name, value)
  if value == nil or value == false or value == "" then return "" end
  return (" %s=\"%s\""):format(name, M.esc(value))
end

-- Boolean HTML attribute (checked/disabled/open/...): only emitted when truthy.
function M.battr(name, truthy)
  if not truthy then return "" end
  return " " .. name
end

-- Joins an array of HTML-string fragments with no separator -- the common
-- case for building a list of rendered rows/cards.
function M.join(parts)
  return table.concat(parts, "")
end

-- classNames-style helper: html.cls({"nav-item", active and "active"}) -> "nav-item active"
function M.cls(parts)
  local out = {}
  for _, p in ipairs(parts) do
    if p and p ~= "" then out[#out + 1] = p end
  end
  return table.concat(out, " ")
end

-- ---------------------------------------------------------------------------
-- Nav model (mirrors frontend/src/components/Shell.jsx's navItems list)
-- ---------------------------------------------------------------------------

local NAV_ITEMS = {
  { to = "/", label = "Dashboard", glyph = "◧" },
  { to = "/controls", label = "Controls", glyph = "▶" },
  { to = "/leaderboard", label = "Leaderboard", glyph = "🏆" },
  { to = "/invites", label = "Invites", glyph = "🔗" },
  { to = "/users", label = "Users", glyph = "👥" },
  { to = "/friends", label = "Friends", glyph = "🙂" },
  { to = "/messages", label = "Messages", glyph = "✉" },
  { to = "/profile", label = "Profile", glyph = "◑" },
  { to = "/appearance", label = "Look", glyph = "◈" },
}
local NAV_ADMIN_ITEMS = {
  { to = "/diagnostics", label = "Diagnostics", glyph = "♥", when = "admin" },
  { to = "/accounts", label = "Accounts", glyph = "☺", when = "admin" },
  { to = "/databases", label = "Data", glyph = "▤", when = "admin" },
  { to = "/gallery-admin", label = "Gallery", glyph = "▦", when = "gallery" },
  { to = "/lumisound-admin", label = "Lumisound", glyph = "♪", when = "mod" },
  { to = "/intel", label = "Intel", glyph = "⚠", when = "admin" },
  { to = "/audit-log", label = "Audit Log", glyph = "☰", when = "mod" },
}

local function nav_items_for(session)
  local items = {}
  for _, item in ipairs(NAV_ITEMS) do items[#items + 1] = item end
  for _, item in ipairs(NAV_ADMIN_ITEMS) do
    local show = (item.when == "admin" and session.admin_mode)
      or (item.when == "gallery" and session.image_gallery_owner)
      or (item.when == "mod" and (session.admin_mode or session.moderator))
    if show then items[#items + 1] = item end
  end
  return items
end

local function is_active(pathname, to)
  if to == "/" then return pathname == "/" end
  return pathname == to or pathname:sub(1, #to + 1) == to .. "/"
end

-- Mirrors Shell.jsx's mobilePrimaryItems/mobileSecondaryItems split: the
-- mobile bottom bar only has room for ~5 icons + a "More" launcher, not
-- all 9-16 nav items -- rendering the full list there (as this used to)
-- breaks the CSS's fixed 6-column bottom-bar layout into a multi-row block
-- that eats half the viewport.
local MOBILE_PRIMARY_PATHS = { ["/"] = true, ["/controls"] = true, ["/users"] = true, ["/messages"] = true, ["/profile"] = true }

-- filter: nil = all items (desktop nav), "primary" = the 5 mobile-primary
-- items, "secondary" = everything else (the mobile "More" sheet).
local function render_nav(session, pathname, variant, filter)
  local out = {}
  for _, item in ipairs(nav_items_for(session)) do
    local include = true
    if filter == "primary" then include = MOBILE_PRIMARY_PATHS[item.to] == true
    elseif filter == "secondary" then include = MOBILE_PRIMARY_PATHS[item.to] ~= true end
    if include then
      out[#out + 1] = ('<a class="%s" href="%s"><span class="nav-glyph">%s</span><span>%s</span></a>'):format(
        M.cls({ "nav-item", variant, is_active(pathname, item.to) and "active" or nil }),
        M.esc(item.to), item.glyph, M.esc(item.label))
    end
  end
  return table.concat(out, "")
end

-- ---------------------------------------------------------------------------
-- Appearance / theming (mirrors frontend/src/config.js DEFAULT_PREFERENCES
-- and utils/control.js panelClassName()/panelStyle()) -- CSS was ported
-- verbatim to static/app.css, so it still expects this exact combinatorial
-- class-name system on the root wrapper.
-- ---------------------------------------------------------------------------

M.DEFAULT_PREFERENCES = {
  theme_mode = "dark", accent_color = "#89b4fa", accent_secondary = "",
  background_mode = "default", layout_mode = "standard", density = "comfortable",
  card_shape = "soft", font_scale = "normal", motion = "standard",
  operator_layout = "command", roster_layout = "cards", tab_style = "rail",
  stream_card_style = "telemetry", dashboard_density = "command",
  card_hover_effect = "lift", notification_position = "br",
  surface_opacity = 0.92, surface_blur = 18,
}

local function choice(prefs, key, fallback)
  local v = prefs and prefs[key]
  if v == nil or v == "" then return fallback end
  return v
end

function M.panel_class(prefs)
  prefs = prefs or M.DEFAULT_PREFERENCES
  local notify_pos = choice(prefs, "notification_position", "br")
  return M.cls({
    "app-shell",
    "panel-theme-" .. choice(prefs, "theme_mode", "dark"),
    "panel-bg-" .. choice(prefs, "background_mode", "default"),
    "panel-layout-" .. choice(prefs, "layout_mode", "standard"),
    "panel-density-" .. choice(prefs, "density", "comfortable"),
    "panel-shape-" .. choice(prefs, "card_shape", "soft"),
    "panel-font-" .. choice(prefs, "font_scale", "normal"),
    "panel-motion-" .. choice(prefs, "motion", "standard"),
    "panel-operator-" .. choice(prefs, "operator_layout", "command"),
    "panel-roster-" .. choice(prefs, "roster_layout", "cards"),
    "panel-tabs-" .. choice(prefs, "tab_style", "rail"),
    "panel-stream-" .. choice(prefs, "stream_card_style", "telemetry"),
    "panel-dashboard-" .. choice(prefs, "dashboard_density", "command"),
    "panel-hover-" .. choice(prefs, "card_hover_effect", "lift"),
    -- App.jsx applied notification_position as a SEPARATE class from
    -- panelClassName()'s output (only added when non-default) -- matches
    -- that exactly rather than folding it into a "panel-notify-br" no-op.
    -- NOTE: every entry here must be a string (never bare `nil`) -- M.cls
    -- iterates with ipairs(), which stops dead at the first hole in the
    -- array, silently dropping every class listed after it. "" is the
    -- correct "omit this one" value; M.cls already filters empty strings.
    (notify_pos ~= "br") and ("panel-notify-" .. notify_pos) or "",
    -- The following were saved/round-tripped by profiles.lua's
    -- clean_panel_preferences and editable on /appearance, but had NO
    -- class wiring anywhere -- not even in the original pre-rewrite React
    -- app (verified via git history) -- so changing them never did
    -- anything. Giving them real, if new, effect per the corresponding
    -- CSS added below.
    "panel-radius-" .. choice(prefs, "panel_radius", "medium"),
    "panel-fontfamily-" .. choice(prefs, "panel_font_family", "system"),
    "panel-nav-" .. choice(prefs, "sidebar_style", "full"),
    "panel-detail-" .. choice(prefs, "bot_card_detail", "full"),
    (prefs.show_bot_uptime == false) and "panel-hide-uptime" or "",
    (prefs.show_queue_pressure == false) and "panel-hide-queue-pressure" or "",
    (prefs.compact_sidebar == true) and "panel-compact-nav" or "",
  })
end

local BACKGROUND_PRESETS = {
  default = "#0d1117", midnight = "#090b12", aurora = "#101821", ember = "#17100d",
}

local function safe_hex(value, fallback)
  if type(value) == "string" and value:match("^#%x%x%x%x%x%x$") then return value end
  return fallback
end

local function clamp_number(value, fallback, min, max)
  local n = tonumber(value)
  if not n then return fallback end
  if n < min then return min end
  if n > max then return max end
  return n
end

local function css_url(value)
  -- Matches utils/control.js's safeImage()/panelStyle() -- only http(s)
  -- URLs are trusted into a CSS url(); escapes quotes/backslashes so a
  -- crafted background_image_url can't break out of the string literal.
  local text = tostring(value or ""):match("^%s*(.-)%s*$")
  if not text:match("^https?://") then return "none" end
  return ('url("%s")'):format(text:gsub('([\\"])', '\\%1'))
end

-- Was only setting --surface-opacity/--surface-blur/--accent -- --bg (the
-- background_mode preset/custom_color) and --panel-bg-image
-- (background_image_url, custom_image mode) are both referenced by
-- app.css's .app-shell::before/.panel-bg-* rules but were never actually
-- set anywhere, so background_mode="custom_image" plus a saved image URL
-- silently did nothing. Mirrors utils/control.js's panelStyle() exactly.
function M.panel_style(prefs)
  prefs = prefs or M.DEFAULT_PREFERENCES
  local mode = choice(prefs, "background_mode", "default")
  local base_bg = (mode == "custom_color") and safe_hex(prefs.background_color, "#0b0e18")
    or (BACKGROUND_PRESETS[mode] or BACKGROUND_PRESETS.default)
  local use_image = (mode == "custom_image") and tostring(prefs.background_image_url or ""):match("^%s*https?://")
  local parts = {
    ("--accent:%s"):format(safe_hex(prefs.accent_color, "#89b4fa")),
    ("--bg:%s"):format(base_bg),
    ("--panel-bg-image:%s"):format(use_image and css_url(prefs.background_image_url) or "none"),
    ("--surface-opacity:%s"):format(tostring(clamp_number(prefs.surface_opacity, 0.92, 0.35, 1))),
    ("--surface-blur:%spx"):format(tostring(clamp_number(prefs.surface_blur, 18, 0, 36))),
  }
  if prefs.accent_contrast_text and prefs.accent_contrast_text ~= "" then
    parts[#parts + 1] = "--accent-contrast-text:" .. safe_hex(prefs.accent_contrast_text, "#ffffff")
  end
  if prefs.accent_gradient and prefs.accent_gradient ~= "" then
    parts[#parts + 1] = "--accent-gradient:" .. prefs.accent_gradient
  end
  return table.concat(parts, ";")
end

-- ---------------------------------------------------------------------------
-- Page shell (mirrors Shell.jsx's topbar/nav/footer chrome)
-- ---------------------------------------------------------------------------

-- opts: { title, path, session (from get_auth-shaped table or nil),
--         body (HTML string), head_extra (HTML string, optional), token }
-- session.username/admin_mode/site_owner/moderator/image_gallery_owner drive
-- the nav + session-bar exactly like ctx.isAdmin/isOwner/etc in Shell.jsx.
-- `token` is only used to seed window.SWARM_TOKEN for the dashboard
-- WebSocket's existing {type:"auth", token} first-frame protocol (see
-- routes.lua's /ws handler) -- it is never rendered anywhere visible and
-- never sent anywhere except that one same-origin WS connection.
function M.layout(opts)
  local session = opts.session or { authenticated = false }
  local authed = session.authenticated
  local username = session.username or "Operator"
  local initial = username:sub(1, 1):upper()

  local notif_bell = authed and [[
      <div class="notifications-bell">
        <button class="icon-button" type="button" id="notif-bell-btn" title="Notifications" aria-haspopup="true" aria-expanded="false">
          &#128276;<span class="notifications-badge" id="notif-badge" hidden>0</span>
        </button>
        <div class="notifications-backdrop" id="notif-backdrop" hidden></div>
        <div class="notifications-dropdown" id="notif-dropdown" hidden>
          <div class="notifications-dropdown-head">
            <strong>Notifications</strong>
            <button type="button" id="notif-mark-all">Mark all read</button>
          </div>
          <ul class="notifications-list" id="notif-list"></ul>
        </div>
      </div>
    ]] or ""

  local session_bar
  if authed then
    session_bar = ([[
      <span class="mode-pill%s">%s</span>
      %s
      %s
      <a class="profile-link" href="/profile"><span class="profile-link-badge">%s</span><span>%s</span></a>
      <form method="POST" action="/logout" class="logout-form"><button class="icon-button" type="submit" title="Logout">&#8677;</button></form>
    ]]):format(
      session.admin_mode and " admin" or "", session.admin_mode and "Admin" or "User",
      session.site_owner and ([[<button class="mode-toggle%s" type="button" data-admin-toggle="%s">%s</button>]]):format(
        session.admin_mode and " active" or "", session.admin_mode and "0" or "1",
        session.admin_mode and "Admin On" or "Admin Off") or "",
      notif_bell,
      M.esc(initial), M.esc(username))
  elseif opts.path ~= "/login" then
    session_bar = '<a class="button-link primary" href="/login">&#8676; Login</a>'
  else
    session_bar = ""
  end

  local nav_desktop = authed and ('<nav class="nav nav-desktop" aria-label="Main">' .. render_nav(session, opts.path, "") .. "</nav>") or "<div></div>"
  local mobile_nav = ""
  if authed then
    mobile_nav = ([[
      <nav class="nav nav-mobile" aria-label="Mobile Main">%s
        <a class="nav-item mobile-nav-launcher" href="#" data-mobile-nav-toggle><span class="nav-glyph">&#9776;</span><span>More</span></a>
      </nav>
      <div class="mobile-nav-backdrop" data-mobile-nav-backdrop></div>
      <aside class="mobile-nav-sheet" data-mobile-nav-sheet>
        <div class="mobile-nav-sheet-head">
          <div><strong>Command Access</strong><p>Jump to the rest of the panel.</p></div>
          <button type="button" data-mobile-nav-close>Close</button>
        </div>
        <div class="mobile-session-chip"><span class="mode-pill%s">%s</span><span>%s</span></div>
        <nav class="mobile-nav-list" aria-label="More Navigation">%s</nav>
      </aside>
    ]]):format(render_nav(session, opts.path, "mobile-primary", "primary"),
      session.admin_mode and " admin" or "", session.admin_mode and "Admin" or "User", M.esc(username),
      render_nav(session, opts.path, "", "secondary"))
  end

  local prefs = opts.preferences or M.DEFAULT_PREFERENCES

  return ([[<!doctype html>
<html lang="en" data-theme="dark">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>%s // SwarmPanel</title>
<link rel="stylesheet" href="/static/app.css">
<script>window.SWARM_TOKEN = %s; window.SWARM_SESSION = %s;</script>
<script src="/static/app.js"></script>
%s
</head>
<body>
<div class="%s" style="%s">
<header class="topbar">
  <a class="brand" href="/"><span class="brand-mark">&#10022;</span><span class="brand-copy"><strong>SwarmPanel</strong><small>Fleet Command</small></span></a>
  %s
  <div class="session-bar">%s</div>
</header>
%s
<main class="stage">%s</main>
<footer class="site-footer">
  <span>SwarmPanel // HeavenlyXenusVR</span>
  <a href="https://discord.com/users/1304564041863266347" target="_blank" rel="noreferrer">Discord</a>
</footer>
</div>
<div id="toast" class="toast" role="status" aria-live="polite"></div>
</body>
</html>]]):format(
    M.esc(opts.title or "SwarmPanel"),
    opts.token and ('"' .. M.esc(opts.token):gsub('"', '\\"') .. '"') or "null",
    (authed and "true" or "false"),
    opts.head_extra or "",
    M.esc(M.panel_class(prefs)), M.esc(M.panel_style(prefs)),
    nav_desktop, session_bar, mobile_nav, opts.body or "")
end

-- ---------------------------------------------------------------------------
-- Shared component primitives (mirror components/ui.jsx)
-- ---------------------------------------------------------------------------

-- Page(title, eyebrow, lede, actions_html, body_html)
function M.page(opts)
  return ([[
    <div class="page">
      <div class="page-head">
        <div>
          %s
          <h1>%s</h1>
          %s
        </div>
        %s
      </div>
      %s
    </div>
  ]]):format(
    opts.eyebrow and ("<p>" .. M.esc(opts.eyebrow) .. "</p>") or "",
    M.esc(opts.title or ""),
    opts.lede and ('<span class="page-lede">' .. M.esc(opts.lede) .. "</span>") or "",
    opts.actions or "",
    opts.body or "")
end

function M.section_head(title, subtitle)
  return ('<div class="section-head"><h2>%s</h2>%s</div>'):format(
    M.esc(title), subtitle and ("<p>" .. M.esc(subtitle) .. "</p>") or "")
end

-- metrics: array of {label=, value=}
function M.metric_grid(metrics)
  local cells = {}
  for _, m in ipairs(metrics) do
    cells[#cells + 1] = ('<div class="metric"><span class="metric-value">%s</span><span class="metric-label">%s</span></div>'):format(
      M.esc(m.value), M.esc(m.label))
  end
  return '<div class="metric-grid">' .. table.concat(cells, "") .. "</div>"
end

function M.notice(kind, text)
  return ('<div class="notice notice-%s">%s</div>'):format(M.esc(kind or "info"), M.esc(text))
end

function M.empty_state(text)
  return ('<div class="empty-state">%s</div>'):format(M.esc(text))
end

-- Generic auto-column table (mirrors swarm.jsx's DataTable). rows: array of
-- plain tables; columns: optional array of column names to force ordering
-- (defaults to the keys of the first row, capped at 9, matching the React
-- version's column cap).
function M.data_table(rows, columns, opts)
  opts = opts or {}
  if not rows or #rows == 0 then return M.empty_state(opts.empty_text or "No rows.") end
  if not columns then
    columns = {}
    local seen = {}
    for k in pairs(rows[1]) do
      if not seen[k] and k ~= "password_hash" and #columns < 9 then
        seen[k] = true
        columns[#columns + 1] = k
      end
    end
    table.sort(columns)
  end
  local thead = {}
  for _, c in ipairs(columns) do thead[#thead + 1] = "<th>" .. M.esc(c) .. "</th>" end
  local tbody = {}
  for _, row in ipairs(rows) do
    local cells = {}
    for _, c in ipairs(columns) do
      local v = row[c]
      if type(v) == "table" then v = cjson_encode_safe(v) end
      cells[#cells + 1] = "<td>" .. M.esc(v) .. "</td>"
    end
    tbody[#tbody + 1] = "<tr>" .. table.concat(cells, "") .. "</tr>"
  end
  return ('<div class="table-wrap"><table class="data-table"><thead><tr>%s</tr></thead><tbody>%s</tbody></table></div>'):format(
    table.concat(thead, ""), table.concat(tbody, ""))
end

return M
