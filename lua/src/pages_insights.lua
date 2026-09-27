-- Insights section: Leaderboard and Learning -- what the swarm is playing
-- and what the smart-recommendation engine has learned.
local httpd = require("httpd")
local html = require("html")
local accounts = require("accounts")
local kit = require("page_kit")
local dashboard = require("dashboard")

local M = {}

function M.register(cfg)
  local music_bots = cfg.music_bots
  local session_view, page_shell, denied = kit.session_view, kit.page_shell, kit.denied

  -- -----------------------------------------------------------------
  -- Leaderboard
  -- -----------------------------------------------------------------
  httpd.route("GET", "/leaderboard", function(req)
    local a, status, headers = cfg.require_auth_page(req)
    if not a then return status, "", headers end
    local data = dashboard.get_dashboard_data(music_bots)
    local bot_options = {}
    for _, bot in ipairs(data.bots) do
      bot_options[#bot_options + 1] = ("<option value=\"%s\">%s</option>"):format(html.esc(bot.key), html.esc(bot.display_name))
    end

    -- Same default as Controls: a guild-scoped account's own registered
    -- guild, read-only; admins get the first live session's guild as a
    -- convenience default but can still edit it.
    local own_guild_id = (not a.admin_mode) and a.guild_id or nil
    local default_guild_id = own_guild_id
    if not default_guild_id then
      for _, bot in ipairs(data.bots) do
        local first = bot.sessions and bot.sessions[1]
        if first and first.guild_id then default_guild_id = first.guild_id; break end
      end
    end
    local guild_field = own_guild_id
      and ('<label class="field">Guild ID<input type="text" name="guild_id" value="%s" readonly></label>'):format(html.esc(own_guild_id))
      or ('<label class="field">Guild ID<input type="text" name="guild_id" required value="%s"></label>'):format(html.esc(default_guild_id or ""))

    local body = html.page({
      title = "Leaderboard", eyebrow = "Insights", lede = "Top tracks and listeners.",
      body = ([[
        <form id="lb-form" class="panel form-panel">
          <label class="field">Bot<select name="bot_key">%s</select></label>
          %s
          <button type="submit" class="button-link primary">Load</button>
        </form>
        %s
        <div id="lb-results">%s</div>
        %s
        <div id="lb-swarm">%s</div>
      ]]):format(html.join(bot_options), guild_field, html.section_head("Guild Leaderboard"),
        html.section_loading("Loading leaderboard", "Fetching top tracks and listeners for this guild.", 3),
        a.admin_mode and html.section_head("Swarm-wide (admin)") or "",
        a.admin_mode and html.section_loading("Loading swarm-wide leaderboard", "Aggregating top tracks across every bot's database.", 3) or ""),
    })
    local script = ([[
      const lbForm = document.getElementById("lb-form");
      lbForm.addEventListener("submit", async (e) => {
        e.preventDefault();
        const fd = new FormData(lbForm);
        try {
          const res = await swarmFetch(`/api/guilds/${fd.get("guild_id")}/leaderboard?bot_key=${fd.get("bot_key")}`);
          const rows = (res.top_tracks || res.tracks || []).map((t, i) =>
            `<tr><td>${i + 1}</td><td>${(t.title || "Unknown").replace(/</g, "&lt;")}</td><td>${t.plays || 0}</td></tr>`).join("");
          document.getElementById("lb-results").innerHTML =
            '<table class="data-table"><thead><tr><th>#</th><th>Track</th><th>Plays</th></tr></thead><tbody>' + (rows || "<tr><td colspan=3>No data.</td></tr>") + "</tbody></table>";
        } catch (err) { swarmToast(err.message, "error"); }
      });
      %s
    ]]):format(a.admin_mode and [[
      (async () => {
        try {
          const res = await swarmFetch("/api/swarm-leaderboard?days=7&limit=20");
          const rows = (res.top_tracks || res.tracks || []).map((t, i) =>
            `<tr><td>${i + 1}</td><td>${(t.title || "Unknown").replace(/</g, "&lt;")}</td><td>${t.plays || 0}</td></tr>`).join("");
          document.getElementById("lb-swarm").innerHTML =
            '<table class="data-table"><thead><tr><th>#</th><th>Track</th><th>Plays</th></tr></thead><tbody>' + (rows || "<tr><td colspan=3>No data.</td></tr>") + "</tbody></table>";
        } catch { /* admin-only, ignore if it fails */ }
      })();
    ]] or "")
    return page_shell(req, a, "/leaderboard", "Leaderboard", body, script)
  end)

  -- -----------------------------------------------------------------
  -- Learning (GET /api/music-intelligence) -- a fully-built backend
  -- (dashboard.get_music_intelligence_summary: learned-track counts,
  -- plays/finishes/skips/likes/dislikes totals, smart-recommendation
  -- counts, and per-bot top-tracks-by-smart-score) with no page anywhere
  -- that ever called it.
  -- -----------------------------------------------------------------
  httpd.route("GET", "/learning", function(req)
    local a, status, headers = cfg.require_auth_page(req)
    if not a then return status, "", headers end
    local data = dashboard.get_dashboard_data(music_bots)
    local bot_options = { '<option value="">All bots</option>' }
    for _, bot in ipairs(data.bots) do
      if bot.kind == "music" then
        bot_options[#bot_options + 1] = ("<option value=\"%s\">%s</option>"):format(html.esc(bot.key), html.esc(bot.display_name))
      end
    end
    local own_guild_id = (not a.admin_mode) and a.guild_id or nil
    local guild_field = own_guild_id
      and ('<label class="field">Guild ID<input type="text" name="guild_id" value="%s" readonly></label>'):format(html.esc(own_guild_id))
      or '<label class="field">Guild ID (optional -- fleet-wide if blank)<input type="text" name="guild_id"></label>'

    local body = html.page({
      title = "Learning", eyebrow = "Insights", lede = "What the swarm's smart-recommendation engine has learned.",
      body = ([[
        <form id="learn-form" class="panel form-panel">
          <label class="field">Bot<select name="bot_key">%s</select></label>
          %s
          <button type="submit" class="button-link primary">Load</button>
        </form>
        <div class="metric-grid" id="learn-totals"></div>
        %s
        <div id="learn-bots">%s</div>
      ]]):format(html.join(bot_options), guild_field, html.section_head("By Bot"),
        html.section_loading("Loading music intelligence", "Aggregating learned-track stats across the fleet.", 3)),
    })
    local script = [[
      const learnForm = document.getElementById("learn-form");
      async function loadIntelligence() {
        const fd = new FormData(learnForm);
        const params = new URLSearchParams();
        if (fd.get("bot_key")) params.set("bot_key", fd.get("bot_key"));
        if (fd.get("guild_id")) params.set("guild_id", fd.get("guild_id"));
        try {
          const res = await swarmFetch(`/api/music-intelligence?${params.toString()}`);
          const t = (res.data && res.data.totals) || {};
          document.getElementById("learn-totals").innerHTML = [
            ["Learned Tracks", t.learned_tracks], ["Plays", t.plays], ["Finishes", t.finishes],
            ["Skips", t.skips], ["Likes", t.likes], ["Dislikes", t.dislikes], ["Smart Recs", t.recommendations],
          ].map(([label, value]) => `<div class="metric"><span class="metric-value">${value || 0}</span><span class="metric-label">${label}</span></div>`).join("");
          const bots = (res.data && res.data.bots) || [];
          document.getElementById("learn-bots").innerHTML = bots.length ? bots.map((bot) => `
            <div class="panel wide">
              <div class="section-head"><h2>${(bot.bot_display || bot.bot_key).replace(/</g, "&lt;")}</h2><p>${bot.learned_tracks || 0} learned tracks, ${bot.recommendations || 0} smart recommendations</p></div>
              <div class="table-wrap">
                <table class="data-table">
                  <thead><tr><th>Track</th><th>Plays</th><th>Finishes</th><th>Skips</th><th>Likes</th><th>Smart Score</th></tr></thead>
                  <tbody>${(bot.top_tracks || []).map((tr) => `
                    <tr><td>${(tr.title || "Unknown").replace(/</g, "&lt;")}</td><td>${tr.play_count || 0}</td><td>${tr.finish_count || 0}</td><td>${tr.skip_count || 0}</td><td>${tr.like_count || 0}</td><td>${tr.smart_score || 0}</td></tr>
                  `).join("") || '<tr><td colspan="6">No learned tracks yet.</td></tr>'}</tbody>
                </table>
              </div>
            </div>
          `).join("") : '<div class="empty-state">No music intelligence data yet.</div>';
        } catch (err) { swarmToast(err.message, "error"); }
      }
      learnForm.addEventListener("submit", (e) => { e.preventDefault(); loadIntelligence(); });
      loadIntelligence();
    ]]
    return page_shell(req, a, "/learning", "Learning", body, script)
  end)
end

return M
