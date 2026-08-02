-- Server-rendered pages: Controls, Invites, Leaderboard, Users, Friends.
-- Pattern: render the page shell + static structure server-side via
-- html.lua, then populate live/interactive data with inline JS calling the
-- SAME JSON API the old React app used (swarmFetch, from static/app.js).
local httpd = require("httpd")
local html = require("html")

local M = {}

local CONTROL_ACTIONS = {
  "PLAY", "SMART_RECOMMEND", "PAUSE", "RESUME", "SKIP", "STOP", "CLEAR",
  "RESET_QUEUE", "SHUFFLE", "LOOP", "FILTER", "LEAVE", "SET_HOME", "RECOVER", "RESTART",
}

function M.register(cfg)
  local dashboard = require("dashboard")
  local music_bots = cfg.music_bots

  local function session_view(a)
    if not a then return { authenticated = false } end
    return {
      authenticated = true, username = a.username, site_owner = a.site_owner == true,
      admin_mode = a.admin_mode == true, moderator = a.moderator == true,
      image_gallery_owner = (a.admin_mode == true) and (a.site_owner == true),
    }
  end

  local function page_shell(req, a, path, title, body_html, extra_script)
    local script = ([[<script>%s</script>]]):format(extra_script or "")
    return 200, html.layout({
      title = title, path = path, session = session_view(a),
      token = req.cookies and req.cookies.swarm_session,
      body = body_html .. script,
    }), { ["Content-Type"] = "text/html; charset=utf-8" }
  end

  -- -----------------------------------------------------------------
  -- Controls
  -- -----------------------------------------------------------------
  httpd.route("GET", "/controls", function(req)
    local a, status, headers = cfg.require_auth_page(req)
    if not a then return status, "", headers end

    local data = dashboard.get_dashboard_data(music_bots)
    local bot_options = {}
    for _, bot in ipairs(data.bots) do
      bot_options[#bot_options + 1] = ("<option value=\"%s\">%s</option>"):format(html.esc(bot.key), html.esc(bot.display_name))
    end
    local action_options = {}
    for _, act in ipairs(CONTROL_ACTIONS) do
      action_options[#action_options + 1] = ("<option value=\"%s\">%s</option>"):format(html.esc(act), html.esc(act))
    end

    local body = html.page({
      title = "Controls", eyebrow = "Direct Control", lede = "Send a direct order to any bot in any guild.",
      body = ([[
        <form id="control-form" class="panel form-panel">
          <label class="field">Bot<select name="bot_key" required>%s</select></label>
          <label class="field">Guild ID<input type="text" name="guild_id" required placeholder="1247394560007471134"></label>
          <label class="field">Action<select name="action">%s</select></label>
          <label class="field">Source URL / search (PLAY only)<input type="text" name="source_url" placeholder="https://... or search terms"></label>
          <label class="field">Voice channel ID<input type="text" name="voice_channel_id"></label>
          <label class="field">Text channel ID<input type="text" name="text_channel_id"></label>
          <label class="field">Loop mode (LOOP only)<select name="loop_mode"><option value="off">off</option><option value="song">song</option><option value="queue">queue</option></select></label>
          <label class="field">Filter mode (FILTER only)<select name="filter_mode"><option value="none">none</option><option value="bassboost">bassboost</option><option value="nightcore">nightcore</option><option value="vaporwave">vaporwave</option><option value="8d">8d</option></select></label>
          <button type="submit" class="button-link primary">Send</button>
        </form>
        <div id="control-result"></div>
        %s
        <div id="control-state" class="control-state"></div>
        %s
        <div id="saved-queues"></div>
      ]]):format(html.join(bot_options), html.join(action_options),
        html.section_head("Control State"), html.section_head("Saved Queues")),
    })

    local script = [[
      const PAYLOAD_FIELDS = {
        PLAY: ["source_url", "voice_channel_id", "text_channel_id"],
        SMART_RECOMMEND: ["voice_channel_id", "text_channel_id"],
        SET_HOME: ["voice_channel_id"],
        LOOP: ["loop_mode"],
        FILTER: ["filter_mode"],
      };
      const form = document.getElementById("control-form");
      form.addEventListener("submit", async (e) => {
        e.preventDefault();
        const fd = new FormData(form);
        const action = fd.get("action");
        const fields = PAYLOAD_FIELDS[action] || [];
        const payload = {};
        for (const f of fields) payload[f] = fd.get(f);
        const box = document.getElementById("control-result");
        try {
          const res = await swarmFetch("/api/bots/control", {
            method: "POST",
            body: JSON.stringify({ bot_key: fd.get("bot_key"), guild_id: fd.get("guild_id"), action, payload }),
          });
          box.innerHTML = '<div class="notice notice-success">' + (res.message || "Order sent.") + "</div>";
          swarmToast("Order sent.", "success");
          refreshControlState();
        } catch (err) {
          box.innerHTML = '<div class="notice notice-error">' + err.message + "</div>";
        }
      });

      async function refreshControlState() {
        const botKey = form.bot_key.value, guildId = form.guild_id.value;
        if (!botKey || !guildId) return;
        try {
          const state = await swarmFetch(`/api/bots/${botKey}/control-state?guild_id=${encodeURIComponent(guildId)}`);
          document.getElementById("control-state").innerHTML =
            '<pre class="json-panel">' + JSON.stringify(state, null, 2).replace(/</g, "&lt;") + "</pre>";
        } catch { /* not ready yet */ }
      }
      form.bot_key.addEventListener("change", refreshControlState);
      form.guild_id.addEventListener("change", refreshControlState);
      swarmLiveRefresh(refreshControlState, 4000);

      async function loadQueues() {
        const botKey = form.bot_key.value, guildId = form.guild_id.value;
        if (!botKey || !guildId) return;
        try {
          const res = await swarmFetch(`/api/queues?guild_id=${encodeURIComponent(guildId)}&bot_key=${botKey}`);
          const rows = (res.queues || []).map((q) =>
            `<li>${q.name} <button type="button" data-load-queue="${q.id}">Load</button> <button type="button" data-delete-queue="${q.id}">Delete</button></li>`
          ).join("");
          document.getElementById("saved-queues").innerHTML = "<ul>" + (rows || "<li>No saved queues.</li>") + "</ul>";
        } catch { /* ignore */ }
      }
      swarmLiveRefresh(loadQueues, 30000);
      document.getElementById("saved-queues").addEventListener("click", async (e) => {
        const del = e.target.getAttribute("data-delete-queue");
        if (del) {
          await swarmFetch(`/api/queues/${del}/delete`, { method: "POST" }).catch(() => {});
          loadQueues();
        }
      });
    ]]

    return page_shell(req, a, "/controls", "Controls", body, script)
  end)

  -- -----------------------------------------------------------------
  -- Invites
  -- -----------------------------------------------------------------
  httpd.route("GET", "/invites", function(req)
    local a, status, headers = cfg.require_auth_page(req)
    if not a then return status, "", headers end
    local body = html.page({
      title = "Invites", eyebrow = "Fleet", lede = "Invite links for every bot in the swarm.",
      body = '<div id="invite-cards" class="invite-grid">' .. html.empty_state("Loading...") .. "</div>",
    })
    local script = [[
      async function loadInvites() {
        try {
          const res = await swarmFetch("/api/bots");
          const cards = (res.invite_bots || res.bots || []).map((b) => `
            <div class="invite-card">
              <div class="bot-now"><strong>${b.name || b.display_name}</strong></div>
              <p>
                ${b.invite_url ? `<a class="button-link primary" href="${b.invite_url}" target="_blank" rel="noreferrer">Invite</a>` : "<span>No invite available</span>"}
              </p>
            </div>`).join("");
          document.getElementById("invite-cards").innerHTML = cards || "<p>No bots found.</p>";
        } catch (err) { swarmToast("Failed to load bots.", "error"); }
      }
      swarmLiveRefresh(loadInvites, 5000);
    ]]
    return page_shell(req, a, "/invites", "Invites", body, script)
  end)

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
    local body = html.page({
      title = "Leaderboard", eyebrow = "Music Intelligence", lede = "Top tracks and listeners.",
      body = ([[
        <form id="lb-form" class="panel form-panel">
          <label class="field">Bot<select name="bot_key">%s</select></label>
          <label class="field">Guild ID<input type="text" name="guild_id" required></label>
          <button type="submit" class="button-link primary">Load</button>
        </form>
        %s
        <div id="lb-results"></div>
        %s
        <div id="lb-swarm"></div>
      ]]):format(html.join(bot_options), html.section_head("Guild Leaderboard"),
        a.admin_mode and html.section_head("Swarm-wide (admin)") or ""),
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
  -- Users
  -- -----------------------------------------------------------------
  httpd.route("GET", "/users", function(req)
    local a, status, headers = cfg.require_auth_page(req)
    if not a then return status, "", headers end
    local body = html.page({
      title = "Users", eyebrow = "Directory", lede = "Find other operators in the swarm.",
      body = '<input type="search" placeholder="Search users..." data-debounced-search id="user-search">'
        .. '<div id="user-results" class="user-grid">' .. html.empty_state("Start typing to search.") .. "</div>",
    })
    local script = [[
      async function renderUsers(q) {
        try {
          const res = await swarmFetch("/api/users/directory?q=" + encodeURIComponent(q || ""));
          const cards = (res.users || []).map((u) => `
            <div class="user-card">
              <div class="bot-now"><strong>${(u.display_name || u.username).replace(/</g,"&lt;")}</strong></div>
              <p>
                <a href="/users/${u.id}">View profile</a>
                <button type="button" data-follow="${u.id}">Follow</button>
                <button type="button" data-friend="${u.id}">Add friend</button>
              </p>
            </div>`).join("");
          document.getElementById("user-results").innerHTML = cards || "<p>No users found.</p>";
        } catch (err) { swarmToast("Search failed.", "error"); }
      }
      document.getElementById("user-search").addEventListener("swarm:search", (e) => renderUsers(e.detail.query));
      renderUsers("");
      document.getElementById("user-results").addEventListener("click", async (e) => {
        const followId = e.target.getAttribute("data-follow");
        const friendId = e.target.getAttribute("data-friend");
        try {
          if (followId) await swarmFetch(`/api/users/${followId}/follow`, { method: "POST" });
          if (friendId) await swarmFetch(`/api/users/${friendId}/friend-request`, { method: "POST" });
          if (followId || friendId) swarmToast("Done.", "success");
        } catch (err) { swarmToast(err.message, "error"); }
      });
    ]]
    return page_shell(req, a, "/users", "Users", body, script)
  end)

  -- -----------------------------------------------------------------
  -- Friends
  -- -----------------------------------------------------------------
  httpd.route("GET", "/friends", function(req)
    local a, status, headers = cfg.require_auth_page(req)
    if not a then return status, "", headers end
    local body = html.page({
      title = "Friends", eyebrow = "Social", lede = "Requests and confirmed friends.",
      body = [[
        <div class="friends-columns">
          <div><h3>Incoming</h3><div id="friends-incoming"></div></div>
          <div><h3>Outgoing</h3><div id="friends-outgoing"></div></div>
          <div><h3>Friends</h3><div id="friends-list"></div></div>
        </div>
      ]],
    })
    local script = [[
      async function loadFriends() {
        try {
          const reqs = await swarmFetch("/api/friends/requests");
          const incoming = (reqs.incoming || []).map((r) =>
            `<div class="friend-row">${(r.username||"").replace(/</g,"&lt;")} <button data-accept="${r.id}">Accept</button> <button data-decline="${r.id}">Decline</button></div>`).join("");
          const outgoing = (reqs.outgoing || []).map((r) =>
            `<div class="friend-row">${(r.username||"").replace(/</g,"&lt;")} <button data-cancel="${r.id}">Cancel</button></div>`).join("");
          document.getElementById("friends-incoming").innerHTML = incoming || "<p>None.</p>";
          document.getElementById("friends-outgoing").innerHTML = outgoing || "<p>None.</p>";
          const friends = await swarmFetch("/api/me/friends");
          document.getElementById("friends-list").innerHTML =
            (friends.friends || []).map((f) => `<div class="friend-row">${(f.username||"").replace(/</g,"&lt;")}</div>`).join("") || "<p>No friends yet.</p>";
        } catch (err) { swarmToast("Failed to load friends.", "error"); }
      }
      swarmLiveRefresh(loadFriends, 5000);
      document.body.addEventListener("click", async (e) => {
        const id = e.target.getAttribute("data-accept") || e.target.getAttribute("data-decline") || e.target.getAttribute("data-cancel");
        if (!id) return;
        const action = e.target.hasAttribute("data-accept") ? "accept" : e.target.hasAttribute("data-decline") ? "decline" : "cancel";
        try {
          await swarmFetch(`/api/friends/requests/${id}`, { method: "POST", body: JSON.stringify({ action }) });
          loadFriends();
        } catch (err) { swarmToast(err.message, "error"); }
      });
    ]]
    return page_shell(req, a, "/friends", "Friends", body, script)
  end)
end

return M
