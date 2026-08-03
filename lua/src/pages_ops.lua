-- Server-rendered pages: Controls, Invites, Leaderboard, Users, Friends.
-- Pattern: render the page shell + static structure server-side via
-- html.lua, then populate live/interactive data with inline JS calling the
-- SAME JSON API the old React app used (swarmFetch, from static/app.js).
local httpd = require("httpd")
local html = require("html")
local accounts = require("accounts")

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
    local prefs = a and accounts.get_panel_preferences(a.username, a.guild_id) or nil
    return 200, html.layout({
      title = title, path = path, session = session_view(a),
      token = req.cookies and req.cookies.swarm_session, preferences = prefs,
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

    -- Mirrors ControlsPage.jsx's form.guild_id default: a guild-scoped
    -- account's own registered guild (ctx.session.guild_id), read-only --
    -- POST /api/bots/control now rejects any other guild_id for a scoped
    -- account anyway (require_bot_guild_access), so letting them type an
    -- arbitrary one here was never actually usable, just confusing. Admins
    -- get it pre-filled from the first live session (also matching the
    -- React fallback: dash.sessions?.[0]?.guild_id) but still editable,
    -- since they can legitimately target any guild.
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
      or ('<label class="field">Guild ID<input type="text" name="guild_id" required value="%s" placeholder="1247394560007471134"></label>'):format(html.esc(default_guild_id or ""))

    local body = html.page({
      title = "Controls", eyebrow = "Direct Control", lede = "Send a direct order to any bot in any guild.",
      body = ([[
        <form id="control-form" class="panel form-panel">
          <label class="field">Bot<select name="bot_key" required>%s</select></label>
          %s
          <label class="field">Action<select name="action">%s</select></label>
          <label class="field">Source URL / search (PLAY only)<input type="text" name="source_url" placeholder="https://... or search terms"></label>
          <label class="field">Voice channel<select name="voice_channel_id"><option value="">Choose channel</option></select></label>
          <label class="field">Text channel<select name="text_channel_id"><option value="">None</option></select></label>
          <label class="field">Loop mode (LOOP only)<select name="loop_mode"><option value="off">off</option><option value="song">song</option><option value="queue">queue</option></select></label>
          <label class="field">Filter mode (FILTER only)<select name="filter_mode">
            <option value="none">None</option>
            <option value="nightcore">Nightcore</option>
            <option value="bassboost">Bassboost</option>
            <option value="vaporwave">Vaporwave</option>
            <option value="8d">8D</option>
            <option value="karaoke">Karaoke</option>
            <option value="tremolo">Tremolo</option>
            <option value="vibrato">Vibrato</option>
            <option value="lowpass">Low Pass</option>
            <option value="lofi">Lo-fi</option>
            <option value="electronic">Electronic</option>
            <option value="party">Party</option>
            <option value="radio">Radio</option>
            <option value="cinema">Cinema</option>
          </select></label>
          <button type="submit" class="button-link primary">Send</button>
        </form>
        <div id="control-result"></div>
        %s
        <div id="control-state" class="control-state"></div>
        %s
        <div id="saved-queues"></div>
      ]]):format(html.join(bot_options), guild_field, html.join(action_options),
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
          // Mirrors ControlsPage.jsx's controlState effect: voice/text channel
          // are one-time defaults (only fill an empty field -- never clobber
          // what the operator is mid-typing for a PLAY/SET_HOME order), while
          // loop_mode/filter_mode always reflect the bot's actual live
          // setting, since those aren't per-order inputs, they're "what is
          // this guild currently configured to do" (was previously stuck on
          // the form's hardcoded "off"/"none" defaults regardless of what
          // the bot was really set to -- e.g. every bot defaults to
          // loop_mode=queue, but the form never showed that).
          const session = state && state.session;
          if (session) {
            // voice/text channel selects are populated asynchronously by
            // loadChannels() below (real channel NAMES, not raw IDs -- a
            // bare numeric snowflake told you nothing about which channel
            // you were about to target), so the desired id is stashed here
            // and applied once loadChannels() has real <option>s to match
            // against, instead of writing straight to .value (which is a
            // silent no-op on a <select> with no matching <option> yet).
            if (!form.voice_channel_id.value) {
              pendingVoiceChannelId = session.home_channel_id || session.channel_id || "";
              applyPendingChannelValue(form.voice_channel_id, pendingVoiceChannelId);
            }
            if (!form.text_channel_id.value) {
              pendingTextChannelId = session.feedback_channel_id || "";
              applyPendingChannelValue(form.text_channel_id, pendingTextChannelId);
            }
            if (session.loop_mode) form.loop_mode.value = session.loop_mode;
            if (session.filter_mode) form.filter_mode.value = session.filter_mode;
          }
        } catch { /* not ready yet */ }
      }
      // Switching bots left guild_id pointed at whatever guild the PREVIOUS
      // bot defaulted to -- if the new bot isn't even in that guild,
      // control-state/inventory still return 200 (guild_id is valid, just
      // not one this bot serves) with an empty/idle session, so the page
      // looked like nothing happened. Re-pick a guild the newly selected
      // bot actually has a live session in (falls back to its first known
      // guild) whenever guild_id is editable, mirroring the page-load
      // default-guild logic in the route handler above.
      async function pickGuildForBot(botKey) {
        try {
          const dash = await swarmFetch("/api/dashboard");
          const bot = (dash.bots || []).find((b) => b.key === botKey);
          if (!bot) return null;
          const sessions = bot.sessions || [];
          const live = sessions.find((s) => s.is_playing) || sessions[0];
          if (live && live.guild_id) return String(live.guild_id);
        } catch { /* fall through */ }
        return null;
      }
      form.bot_key.addEventListener("change", async () => {
        if (!form.guild_id.readOnly) {
          const guild = await pickGuildForBot(form.bot_key.value);
          if (guild) form.guild_id.value = guild;
        }
        refreshControlState();
        loadChannels();
      });
      form.guild_id.addEventListener("change", () => { refreshControlState(); loadChannels(); });
      swarmLiveRefresh(refreshControlState, 4000);

      let pendingVoiceChannelId = "", pendingTextChannelId = "";
      let channelsRequestId = 0;
      const VOICE_TYPES = new Set([2, 13]);
      const TEXT_TYPES = new Set([0, 5, 10, 11, 12]);
      function fillChannelSelect(select, channels, keepValue) {
        const current = keepValue || select.value;
        select.innerHTML = '<option value="">' + (select.name === "text_channel_id" ? "None" : "Choose channel") + "</option>"
          + channels.map((c) => `<option value="${c.id}">${(c.name || c.id).replace(/</g, "&lt;")}</option>`).join("");
        if (current && channels.some((c) => String(c.id) === String(current))) select.value = current;
      }
      // refreshControlState() polls independently of loadChannels() -- if a
      // session's home channel arrives after the select is already
      // populated, nothing would otherwise re-apply it until the next
      // loadChannels() call, so try to select it immediately too.
      function applyPendingChannelValue(select, value) {
        if (value && [...select.options].some((o) => o.value === String(value))) select.value = value;
      }
      async function loadChannels() {
        const botKey = form.bot_key.value, guildId = form.guild_id.value;
        if (!botKey || !guildId) return;
        // bot_key/guild_id changes and the initial call can overlap in
        // flight; only the response to the MOST RECENT request may write
        // to the selects, or a slow stale fetch can clobber a faster
        // newer one and silently leave the wrong guild's channels showing.
        const requestId = ++channelsRequestId;
        try {
          const inv = await swarmFetch(`/api/bots/${botKey}/inventory`);
          if (requestId !== channelsRequestId) return;
          const guild = (inv.guilds || []).find((g) => String(g.id) === String(guildId));
          const channels = (guild && guild.channels) || [];
          fillChannelSelect(form.voice_channel_id, channels.filter((c) => VOICE_TYPES.has(Number(c.type))), pendingVoiceChannelId);
          fillChannelSelect(form.text_channel_id, channels.filter((c) => TEXT_TYPES.has(Number(c.type))), pendingTextChannelId);
          pendingVoiceChannelId = ""; pendingTextChannelId = "";
        } catch { /* bot token/inventory unavailable -- selects just stay empty */ }
      }
      loadChannels();

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
      title = "Leaderboard", eyebrow = "Music Intelligence", lede = "Top tracks and listeners.",
      body = ([[
        <form id="lb-form" class="panel form-panel">
          <label class="field">Bot<select name="bot_key">%s</select></label>
          %s
          <button type="submit" class="button-link primary">Load</button>
        </form>
        %s
        <div id="lb-results"></div>
        %s
        <div id="lb-swarm"></div>
      ]]):format(html.join(bot_options), guild_field, html.section_head("Guild Leaderboard"),
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
      function escUser(s) { return String(s == null ? "" : s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }
      function userInitials(label) {
        const parts = String(label || "").trim().split(/\s+/).filter(Boolean);
        if (!parts.length) return "SP";
        return (parts[0][0] + (parts[1] ? parts[1][0] : "")).toUpperCase();
      }
      function titleCaseUser(s) { return String(s || "").replace(/[_-]+/g, " ").replace(/\b\w/g, (c) => c.toUpperCase()); }
      // Full port of UserCard from components/swarm.jsx -- the first pass
      // only rendered the display name and three bare buttons, so avatars,
      // handles, guild/favorite-bot chips, and follower/friend counts (all
      // already returned by /api/users/directory) never showed up anywhere
      // in the directory.
      async function renderUsers(q) {
        try {
          const res = await swarmFetch("/api/users/directory?q=" + encodeURIComponent(q || ""));
          const cards = (res.users || []).map((u) => {
            const imageUrl = u.avatar_url || u.server_icon_url || "";
            const displayName = u.display_name || u.username || "Unknown operator";
            const guildLabel = u.server_name || u.profile_headline || (u.guild_id ? `Guild ${u.guild_id}` : "Swarm directory");
            const favoriteBot = u.favorite_bot ? titleCaseUser(u.favorite_bot) : "No favorite";
            const avatarImg = imageUrl ? `<img class="avatar-image" src="${escUser(imageUrl)}" alt="">` : `<span class="avatar-fallback">${escUser(userInitials(displayName))}</span>`;
            const friendLocked = ["friends", "pending_out", "self"].includes(u.friend_status);
            const friendLabel = u.friend_status === "friends" ? "Friends" : u.friend_status === "pending_out" ? "Pending" : "Friend";
            return `
            <article class="user-card">
              <div class="user-card-main">
                <a class="avatar-link" href="/users/${u.id}">
                  <div class="avatar avatar-lg avatar-presence">${avatarImg}<span class="presence-dot avatar-dot ${u.is_online ? "online" : "inactive"}" aria-hidden="true"></span></div>
                </a>
                <div class="user-card-copy">
                  <div class="user-card-head">
                    <a href="/users/${u.id}"><h3>${escUser(displayName)}</h3></a>
                    <span class="presence-pill compact ${u.is_online ? "online" : "inactive"}"><span class="presence-dot" aria-hidden="true"></span>${u.is_online ? "Online" : "Inactive"}</span>
                  </div>
                  <p class="user-card-handle">@${escUser(u.username || "operator")}</p>
                  <p class="user-card-guild">${escUser(guildLabel)}</p>
                  <div class="chip-row user-card-tags">
                    <span>${escUser(favoriteBot)}</span>
                    ${u.server_name ? `<span>${escUser(u.server_name)}</span>` : ""}
                  </div>
                </div>
              </div>
              <div class="user-card-stats">
                <article><strong>${u.follower_count || 0}</strong><span>Followers</span></article>
                <article><strong>${u.friend_count || 0}</strong><span>Friends</span></article>
                <article><strong>${escUser(favoriteBot)}</strong><span>Favorite Bot</span></article>
              </div>
              <div class="inline-controls user-card-actions">
                <a class="button-link" href="/users/${u.id}">Open</a>
                <button type="button" data-follow="${u.id}" data-following="${u.followed_by_me ? "1" : ""}">${u.followed_by_me ? "Unfollow" : "Follow"}</button>
                <button type="button" data-friend="${u.id}" ${friendLocked ? "disabled" : ""}>${escUser(friendLabel)}</button>
                <a class="button-link" href="/messages">Message</a>
              </div>
            </article>`;
          }).join("");
          document.getElementById("user-results").innerHTML = cards || "<p>No users found.</p>";
        } catch (err) { swarmToast("Search failed.", "error"); }
      }
      document.getElementById("user-search").addEventListener("swarm:search", (e) => renderUsers(e.detail.query));
      renderUsers("");
      document.getElementById("user-results").addEventListener("click", async (e) => {
        const followId = e.target.getAttribute("data-follow");
        const friendId = e.target.getAttribute("data-friend");
        try {
          if (followId) {
            const wasFollowing = e.target.getAttribute("data-following") === "1";
            await swarmFetch(`/api/users/${followId}/follow`, { method: "POST", body: JSON.stringify({ following: !wasFollowing }) });
            renderUsers(document.getElementById("user-search").value);
          }
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
