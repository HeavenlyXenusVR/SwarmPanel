-- Server-rendered HTML page routes -- replaces frontend/src/pages/*.jsx.
-- Reuses the exact same data-fetching functions the JSON API routes call
-- (dashboard.lua, accounts.lua, etc) via routes.lua's dependency injection
-- (see M.register(cfg) below, mirroring routes.lua's own M.register shape).
local httpd = require("httpd")
local html = require("html")
local auth = require("auth")
local dashboard = require("dashboard")
local ratelimit = require("ratelimit")
local config = require("config")

local M = {}

function M.register(cfg)
  local settings = cfg.settings
  local music_bots = cfg.music_bots
  local get_auth = cfg.get_auth
  local session_cookie_header = cfg.session_cookie_header
  local clear_session_cookie_header = cfg.clear_session_cookie_header

  -- Builds the {authenticated=, username=, admin_mode=, ...} shape html.lua's
  -- layout()/nav expect, from the raw auth-payload table get_auth() returns
  -- (or nil if unauthenticated) -- same fields routes.lua's GET /api/session
  -- already computes, just reused here for page chrome.
  local function session_view(a)
    if not a then return { authenticated = false } end
    return {
      authenticated = true,
      username = a.username,
      site_owner = a.site_owner == true,
      admin_mode = a.admin_mode == true,
      moderator = a.moderator == true,
      image_gallery_owner = (a.admin_mode == true) and (a.site_owner == true),
    }
  end

  -- ---------------------------------------------------------------------
  -- Login (public) -- mirrors pages/AuthPage.jsx
  -- ---------------------------------------------------------------------
  httpd.route("GET", "/login", function(req)
    local a = get_auth(req)
    if a then return 303, "", { Location = "/" } end
    local next_path = req.query["next"]
    local body = ([[
      <form id="login-form" class="auth-card form-panel">
        <h1>SwarmPanel</h1>
        <span class="page-lede">Sign in to reach fleet command.</span>
        <div id="auth-error" class="notice notice-error" hidden></div>
        <label class="field"><span>Username</span><input type="text" name="username" autocomplete="username" required></label>
        <label class="field"><span>Password</span><input type="password" name="password" autocomplete="current-password" required></label>
        <input type="hidden" name="next" value="%s">
        <button type="submit" class="primary">Login</button>
      </form>
      <script>
        document.getElementById("login-form").addEventListener("submit", async (e) => {
          e.preventDefault();
          const form = e.target;
          const errBox = document.getElementById("auth-error");
          errBox.hidden = true;
          try {
            const res = await fetch("/api/session/login", {
              method: "POST",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify({ username: form.username.value, password: form.password.value }),
            });
            const data = await res.json();
            if (!res.ok) throw new Error(data.detail || "Login failed");
            window.location = form.next.value || "/";
          } catch (err) {
            errBox.textContent = err.message || "Login failed";
            errBox.hidden = false;
          }
        });
      </script>
    ]]):format(html.esc(next_path or ""))
    return 200, html.layout({ title = "Login", path = "/login", session = { authenticated = false }, body = body }),
      { ["Content-Type"] = "text/html; charset=utf-8" }
  end)

  httpd.route("POST", "/logout", function(req)
    return 303, "", { Location = "/login", ["Set-Cookie"] = clear_session_cookie_header() }
  end)

  -- ---------------------------------------------------------------------
  -- Dashboard -- mirrors pages/DashboardPage.jsx
  -- ---------------------------------------------------------------------
  local function render_dashboard(req, path)
    local a, redirect_status, redirect_headers = cfg.require_auth_page(req)
    if not a then return redirect_status, "", redirect_headers end

    local data = dashboard.get_dashboard_data(music_bots)

    -- Mirrors swarm.jsx's bestSession()/playbackBadge(): the featured
    -- session for a card is whichever guild is actually playing, falling
    -- back to the first known session, then the badge reflects that
    -- session's state (or the bot's own heartbeat health when nothing is
    -- playing at all).
    local function best_session(bot)
      for _, s in ipairs(bot.sessions or {}) do
        if s.is_playing then return s end
      end
      return bot.sessions and bot.sessions[1] or nil
    end
    local function playback_badge(session, bot)
      if session and session.is_playing then return "live", "Live" end
      if session and session.is_paused then return "soft", "Paused" end
      local status_lower = tostring(bot.heartbeat_status or bot.status or ""):lower()
      if status_lower:find("stale") or tostring(bot.status or ""):lower() == "offline" then
        return "danger", "Stale"
      end
      return "off", "Idle"
    end

    local bot_cards = {}
    local all_sessions = {}
    for _, bot in ipairs(data.bots) do
      local session = best_session(bot)
      local tone, label = playback_badge(session, bot)
      local accent = config.bot_accents[bot.key] or "#89b4fa"

      local thumb
      if session and session.thumbnail and session.thumbnail ~= "" then
        thumb = ('<img class="bot-thumb" src="%s" alt="" loading="lazy">'):format(html.esc(session.thumbnail))
      else
        thumb = '<div class="bot-thumb bot-thumb-empty">&#9835;</div>'
      end

      local now_title = (session and session.title and session.title ~= "") and session.title
        or bot.error or bot.schema or "Waiting for live playback."
      local now_sub = (session and (session.media_source_label or session.session_state_label))
        or "Live state will fill in automatically."

      local playback_block = ""
      if session then
        local duration = math.floor(session.duration_seconds or 0)
        local pct = (duration > 0) and math.floor(100 * (session.position_seconds or 0) / duration) or 0
        playback_block = ([[
          <div class="bot-seek-bar" data-seek-bar data-bot-key="%s" data-guild-id="%s" data-duration="%d">
            <div class="bot-seek-track"><div class="bot-seek-fill" data-playback-bar style="width:%d%%"></div></div>
          </div>
          <span data-playback-counter data-position="%s" data-observed-at="%s" data-duration="%s" data-playing="%s">
            <span data-playback-label></span>
          </span>
        ]]):format(html.esc(bot.key), html.esc(session.guild_id), duration, pct,
          tostring(session.position_seconds or 0), tostring(session.position_observed_at or 0),
          tostring(session.duration_seconds or 0), tostring(session.is_playing == true))
      end

      bot_cards[#bot_cards + 1] = ([[
        <article class="bot-card" style="--card-accent: %s">
          <div class="bot-head">
            <span class="bot-dot"></span>
            <div class="bot-head-copy">
              <h3>%s</h3>
              <small>%s</small>
            </div>
            <span class="data-pill data-pill-%s">%s</span>
          </div>
          <div class="bot-now">
            %s
            <div class="bot-now-copy">
              <strong>%s</strong>
              <small>%s</small>
            </div>
          </div>
          %s
          <div class="chip-row">
            <span>%d live</span>
            <span>%d guilds</span>
            <span>%d queued</span>
            <span>%d backup</span>
          </div>
        </article>
      ]]):format(html.esc(accent),
        html.esc(bot.display_name), html.esc(bot.heartbeat_status or bot.status or "telemetry ready"),
        tone, label,
        thumb,
        html.esc(now_title), html.esc(now_sub),
        playback_block,
        bot.active_playing_count or 0, bot.known_guild_count or 0,
        bot.queue_depth or 0, bot.backup_queue_depth or 0)

      for _, s in ipairs(bot.sessions or {}) do
        s.bot_key = bot.key
        s.bot_display = bot.display_name
        all_sessions[#all_sessions + 1] = s
      end
    end

    local session_rows = {}
    for _, s in ipairs(all_sessions) do
      if s.is_playing or s.is_paused or (s.title and s.title ~= "") then
        session_rows[#session_rows + 1] = ([[
          <tr>
            <td>%s</td>
            <td>%s</td>
            <td>%s</td>
            <td>
              <div class="bot-seek-bar" data-seek-bar data-bot-key="%s" data-guild-id="%s" data-duration="%d">
                <div class="bot-seek-track"><div class="bot-seek-fill" data-playback-bar style="width:%d%%"></div></div>
              </div>
              <span data-playback-counter data-position="%s" data-observed-at="%s" data-duration="%s" data-playing="%s">
                <span data-playback-label></span>
              </span>
            </td>
            <td>%d queued</td>
          </tr>
        ]]):format(
          html.esc(s.bot_display), html.esc(s.title or "—"), html.esc(s.session_state_label or ""),
          html.esc(s.bot_key), html.esc(s.guild_id), math.floor(s.duration_seconds or 0),
          (s.duration_seconds and s.duration_seconds > 0) and math.floor(100 * (s.position_seconds or 0) / s.duration_seconds) or 0,
          tostring(s.position_seconds or 0), tostring(s.position_observed_at or 0), tostring(s.duration_seconds or 0),
          tostring(s.is_playing == true),
          s.queue_count or 0)
      end
    end

    local body = html.page({
      title = "Dashboard",
      eyebrow = "Fleet Command",
      lede = "Live status across the swarm.",
      body = ([[
        %s
        <div class="bot-grid" id="bot-cards">%s</div>
        %s
        <div class="table-wrap">
          <table class="data-table" id="sessions-table">
            <thead><tr><th>Bot</th><th>Track</th><th>State</th><th>Position</th><th>Queue</th></tr></thead>
            <tbody>%s</tbody>
          </table>
        </div>
      ]]):format(
        html.section_head("Bots"), html.join(bot_cards),
        html.section_head("Live Sessions"),
        #session_rows > 0 and html.join(session_rows) or ('<tr><td colspan="5">' .. html.esc("Nothing playing right now.") .. "</td></tr>")),
    })

    body = body .. [[
      <script>
        swarmDashboardStream((msg) => {
          if (msg.type === "dashboard_snapshot") {
            // Full re-render is out of scope for this pass; a page reload
            // picks up fresh data. The WS connection here still proves live
            // connectivity and keeps the playback counters' base timestamps
            // roughly fresh via periodic reloads.
          }
        });
      </script>
    ]]

    return 200, html.layout({ title = "Dashboard", path = path, session = session_view(a), token = req.cookies and req.cookies.swarm_session, body = body }),
      { ["Content-Type"] = "text/html; charset=utf-8" }
  end

  httpd.route("GET", "/", function(req) return render_dashboard(req, "/") end)
  httpd.route("GET", "/dashboard", function(req) return render_dashboard(req, "/dashboard") end)
end

return M
