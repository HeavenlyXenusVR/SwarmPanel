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

-- BUGFIX 2026-08-22: the "Audio Nodes: Healthy/Checking" summary badges
-- (boot screen + dashboard spotlight, below) used to check ONLY the
-- "lavalink" (primary) node's status -- accurate back when that was the
-- only real node, but since the 2026-08-17 3-node pool + per-bot
-- node_affinity rotation (see Music/lua-shared/swarmlua/bot.lua/
-- nodepool.lua), many bots' actual preferred node is lavalink2 or
-- lavalink3, not "lavalink". A primary that happens to be down while both
-- pool nodes are fine (the fleet keeps working fine via failover) used to
-- show "Checking" here forever; the reverse -- lavalink2/lavalink3 both
-- down while the primary happens to be fine -- used to show "Healthy" with
-- 2 of 3 real nodes silently degraded. Healthy here now means "the fleet
-- still has at least one working real Lavalink node" -- NodeLink is a
-- last-resort fallback, deliberately not counted toward this summary the
-- same way it isn't counted as one of the "real" nodes in bot.lua's own
-- node_affinity rotation.
local function any_lavalink_node_healthy(node_health)
  node_health = node_health or {}
  for _, name in ipairs({ "lavalink", "lavalink2", "lavalink3" }) do
    if (node_health[name] or {}).status == "healthy" then return true end
  end
  return false
end

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
      guild_id = a.guild_id,
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
          <label class="field"><span>Email (optional)</span><input type="email" name="email"></label>
          <div class="segmented" role="tablist">
            <button type="button" class="active" data-auth-proof-mode="webhook">Server Webhook</button>
            <button type="button" data-auth-proof-mode="discord">Discord DM</button>
          </div>
          <div data-auth-proof-webhook>
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
          <div data-auth-proof-discord hidden>
            <label class="field"><span>Your Discord User ID</span><input type="text" name="discord_user_id" placeholder="1234567890123456"></label>
            <div class="auth-proof-guide">
              <div class="auth-proof-head">
                <div><strong>How Discord DM proof works</strong>
                <p>SwarmPanel's verification bot sends a real code straight to your Discord DMs. Enter it after registering to finish verifying.</p></div>
              </div>
              <div class="auth-proof-steps">
                <article><span>1</span><div><strong>Enable Developer Mode</strong><p>Discord Settings &rarr; Advanced &rarr; Developer Mode.</p></div></article>
                <article><span>2</span><div><strong>Copy your User ID</strong><p>Right-click your own name or avatar anywhere in Discord &rarr; Copy User ID.</p></div></article>
                <article><span>3</span><div><strong>Share a server with the bot first</strong><p>Bots can only DM accounts that share a server with them and allow DMs from server members.</p></div></article>
              </div>
            </div>
          </div>
        </div>
        <input type="hidden" name="next" value="%s">
        <button type="submit" class="primary liquid-glass" id="auth-submit">Login</button>
      </form>
      <script>
        const authForm = document.getElementById("auth-form");
        const authLede = document.getElementById("auth-lede");
        const authSubmit = document.getElementById("auth-submit");
        const registerFields = document.querySelector("[data-auth-register]");
        const proofWebhookBox = document.querySelector("[data-auth-proof-webhook]");
        const proofDiscordBox = document.querySelector("[data-auth-proof-discord]");
        let authMode = "login";
        let proofMode = "webhook";
        function applyProofMode() {
          proofWebhookBox.hidden = proofMode !== "webhook";
          proofDiscordBox.hidden = proofMode !== "discord";
          authForm.verification_webhook_url.required = authMode === "register" && proofMode === "webhook";
          authForm.discord_user_id.required = authMode === "register" && proofMode === "discord";
          authLede.textContent = authMode === "login"
            ? "Sign in to reach fleet command."
            : proofMode === "webhook"
              ? "Register your guild identity with a Discord webhook that proves guild ownership and receives your verification code."
              : "Register your guild identity, then verify straight from Discord DMs -- no webhook needed.";
        }
        document.querySelectorAll("[data-auth-proof-mode]").forEach((btn) => {
          btn.addEventListener("click", () => {
            proofMode = btn.getAttribute("data-auth-proof-mode");
            document.querySelectorAll("[data-auth-proof-mode]").forEach((b) => b.classList.toggle("active", b === btn));
            applyProofMode();
          });
        });
        document.querySelectorAll("[data-auth-mode]").forEach((btn) => {
          btn.addEventListener("click", () => {
            authMode = btn.getAttribute("data-auth-mode");
            document.querySelectorAll("[data-auth-mode]").forEach((b) => b.classList.toggle("active", b === btn));
            registerFields.hidden = authMode !== "register";
            authForm.password.required = authMode === "login";
            authForm.guild_id.required = authMode === "register";
            applyProofMode();
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
        -- bot-seek-thumb/-times had CSS (a drag handle riding the fill, plus
        -- a split current/duration time row) but the seek bar only ever
        -- rendered the bare track/fill -- no handle, and the single inline
        -- data-playback-label wasn't split the way .bot-seek-times expects.
        playback_block = ([[
          <div class="bot-playback-wrap" data-playback-counter data-position="%s" data-observed-at="%s" data-duration="%s" data-playing="%s">
            <div class="bot-seek-bar" data-seek-bar data-bot-key="%s" data-guild-id="%s" data-duration="%d">
              <div class="bot-seek-track">
                <div class="bot-seek-fill" data-playback-bar style="width:%d%%"></div>
                <div class="bot-seek-thumb" data-seek-thumb style="left:%d%%"></div>
              </div>
            </div>
            <div class="bot-seek-times"><span data-seek-current></span><span data-seek-duration></span></div>
          </div>
        ]]):format(
          tostring(session.position_seconds or 0), tostring(session.position_observed_at or 0),
          tostring(session.duration_seconds or 0), tostring(session.is_playing == true),
          html.esc(bot.key), html.esc(session.guild_id), duration, pct, pct)
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

    -- Cross-bot Lavalink/NodeLink health (see dashboard.lua's
    -- get_node_health() -- reads the shared Redis scoreboard every bot's
    -- own Lavalink client writes to on every success/failure, so this is
    -- one shared status, not per-bot). "degraded"/"stale" reuse the same
    -- data-pill-danger/data-pill-off tones the bot cards above already use
    -- for offline/idle, so a red pill here reads the same way it does
    -- everywhere else on this page.
    local NODE_HEALTH_TONE = { healthy = "live", degraded = "danger", stale = "off", unknown = "off" }
    local NODE_HEALTH_LABEL = { healthy = "Healthy", degraded = "Degraded", stale = "Stale", unknown = "No data yet" }
    -- BUGFIX 2026-08-22: matches dashboard.lua's get_node_health() fix --
    -- this hardcoded 2-node list independently had the exact same gap
    -- (missing lavalink2/lavalink3, the 2 extra real Lavalink instances
    -- added 2026-08-17 to spread the fleet's voice-session load), so even
    -- with that fix, THIS page still wouldn't have rendered them: a
    -- degraded/down node on 2 of the 3 real Lavalink instances could sit
    -- invisible here indefinitely, same failure mode.
    local NODE_DISPLAY_NAME = {
      lavalink = "Lavalink (primary)", lavalink2 = "Lavalink 2", lavalink3 = "Lavalink 3",
      nodelink = "NodeLink (backup)",
    }
    local node_pills = {}
    for _, node_name in ipairs({ "lavalink", "lavalink2", "lavalink3", "nodelink" }) do
      local h = (data.node_health or {})[node_name] or { status = "unknown" }
      local tone = NODE_HEALTH_TONE[h.status] or "off"
      local label = NODE_HEALTH_LABEL[h.status] or "Unknown"
      local detail
      if h.status == "healthy" and h.last_success_age_seconds then
        detail = ("last success %ds ago"):format(h.last_success_age_seconds)
      elseif h.consecutive_failures and h.consecutive_failures > 0 then
        detail = ("%d consecutive failures"):format(h.consecutive_failures)
      else
        detail = "no recent activity"
      end
      node_pills[#node_pills + 1] = ([[
        <div class="bot-card" style="--card-accent: #89b4fa">
          <div class="bot-head">
            <span class="bot-dot"></span>
            <div class="bot-head-copy">
              <h3>%s</h3>
              <small>%s</small>
            </div>
            <span class="data-pill data-pill-%s">%s</span>
          </div>
        </div>
      ]]):format(html.esc(NODE_DISPLAY_NAME[node_name] or node_name), html.esc(detail), tone, label)
    end

    -- Boot screen (swarm-loading-*) uses real numbers already computed
    -- above, not placeholders -- an operator landing on the dashboard sees
    -- an accurate snapshot for the ~1s the panel is visible, not a fake
    -- progress bar. Fades itself out client-side (fully rendered content is
    -- already behind it since this is a server-rendered page, not an
    -- actual loading gate).
    local online_bots, live_count = 0, 0
    for _, bot in ipairs(data.bots) do
      if not bot_is_offline(bot) then online_bots = online_bots + 1 end
    end
    for _, s in ipairs(all_sessions) do
      if s.is_playing then live_count = live_count + 1 end
    end
    local boot_screen = ([[
      <div class="swarm-loading-screen" id="boot-screen">
        <div class="swarm-loading-backdrop"></div>
        <div class="swarm-loading-panel">
          <div class="swarm-loading-hero">
            <div class="swarm-loading-radar">
              <div class="swarm-loading-ring ring-a"></div>
              <div class="swarm-loading-ring ring-b"></div>
              <div class="swarm-loading-ring ring-c"></div>
              <div class="swarm-loading-sweep"></div>
              <div class="swarm-loading-core"></div>
            </div>
            <div class="swarm-loading-copy">
              <span class="swarm-loading-kicker">Fleet Command</span>
              <strong>SwarmPanel</strong>
              <p>Syncing with the swarm...</p>
            </div>
          </div>
          <div class="swarm-loading-status-grid">
            <article><span>Bots Online</span><strong>%d / %d</strong><small>heartbeat within 120s</small></article>
            <article><span>Live Sessions</span><strong>%d</strong><small>currently playing</small></article>
            <article><span>Audio Nodes</span><strong>%s</strong><small>Lavalink / NodeLink</small></article>
          </div>
          <div class="swarm-loading-progress"><span></span></div>
        </div>
      </div>
      <script>
        (function () {
          var el = document.getElementById("boot-screen");
          if (!el) return;
          setTimeout(function () {
            el.classList.add("is-leaving");
            setTimeout(function () { el.remove(); }, 420);
          }, 650);
        })();
      </script>
    ]]):format(
      online_bots, #data.bots, live_count,
      any_lavalink_node_healthy(data.node_health) and "Healthy" or "Checking"
    )

    -- Fleet Overview spotlight: dashboard-spotlight/-metrics/-mini-metrics/
    -- -queue-leaders/-queue-card all had full CSS with no HTML ever built
    -- for them. Real aggregates from the same data.bots the cards below
    -- already render from, not fabricated numbers.
    local total_queue, total_backup, total_guilds = 0, 0, 0
    local busiest_bot = nil
    for _, bot in ipairs(data.bots) do
      total_queue = total_queue + (bot.queue_depth or 0)
      total_backup = total_backup + (bot.backup_queue_depth or 0)
      total_guilds = total_guilds + (bot.known_guild_count or 0)
      if bot.kind == "music" and (not busiest_bot or (bot.queue_depth or 0) > (busiest_bot.queue_depth or 0)) then
        busiest_bot = bot
      end
    end
    -- Real Now Playing widget for the spotlight card (bot-playback-head/
    -- dashboard-playback CSS existed with no consumer) -- the first session
    -- actually playing right now, not just the deepest queue.
    local spotlight_session = nil
    for _, s in ipairs(all_sessions) do
      if s.is_playing then spotlight_session = s; break end
    end
    local spotlight_playback = ""
    if spotlight_session then
      local duration = math.floor(spotlight_session.duration_seconds or 0)
      local pct = (duration > 0) and math.min(100, math.floor(100 * (spotlight_session.position_seconds or 0) / duration)) or 0
      spotlight_playback = ([[
        <div class="bot-playback dashboard-playback" data-playback-counter data-position="%s" data-observed-at="%s" data-duration="%s" data-playing="true">
          <div class="bot-playback-head"><strong>%s</strong><small>%s</small></div>
          <div class="bot-playback-bar"><span data-playback-bar style="width:%d%%"></span></div>
          <small data-playback-label></small>
        </div>
      ]]):format(
        tostring(spotlight_session.position_seconds or 0), tostring(spotlight_session.position_observed_at or 0), tostring(spotlight_session.duration_seconds or 0),
        html.esc(spotlight_session.title or "Now Playing"), html.esc(spotlight_session.bot_display or ""), pct
      )
    end

    local queue_leaders_bots = {}
    for _, bot in ipairs(data.bots) do
      if bot.kind == "music" and (bot.queue_depth or 0) > 0 then queue_leaders_bots[#queue_leaders_bots + 1] = bot end
    end
    table.sort(queue_leaders_bots, function(x, y) return (x.queue_depth or 0) > (y.queue_depth or 0) end)
    local queue_leader_cards = {}
    for i = 1, math.min(4, #queue_leaders_bots) do
      local bot = queue_leaders_bots[i]
      queue_leader_cards[#queue_leader_cards + 1] = ([[
        <div class="dashboard-queue-card bot-card">
          <div class="bot-head"><span class="bot-dot"></span><div class="bot-head-copy"><h3>%s</h3></div><span class="data-pill data-pill-off">%d queued</span></div>
        </div>
      ]]):format(html.esc(bot.display_name), bot.queue_depth or 0)
    end

    local spotlight = ([[
      <div class="dashboard-brief-panel">
        <div class="dashboard-spotlight liquid-glass">
          <div class="dashboard-spotlight-head">
            <span class="dashboard-eyebrow">Fleet Overview</span>
            <span class="dashboard-state-badge%s">%s</span>
          </div>
          <strong>%s</strong>
          <p>%s</p>
          %s
          <div class="dashboard-spotlight-metrics">
            <article><span>Bots Online</span><strong id="metric-bots-online">%d / %d</strong><small>heartbeat within 120s</small></article>
            <article><span>Live Sessions</span><strong id="metric-live-sessions">%d</strong><small>currently playing</small></article>
            <article><span>Queue Depth</span><strong id="metric-queue-depth">%d</strong><small><span id="metric-queue-backup">%d</span> in backup</small></article>
            <article><span>Guilds Served</span><strong id="metric-guilds-served">%d</strong><small>across the fleet</small></article>
          </div>
        </div>
      </div>
      <div class="dashboard-mini-metrics">
        <article><span>Audio Nodes</span><strong>%s</strong></article>
        <article><span>Aria Orchestrator</span><strong>%s</strong></article>
      </div>
      %s
      <div class="dashboard-queue-leaders">%s</div>
    ]]):format(
      live_count > 0 and " live" or " idle", live_count > 0 and "Active" or "Idle",
      busiest_bot and (busiest_bot.display_name .. (live_count > 0 and " is carrying live playback" or " has the deepest queue")) or "Fleet is quiet right now",
      busiest_bot and ("%d queued, %d live guild(s)"):format(busiest_bot.queue_depth or 0, busiest_bot.active_playing_count or 0) or "No active bot to highlight.",
      spotlight_playback,
      online_bots, #data.bots, live_count, total_queue, total_backup, total_guilds,
      any_lavalink_node_healthy(data.node_health) and "Healthy" or "Checking",
      (function()
        for _, bot in ipairs(data.bots) do if bot.key == "aria" then return bot.status or "Unknown" end end
        return "Unknown"
      end)(),
      #queue_leader_cards > 0 and html.section_head("Queue Leaders") or "",
      html.join(queue_leader_cards)
    )

    local body = html.page({
      title = "Dashboard",
      eyebrow = "Fleet Command",
      lede = "Live status across the swarm.",
      body = ([[
        %s
        %s
        <div class="bot-grid">%s</div>
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
        spotlight,
        html.section_head("Audio Nodes"), html.join(node_pills),
        html.section_head("Bots"), html.join(bot_cards),
        html.section_head("Live Sessions"),
        #session_rows > 0 and html.join(session_rows) or ('<tr><td colspan="5">' .. html.esc("Nothing playing right now.") .. "</td></tr>")),
    })

    body = boot_screen .. body .. [[
      <script>
        // BUGFIX: this handler used to do nothing at all -- confirmed live
        // via Playwright, the page never updated without a manual refresh
        // despite its own lede claiming "Live status across the swarm."
        // A first attempt at fixing this reloaded the whole page on every
        // message, but the snapshot's per-session position_seconds/
        // position_observed_at tick essentially every broadcast (~2s,
        // ensure_broadcast_loop in routes.lua), so the server's digest
        // basically always differs while anything anywhere is playing --
        // that caused a reload storm (confirmed: 8 reloads in 15s even
        // throttled), which is worse than the original do-nothing bug, not
        // better. Patching just the 4 spotlight numbers directly from the
        // payload avoids re-deriving the rest of the page (bot cards,
        // session table, etc. still need a real reload to update, same
        // gap as before) but makes the one thing users actually glance at
        // continuously -- Bots Online / Live Sessions / Queue Depth /
        // Guilds Served -- genuinely live with zero reload risk. Mirrors
        // pages.lua's own online_bots/live_count/total_queue/total_backup/
        // total_guilds aggregation (see bot_is_offline above) -- keep the
        // two in sync if that logic ever changes.
        function patchDashboardMetrics(data) {
          const bots = (data && data.bots) || [];
          let online = 0, live = 0, queue = 0, backup = 0, guilds = 0;
          for (const bot of bots) {
            const age = Number(bot.heartbeat_age_seconds);
            const offline = String(bot.status || "").toLowerCase() === "offline" || (Number.isFinite(age) && age > 120);
            if (!offline) online++;
            queue += bot.queue_depth || 0;
            backup += bot.backup_queue_depth || 0;
            guilds += bot.known_guild_count || 0;
            for (const s of bot.sessions || []) { if (s.is_playing) live++; }
          }
          const setText = (id, text) => { const el = document.getElementById(id); if (el) el.textContent = text; };
          setText("metric-bots-online", online + " / " + bots.length);
          setText("metric-live-sessions", String(live));
          setText("metric-queue-depth", String(queue));
          setText("metric-queue-backup", String(backup));
          setText("metric-guilds-served", String(guilds));
        }
        swarmDashboardStream((msg) => {
          if (msg.type === "dashboard_snapshot") patchDashboardMetrics(msg.data);
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
