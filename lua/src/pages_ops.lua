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
      guild_id = a.guild_id,
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
    -- Shows the guild's real NAME (resolved client-side from the bot's
    -- Discord inventory, same data the voice/text channel pickers already
    -- use) instead of a bare numeric ID -- the ID is still exactly what
    -- gets submitted (this <select>'s value), just never what's displayed.
    -- A scoped account gets exactly one <option> (its own guild) -- enabled,
    -- not disabled, since a disabled field is excluded from FormData.
    local guild_field = own_guild_id
      and ('<label class="field field-inline">Guild<select name="guild_id" id="control-guild-id" data-scoped="1"><option value="%s">Guild %s</option></select><button type="button" class="field-inline-action" data-copy-target="#control-guild-id">Copy ID</button></label>'):format(html.esc(own_guild_id), html.esc(own_guild_id))
      or ('<label class="field field-inline">Guild<select name="guild_id" id="control-guild-id" required><option value="%s">%s</option></select><button type="button" class="field-inline-action" data-copy-target="#control-guild-id">Copy ID</button></label>'):format(html.esc(default_guild_id or ""), default_guild_id and ("Guild " .. html.esc(default_guild_id)) or "Choose a guild")

    local body = html.page({
      title = "Controls", eyebrow = "Direct Control", lede = "Send a direct order to any bot in any guild.",
      body = ([[
        <div class="control-layout">
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
          <div class="command-preview-grid">
            <div class="preview-card"><span>Bot</span><strong id="cmd-preview-bot">--</strong></div>
            <div class="preview-card"><span>Action</span><strong id="cmd-preview-action">--</strong></div>
            <div class="preview-card"><span>Guild</span><strong id="cmd-preview-guild">--</strong></div>
            <div class="preview-card command-preview-primary" id="cmd-preview-summary">Choose a bot, action, and guild above to preview the order before sending.</div>
          </div>
          <button type="submit" class="button-link primary">Send</button>
        </form>
        <div>
        <div id="control-result"></div>
        %s
        <div id="control-state" class="control-state"></div>
        %s
        <div id="saved-queues"></div>
        %s
        </div>
        </div>
      ]]):format(html.join(bot_options), guild_field, html.join(action_options),
        html.section_head("Control State"), html.section_head("Saved Queues"),
        a.admin_mode and ([[
          %s
          <div class="panel">
            <p>Sends RECOVER to every bot/guild session fleet-wide currently sitting in "Recovery Pending".</p>
            <button type="button" id="recover-all-btn" class="button-link primary">Recover All Stale Sessions</button>
            <div id="recover-all-result"></div>
          </div>
        ]]):format(html.section_head("Fleet Recovery")) or ""),
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
      // command-preview-grid/-primary had CSS but nothing rendered it -- a
      // plain-language readout of what the form will actually send, kept in
      // sync with every field change so it's accurate right up to submit.
      function updateCommandPreview() {
        const botLabel = form.bot_key.selectedOptions[0] ? form.bot_key.selectedOptions[0].textContent : "--";
        const action = form.action.value || "--";
        const guildLabel = form.guild_id.selectedOptions[0] ? form.guild_id.selectedOptions[0].textContent : "--";
        document.getElementById("cmd-preview-bot").textContent = botLabel;
        document.getElementById("cmd-preview-action").textContent = action;
        document.getElementById("cmd-preview-guild").textContent = guildLabel;
        const summary = document.getElementById("cmd-preview-summary");
        if (form.bot_key.value && form.guild_id.value) {
          let detail = "";
          if (action === "PLAY" && form.source_url.value) detail = ` with "${form.source_url.value}"`;
          else if (action === "LOOP") detail = ` (${form.loop_mode.value})`;
          else if (action === "FILTER") detail = ` (${form.filter_mode.value})`;
          summary.textContent = `${botLabel} will run ${action}${detail} in ${guildLabel}.`;
        } else {
          summary.textContent = "Choose a bot, action, and guild above to preview the order before sending.";
        }
      }
      form.addEventListener("input", updateCommandPreview);
      form.addEventListener("change", updateCommandPreview);
      updateCommandPreview();
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
          const stateBox = document.getElementById("control-state");
          stateBox.innerHTML = '<pre class="json-panel">' + JSON.stringify(state, null, 2).replace(/</g, "&lt;") + "</pre>";
          // .state-recovering already existed in CSS (recovering-pulse
          // keyframe) but nothing ever applied it -- an operator watching
          // this panel had no visual cue that a session was mid-recovery.
          stateBox.classList.toggle("state-recovering", !!(state && state.session && state.session.session_state === "recovering"));
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
      let pendingGuildId = "";
      form.bot_key.addEventListener("change", async () => {
        if (form.guild_id.dataset.scoped !== "1") {
          // Setting .value directly here would silently no-op -- the new
          // bot's guild options (real names) haven't loaded yet, so there's
          // no matching <option> to select. Stash it; loadChannels() below
          // applies it once fillGuildSelect() has real options to match
          // against, same pattern the voice/text channel selects already use.
          pendingGuildId = (await pickGuildForBot(form.bot_key.value)) || "";
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
      // Real guild NAMES (from the bot's Discord inventory) instead of bare
      // IDs -- the <select>'s value stays the ID either way, only the
      // visible <option> text changes. A scoped account's select only ever
      // has its own single guild, so it's left alone here (repopulating it
      // from the bot's full guild list would leak other guilds' names into
      // an account that's not supposed to see them) -- just its one
      // option's label gets the real name once inventory has it.
      function fillGuildSelect(guilds) {
        const select = form.guild_id;
        if (select.dataset.scoped === "1") {
          const own = guilds.find((g) => String(g.id) === select.value);
          if (own && select.options[0]) select.options[0].textContent = own.name || select.options[0].textContent;
          return;
        }
        const current = pendingGuildId || select.value;
        select.innerHTML = guilds.map((g) => `<option value="${g.id}">${(g.name || g.id).toString().replace(/</g, "&lt;")}</option>`).join("")
          || `<option value="">No guilds found</option>`;
        if (current && guilds.some((g) => String(g.id) === String(current))) select.value = current;
        pendingGuildId = "";
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
          fillGuildSelect(inv.guilds || []);
          const resolvedGuildId = form.guild_id.value;
          const guild = (inv.guilds || []).find((g) => String(g.id) === String(resolvedGuildId));
          const channels = (guild && guild.channels) || [];
          fillChannelSelect(form.voice_channel_id, channels.filter((c) => VOICE_TYPES.has(Number(c.type))), pendingVoiceChannelId);
          fillChannelSelect(form.text_channel_id, channels.filter((c) => TEXT_TYPES.has(Number(c.type))), pendingTextChannelId);
          pendingVoiceChannelId = ""; pendingTextChannelId = "";
          updateCommandPreview();
        } catch { /* bot token/inventory unavailable -- selects just stay empty */ }
      }
      loadChannels();

      let savedQueues = [];
      async function loadQueues() {
        const botKey = form.bot_key.value, guildId = form.guild_id.value;
        if (!botKey || !guildId) return;
        try {
          const res = await swarmFetch(`/api/queues?guild_id=${encodeURIComponent(guildId)}&bot_key=${botKey}`);
          savedQueues = res.queues || [];
          const rows = savedQueues.map((q) => `
            <div class="collection-row" data-load-queue="${q.id}">
              <span><strong>${(q.name || "").replace(/</g, "&lt;")}</strong><small>${(q.items || []).length} track${(q.items || []).length === 1 ? "" : "s"}</small></span>
              <button type="button" class="icon-button" data-rename-queue="${q.id}" title="Rename">&#9998;</button>
              <button type="button" class="icon-button" data-delete-queue="${q.id}" title="Delete">&times;</button>
            </div>`
          ).join("");
          document.getElementById("saved-queues").innerHTML = `<div class="list-panel">${rows || '<div class="empty-state">No saved queues.</div>'}</div>`;
        } catch { /* ignore */ }
      }
      swarmLiveRefresh(loadQueues, 30000);
      document.getElementById("saved-queues").addEventListener("click", async (e) => {
        const del = e.target.getAttribute("data-delete-queue");
        if (del) {
          e.stopPropagation();
          await swarmFetch(`/api/queues/${del}/delete`, { method: "POST" }).catch(() => {});
          loadQueues();
          return;
        }
        // Inline rename: swaps the row's display for a mini-form
        // (mini-row/mini-input CSS existed, unused) instead of a full page
        // or a native prompt(), matching the rest of this codebase's
        // no-prompt() convention.
        const renameId = e.target.getAttribute("data-rename-queue");
        if (renameId) {
          e.stopPropagation();
          const row = e.target.closest("[data-load-queue]");
          const queue = savedQueues.find((q) => String(q.id) === renameId);
          if (!row || !queue) return;
          row.innerHTML = `
            <form class="mini-form" data-rename-form="${renameId}">
              <div class="mini-row">
                <input class="mini-input" name="name" value="${(queue.name || "").replace(/"/g, "&quot;")}" maxlength="120" required>
                <button type="submit">Save</button>
                <button type="button" data-cancel-rename>Cancel</button>
              </div>
            </form>`;
          row.querySelector("input").focus();
          return;
        }
        if (e.target.hasAttribute("data-cancel-rename")) { e.stopPropagation(); loadQueues(); return; }
        if (e.target.closest("[data-rename-form]")) return;
        // "Load" a saved queue: previously a dead button (data-load-queue
        // rendered but never listened for) -- replays every saved track by
        // sending each as its own PLAY order in sequence, same as manually
        // re-queueing them one at a time from the form above.
        const row = e.target.closest("[data-load-queue]");
        if (!row) return;
        const queue = savedQueues.find((q) => String(q.id) === row.getAttribute("data-load-queue"));
        if (!queue || !(queue.items || []).length) return;
        const botKey = form.bot_key.value, guildId = form.guild_id.value;
        let queued = 0;
        for (const item of queue.items) {
          try {
            await swarmFetch("/api/bots/control", {
              method: "POST",
              body: JSON.stringify({ bot_key: botKey, guild_id: guildId, action: "PLAY", payload: { source_url: item.video_url } }),
            });
            queued++;
          } catch { /* keep going through the rest of the queue */ }
        }
        swarmToast(`Queued ${queued}/${queue.items.length} track(s) from "${queue.name}".`, queued ? "success" : "error");
        refreshControlState();
      });
      document.getElementById("saved-queues").addEventListener("submit", async (e) => {
        const renameForm = e.target.closest("[data-rename-form]");
        if (!renameForm) return;
        e.preventDefault();
        const id = renameForm.getAttribute("data-rename-form");
        const name = renameForm.elements.name.value.trim();
        if (!name) return;
        try {
          await swarmFetch(`/api/queues/${id}/rename`, { method: "POST", body: JSON.stringify({ guild_id: form.guild_id.value, name }) });
          swarmToast("Renamed.", "success");
          loadQueues();
        } catch (err) { swarmToast(err.message, "error"); }
      });
    ]] .. [[
      const recoverAllBtn = document.getElementById("recover-all-btn");
      if (recoverAllBtn) {
        recoverAllBtn.addEventListener("click", async () => {
          const resultBox = document.getElementById("recover-all-result");
          recoverAllBtn.disabled = true;
          resultBox.innerHTML = "";
          try {
            const dash = await swarmFetch("/api/dashboard");
            const targets = [];
            for (const bot of (dash.bots || [])) {
              for (const session of (bot.sessions || [])) {
                if (session.session_state === "recovering" && session.guild_id) {
                  targets.push({ bot_key: bot.key, guild_id: String(session.guild_id) });
                }
              }
            }
            if (targets.length === 0) {
              resultBox.innerHTML = '<div class="notice notice-success">Nothing to recover — no sessions pending.</div>';
              return;
            }
            let succeeded = 0, failed = 0;
            for (const t of targets) {
              try {
                await swarmFetch("/api/bots/control", {
                  method: "POST",
                  body: JSON.stringify({ bot_key: t.bot_key, guild_id: t.guild_id, action: "RECOVER" }),
                });
                succeeded++;
              } catch { failed++; }
            }
            resultBox.innerHTML = `<div class="notice notice-${failed ? "error" : "success"}">Recovered ${succeeded}/${targets.length} session(s)${failed ? `, ${failed} failed` : ""}.</div>`;
            swarmToast(`Recovery sent to ${succeeded}/${targets.length} session(s).`, failed ? "error" : "success");
            refreshControlState();
          } catch (err) {
            resultBox.innerHTML = '<div class="notice notice-error">' + err.message + "</div>";
          } finally {
            recoverAllBtn.disabled = false;
          }
        });
      }
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
          const cards = (res.invite_bots || res.bots || []).map((b) => {
            const avatar = b.icon_url
              ? `<img class="avatar invite-avatar" src="${b.icon_url}" alt="">`
              : `<span class="avatar invite-avatar avatar-fallback">${(b.identity_name || b.name || b.display_name || "?").slice(0, 1).toUpperCase()}</span>`;
            return `
            <div class="invite-card" style="--card-accent: ${b.accent || "#89b4fa"}">
              <div class="invite-card-head">
                ${avatar}
                <div class="invite-card-copy">
                  <strong>${b.name || b.display_name}</strong>
                  <small>${(b.capability_summary || "").replace(/</g, "&lt;")}</small>
                </div>
                ${b.connected_to_session_guild ? '<span class="data-pill data-pill-live">In your guild</span>' : ""}
              </div>
              ${b.identity_error ? `<p class="notice notice-error">${b.identity_error.replace(/</g, "&lt;")}</p>` : ""}
              <p>
                ${b.invite_url ? `<a class="button-link primary" href="${b.invite_url}" target="_blank" rel="noreferrer">Invite</a>` : "<span>No invite available</span>"}
              </p>
            </div>`;
          }).join("");
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
      title = "Learning", eyebrow = "Music Intelligence", lede = "What the swarm's smart-recommendation engine has learned.",
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

  -- -----------------------------------------------------------------
  -- Users
  -- -----------------------------------------------------------------
  httpd.route("GET", "/users", function(req)
    local a, status, headers = cfg.require_auth_page(req)
    if not a then return status, "", headers end
    local body = html.page({
      title = "Users", eyebrow = "Directory", lede = "Find other operators in the swarm.",
      body = [[
        <div class="directory-toolbar">
          <div class="search-box search-box-wide">
            <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true"><circle cx="7" cy="7" r="5" stroke="currentColor" stroke-width="1.6"/><path d="M11 11L14.5 14.5" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>
            <input type="search" placeholder="Search users..." data-debounced-search id="user-search">
          </div>
          <div class="directory-summary" id="user-summary"></div>
        </div>
        <div id="user-results" class="user-grid">]] .. html.skeleton_grid(6) .. [[</div>
      ]],
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
          const users = res.users || [];
          const onlineCount = users.filter((u) => u.is_online).length;
          document.getElementById("user-summary").innerHTML = users.length
            ? `<span>${users.length} shown</span><span>${onlineCount} online</span>`
            : "";
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
    -- BUGFIX: the bare env-configured admin login (settings.admin_username/
    -- admin_password -- see /api/login's `auth_result = { ... guild_id =
    -- nil, site_owner = true, admin_mode = true ... }`) has no `users` table
    -- row at all, so account_id_for_auth() in routes.lua can NEVER resolve
    -- an account_id for it -- every /api/friends/* and /api/me/friends call
    -- 403s with "Guild account access required", every single time,
    -- forever, for this account type. The page used to render the full
    -- interactive friends UI regardless and let the client-side fetch fail,
    -- surfacing as a generic "Failed to load friends." toast -- repeating
    -- every 5s via swarmLiveRefresh, since nothing ever stopped retrying.
    -- Friends/social features are inherently per-guild-account (see
    -- social.lua/accounts.lua's users-table-keyed model); the site-admin
    -- login genuinely has no social identity to attach them to. Detect that
    -- up front and show a clear explanation instead of a page that's
    -- guaranteed to error forever.
    if not a.guild_id then
      local body = html.page({
        title = "Friends", eyebrow = "Social", lede = "Requests and confirmed friends.",
        body = [[
          <div class="empty-state">
            <p>Friends and social features are tied to a guild account, not the site admin login.</p>
            <p>Log in with a guild account (one registered to a specific bot/guild) to use Friends.</p>
          </div>
        ]],
      })
      return page_shell(req, a, "/friends", "Friends", body, "")
    end
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
