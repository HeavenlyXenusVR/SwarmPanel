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
local accounts = require("accounts")

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
    -- Mirrors AuthPage.jsx: a login/register mode toggle on one form. The
    -- register fields (guild_id/email/verification_webhook_url) were
    -- entirely missing from the first Lua-rendered pass -- POST
    -- /api/session/register already existed and worked server-side the
    -- whole time, there was just no page that could reach it, so new
    -- guild accounts had no way to sign up at all.
    local body = ([[
      <form id="auth-form" class="auth-card form-panel">
        <h1>SwarmPanel</h1>
        <span class="page-lede" id="auth-lede">Sign in to reach fleet command.</span>
        <div class="segmented" role="tablist">
          <button type="button" class="active" data-auth-mode="login">Login</button>
          <button type="button" data-auth-mode="register">Register</button>
        </div>
        <div id="auth-error" class="notice notice-error" hidden></div>
        <label class="field"><span>Username</span><input type="text" name="username" autocomplete="username" required></label>
        <label class="field"><span>Password</span><input type="password" name="password" autocomplete="current-password"></label>
        <div data-auth-register hidden>
          <label class="field"><span>Guild ID</span><input type="text" name="guild_id"></label>
          <label class="field"><span>Email</span><input type="email" name="email"></label>
          <label class="field"><span>Discord Verification Webhook</span><input type="text" name="verification_webhook_url" placeholder="https://discord.com/api/webhooks/..."></label>
          <div class="auth-proof-guide">
            <div class="auth-proof-head">
              <div><strong>How webhook proof works</strong>
              <p>SwarmPanel verifies that the webhook URL belongs to the same Discord server as the guild ID you entered, then sends your real verification code there.</p></div>
            </div>
            <div class="auth-proof-steps">
              <article><span>1</span><div><strong>Open your Discord server settings</strong><p>Go to the server you want to register, then open a text channel you manage.</p></div></article>
              <article><span>2</span><div><strong>Create a temporary webhook</strong><p>Channel Settings &rarr; Integrations &rarr; Webhooks &rarr; New Webhook. Copy the URL.</p></div></article>
              <article><span>3</span><div><strong>Paste the URL here and register</strong><p>Remove the webhook after you finish verification.</p></div></article>
            </div>
            <div class="auth-proof-footnote">
              <span>This prevents someone else from claiming your guild by typing its ID first.</span>
              <span>The webhook only needs to stay active until the verification code is confirmed.</span>
            </div>
          </div>
        </div>
        <input type="hidden" name="next" value="%s">
        <button type="submit" class="primary" id="auth-submit">Login</button>
      </form>
      <script>
        const authForm = document.getElementById("auth-form");
        const authLede = document.getElementById("auth-lede");
        const authSubmit = document.getElementById("auth-submit");
        const registerFields = document.querySelector("[data-auth-register]");
        let authMode = "login";
        document.querySelectorAll("[data-auth-mode]").forEach((btn) => {
          btn.addEventListener("click", () => {
            authMode = btn.getAttribute("data-auth-mode");
            document.querySelectorAll("[data-auth-mode]").forEach((b) => b.classList.toggle("active", b === btn));
            registerFields.hidden = authMode !== "register";
            authForm.password.required = authMode === "login";
            authForm.guild_id.required = authMode === "register";
            authForm.verification_webhook_url.required = authMode === "register";
            authLede.textContent = authMode === "login"
              ? "Sign in to reach fleet command."
              : "Register your guild identity with a Discord webhook that proves guild ownership and receives your verification code.";
            authSubmit.textContent = authMode === "login" ? "Login" : "Create Account";
          });
        });
        authForm.addEventListener("submit", async (e) => {
          e.preventDefault();
          const errBox = document.getElementById("auth-error");
          errBox.hidden = true;
          const fd = new FormData(authForm);
          const endpoint = authMode === "login" ? "/api/session/login" : "/api/session/register";
          const payload = Object.fromEntries(fd);
          try {
            const res = await fetch(endpoint, {
              method: "POST",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify(payload),
            });
            const data = await res.json();
            if (!res.ok) throw new Error(data.detail || (authMode === "login" ? "Login failed" : "Registration failed"));
            window.location = fd.get("next") || "/";
          } catch (err) {
            errBox.textContent = err.message || "Something went wrong";
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
    -- Was checking session.is_playing BEFORE offline/stale status, so a bot
    -- that went offline mid-track (its last DB-persisted session row still
    -- has is_playing=true from before it dropped) still showed a "Live"
    -- badge and a playback counter that could never advance again -- which
    -- is what actually produced several of the "duration stuck" bot cards:
    -- not a display bug, a genuinely dead bot whose last-known state was
    -- being trusted as current. Offline/stale is checked first now.
    local function bot_is_offline(bot)
      local status_lower = tostring(bot.status or ""):lower()
      if status_lower == "offline" then return true end
      local age = tonumber(bot.heartbeat_age_seconds)
      if age and age > 120 then return true end
      return false
    end
    local function playback_badge(session, bot)
      if bot_is_offline(bot) then return "danger", "Offline" end
      if session and session.is_playing then return "live", "Live" end
      if session and session.is_paused then return "soft", "Paused" end
      local status_lower = tostring(bot.heartbeat_status or bot.status or ""):lower()
      if status_lower:find("stale") then return "danger", "Stale" end
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
        local pct = (duration > 0) and math.min(100, math.floor(100 * (session.position_seconds or 0) / duration)) or 0
        -- data-playback-bar must live INSIDE the data-playback-counter
        -- element -- app.js's tickPlaybackCounters() finds the bar via
        -- el.querySelector() scoped to the counter element, so a sibling
        -- bar (as this used to be) is never found and its width just
        -- freezes at whatever the server rendered on page load.
        playback_block = ([[
          <div class="bot-playback-wrap" data-playback-counter data-position="%s" data-observed-at="%s" data-duration="%s" data-playing="%s">
            <div class="bot-seek-bar" data-seek-bar data-bot-key="%s" data-guild-id="%s" data-duration="%d">
              <div class="bot-seek-track"><div class="bot-seek-fill" data-playback-bar style="width:%d%%"></div></div>
            </div>
            <span data-playback-label></span>
          </div>
        ]]):format(
          tostring(session.position_seconds or 0), tostring(session.position_observed_at or 0),
          tostring(session.duration_seconds or 0), tostring(session.is_playing == true),
          html.esc(bot.key), html.esc(session.guild_id), duration, pct)
      end

      local offline_overlay = bot_is_offline(bot)
        and '<div class="bot-card-offline-overlay"><span class="bot-card-offline-label">Offline</span></div>' or ""

      bot_cards[#bot_cards + 1] = ([[
        <article class="bot-card%s" style="--card-accent: %s">
          %s
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
            <span data-queue-pressure>%d queued</span>
            <span data-queue-pressure>%d backup</span>
            %s
          </div>
        </article>
      ]]):format(offline_overlay ~= "" and " bot-card-offline" or "", html.esc(accent),
        offline_overlay,
        html.esc(bot.display_name), html.esc(bot.heartbeat_status or bot.status or "telemetry ready"),
        tone, label,
        thumb,
        html.esc(now_title), html.esc(now_sub),
        playback_block,
        bot.active_playing_count or 0, bot.known_guild_count or 0,
        bot.queue_depth or 0, bot.backup_queue_depth or 0,
        -- show_bot_uptime ("Show bot uptime" on /appearance): saved but
        -- never had any stat to toggle. heartbeat_age_seconds is real,
        -- live data already flowing through /api/dashboard (used for
        -- offline detection above) -- surfaced here as "last heartbeat"
        -- rather than inventing a fabricated process-uptime number, since
        -- no bot actually persists a process start time anywhere.
        (tonumber(bot.heartbeat_age_seconds) ~= nil)
          and ('<span data-bot-uptime>heartbeat %ds ago</span>'):format(math.floor(bot.heartbeat_age_seconds))
          or "")

      for _, s in ipairs(bot.sessions or {}) do
        s.bot_key = bot.key
        s.bot_display = bot.display_name
        all_sessions[#all_sessions + 1] = s
      end
    end

    local session_rows = {}
    for _, s in ipairs(all_sessions) do
      if s.is_playing or s.is_paused or (s.title and s.title ~= "") then
        -- Read-only compact counter here, not the draggable bot-seek-bar
        -- (that belongs on the bot cards above, matching the original
        -- BotCard/SessionTable split) -- the seek bar has no width of its
        -- own (100% of its container), so dropped into a wide table column
        -- it stretched across nearly the full row. The bare 160px cap here
        -- matches PlaybackCounter's compact rendering in ControlState.
        session_rows[#session_rows + 1] = ([[
          <tr>
            <td>%s</td>
            <td>%s</td>
            <td>%s</td>
            <td style="max-width:160px">
              <div class="bot-playback compact" data-playback-counter data-position="%s" data-observed-at="%s" data-duration="%s" data-playing="%s">
                <div class="bot-playback-bar" aria-hidden="true"><span data-playback-bar style="width:%d%%"></span></div>
                <span data-playback-label></span>
              </div>
            </td>
            <td>%d queued</td>
          </tr>
        ]]):format(
          html.esc(s.bot_display), html.esc(s.title or "—"), html.esc(s.session_state_label or ""),
          tostring(s.position_seconds or 0), tostring(s.position_observed_at or 0), tostring(s.duration_seconds or 0),
          tostring(s.is_playing == true),
          (s.duration_seconds and s.duration_seconds > 0) and math.min(100, math.floor(100 * (s.position_seconds or 0) / s.duration_seconds)) or 0,
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

    local prefs = a and accounts.get_panel_preferences(a.username, a.guild_id) or nil
    return 200, html.layout({ title = "Dashboard", path = path, session = session_view(a), token = req.cookies and req.cookies.swarm_session, body = body, preferences = prefs }),
      { ["Content-Type"] = "text/html; charset=utf-8" }
  end

  httpd.route("GET", "/", function(req) return render_dashboard(req, "/") end)
  httpd.route("GET", "/dashboard", function(req) return render_dashboard(req, "/dashboard") end)
end

return M
