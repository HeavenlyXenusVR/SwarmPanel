-- Server-rendered pages: Messages, Profile, Appearance, Diagnostics.
-- Same pattern as pages_ops.lua: shell server-side, data via swarmFetch
-- against the existing JSON API.
local httpd = require("httpd")
local html = require("html")
local accounts = require("accounts")

local M = {}

function M.register(cfg)
  local function session_view(a)
    if not a then return { authenticated = false } end
    return {
      authenticated = true, username = a.username, site_owner = a.site_owner == true,
      admin_mode = a.admin_mode == true, moderator = a.moderator == true,
      image_gallery_owner = (a.admin_mode == true) and (a.site_owner == true),
    }
  end

  local function page_shell(req, a, path, title, body_html, extra_script, prefs)
    local script = ([[<script>%s</script>]]):format(extra_script or "")
    prefs = prefs or (a and accounts.get_panel_preferences(a.username, a.guild_id)) or nil
    return 200, html.layout({
      title = title, path = path, session = session_view(a),
      token = req.cookies and req.cookies.swarm_session, preferences = prefs,
      body = body_html .. script,
    }), { ["Content-Type"] = "text/html; charset=utf-8" }
  end

  -- -----------------------------------------------------------------
  -- Messages
  -- -----------------------------------------------------------------
  httpd.route("GET", "/messages", function(req)
    local a, status, headers = cfg.require_auth_page(req)
    if not a then return status, "", headers end
    local body = html.page({
      title = "Messages", eyebrow = "Inbox", lede = "Direct messages with other operators.",
      body = [[
        <div class="messages-layout">
          <div class="messages-threads">
            <input type="search" placeholder="Find someone..." data-debounced-search id="msg-search">
            <div id="msg-search-results"></div>
            <div id="msg-threads"></div>
          </div>
          <div class="messages-conversation" id="msg-conversation">
            <p class="empty-state">Select a conversation.</p>
          </div>
        </div>
      ]],
    })
    local script = [[
      let activeThread = null;
      async function loadThreads() {
        try {
          const res = await swarmFetch("/api/messages/threads");
          document.getElementById("msg-threads").innerHTML = (res.threads || []).map((t) =>
            `<button type="button" class="thread-item" data-thread="${t.account_id}">${(t.username||"Unknown").replace(/</g,"&lt;")}</button>`
          ).join("") || "<p>No conversations yet.</p>";
        } catch { /* ignore */ }
      }
      async function openThread(id) {
        activeThread = id;
        const box = document.getElementById("msg-conversation");
        box.innerHTML = '<div id="msg-list"></div><form id="msg-form"><input name="body" placeholder="Message..." required><button type="submit">Send</button></form>';
        await loadMessages();
        document.getElementById("msg-form").addEventListener("submit", async (e) => {
          e.preventDefault();
          const input = e.target.body;
          if (!input.value.trim()) return;
          try {
            await swarmFetch(`/api/messages/${activeThread}`, { method: "POST", body: JSON.stringify({ body: input.value }) });
            input.value = "";
            loadMessages();
          } catch (err) { swarmToast(err.message, "error"); }
        });
      }
      async function loadMessages() {
        if (!activeThread) return;
        try {
          const res = await swarmFetch(`/api/messages/${activeThread}`);
          document.getElementById("msg-list").innerHTML = (res.messages || []).map((m) =>
            `<div class="msg-bubble ${m.mine ? "mine" : ""}">${(m.body||"").replace(/</g,"&lt;")}</div>`).join("");
        } catch { /* ignore */ }
      }
      document.getElementById("msg-threads").addEventListener("click", (e) => {
        const id = e.target.getAttribute("data-thread");
        if (id) openThread(id);
      });
      document.getElementById("msg-search").addEventListener("swarm:search", async (e) => {
        const q = e.detail.query;
        if (!q) { document.getElementById("msg-search-results").innerHTML = ""; return; }
        try {
          const res = await swarmFetch("/api/users/directory?q=" + encodeURIComponent(q));
          document.getElementById("msg-search-results").innerHTML = (res.users || []).map((u) =>
            `<button type="button" class="thread-item" data-thread="${u.id}">${(u.display_name||u.username).replace(/</g,"&lt;")}</button>`).join("");
        } catch { /* ignore */ }
      });
      document.getElementById("msg-search-results").addEventListener("click", (e) => {
        const id = e.target.getAttribute("data-thread");
        if (id) openThread(id);
      });
      swarmLiveRefresh(loadThreads, 5000);
      swarmLiveRefresh(loadMessages, 4000);
    ]]
    return page_shell(req, a, "/messages", "Messages", body, script)
  end)

  -- -----------------------------------------------------------------
  -- Profile (own /profile, public /users/:id)
  -- -----------------------------------------------------------------
  local function render_profile(req, is_public)
    local a, status, headers = cfg.require_auth_page(req)
    if not a then return status, "", headers end
    local target_id = is_public and req.params.id or nil

    local body, script
    if is_public then
      -- target_id (a raw URL path segment, httpd.lua's :id capture accepts
      -- any non-"/" bytes) is passed via a data-* attribute -- HTML-attribute
      -- escaping is the correct context there. It must NOT be interpolated
      -- directly into the <script> text below: that would need JS-string
      -- escaping, not HTML escaping, and getting that wrong is a real JS-
      -- injection hole (a crafted /users/<id> URL could break out of the
      -- quoted string literal).
      body = html.page({ title = "Profile", body = ('<div id="profile-view" data-profile-id="%s">%s</div>'):format(
        html.esc(target_id), html.empty_state("Loading...")) })
      -- Full public-card port of ProfilePage.jsx's publicMode branch -- the
      -- first pass only rendered display_name/bio and Follow/Friend/Message
      -- buttons, so avatar, banner, tags, favorite bot, server info, custom
      -- links, quote, and all the profile_banner_mode/card_style/
      -- border_accent visual styling (which /api/users/:id/profile already
      -- returns, straight off the account row) never rendered anywhere.
      script = [[
        (async () => {
          const view = document.getElementById("profile-view");
          const id = view.dataset.profileId;
          const BORDER_ACCENTS = new Set(["none", "glow", "pulse", "neon", "solid"]);
          function esc(s) { return String(s == null ? "" : s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }
          function initials(label) {
            const parts = String(label || "").trim().split(/\s+/).filter(Boolean);
            if (!parts.length) return "SP";
            return (parts[0][0] + (parts[1] ? parts[1][0] : "")).toUpperCase();
          }
          function avatarHtml(src, label, online, cls) {
            const img = src ? `<img class="avatar-image" src="${esc(src)}" alt="">` : `<span class="avatar-fallback">${esc(initials(label))}</span>`;
            return `<div class="${cls} avatar-presence">${img}<span class="presence-dot avatar-dot ${online ? "online" : "inactive"}" aria-hidden="true"></span></div>`;
          }
          try {
            const res = await swarmFetch("/api/users/" + encodeURIComponent(id) + "/profile");
            const p = res.profile || {};
            const perms = res.social_permissions || {};
            const activity = p.activity || {};
            const tags = Array.isArray(p.profile_tags) ? p.profile_tags.slice(0, 5) : [];
            const links = Array.isArray(p.profile_links) ? p.profile_links : [];
            const accent = p.theme_accent || "#89b4fa";
            const bannerMode = p.profile_banner_mode || "gradient";
            const cardStyle = p.profile_card_style || "solid";
            const borderAccent = BORDER_ACCENTS.has(String(p.profile_border_accent || "").toLowerCase()) ? p.profile_border_accent : "none";
            const heroStyle = `--accent:${accent};--profile-banner-url:${p.profile_banner_url ? `url("${String(p.profile_banner_url).replace(/["\\]/g, "\\$&")}")` : "none"}`;
            const guildLabel = p.server_name || `Guild ${p.guild_id || "profile"}`;
            const socialLabel = { open: "Open", friends: "Friends Only", quiet: "Quiet" }[String(p.profile_social_mode || "open").toLowerCase()] || "Open";

            const followDisabled = !p.followed_by_me && !perms.can_follow;
            const friendLocked = ["friends", "pending_out", "self"].includes(p.friend_status);
            const friendLabel = p.friend_status === "friends" ? "Friends" : p.friend_status === "pending_out" ? "Pending" : "Friend";

            view.className = `public-profile-shell`;
            view.setAttribute("style", heroStyle);
            view.innerHTML = `
              <section class="panel public-profile-hero public-profile-card-${esc(cardStyle)} public-profile-banner-${esc(bannerMode)} profile-border-${esc(borderAccent)}" style="${heroStyle}">
                ${avatarHtml(p.avatar_url || p.server_icon_url, p.display_name || p.username, p.is_online, "avatar profile-avatar-xl")}
                <div class="public-profile-copy">
                  <h2>${esc(p.profile_headline || p.display_name || p.username || "Unknown")}</h2>
                  <p>${esc(p.bio || p.server_name || guildLabel)}</p>
                  ${p.profile_quote ? `<p class="muted">${esc(p.profile_quote)}</p>` : ""}
                  <div class="chip-row">
                    <span class="presence-pill ${p.is_online ? "online" : "inactive"}"><span class="presence-dot" aria-hidden="true"></span>${p.is_online ? "Online" : "Inactive"}</span>
                    ${tags.map((t) => `<span>${esc(t)}</span>`).join("")}
                    <span>${esc(p.favorite_bot || "swarm")}</span>
                    <span>${esc(guildLabel)}</span>
                  </div>
                </div>
                <div class="public-profile-actions">
                  <button type="button" id="follow-btn" ${followDisabled ? "disabled" : ""}>${p.followed_by_me ? "Unfollow" : "Follow"}</button>
                  <button type="button" id="friend-btn" ${(!perms.can_friend || friendLocked) ? "disabled" : ""}>${esc(friendLabel)}</button>
                  ${perms.can_message ? '<a class="button-link primary" href="/messages">Message</a>' : '<button type="button" disabled>Message Locked</button>'}
                </div>
              </section>
              <section class="profile-dashboard-grid">
                <article class="panel profile-stat-panel"><strong>${p.follower_count || 0}</strong><span>Followers</span></article>
                <article class="panel profile-stat-panel"><strong>${p.following_count || 0}</strong><span>Following</span></article>
                <article class="panel profile-stat-panel"><strong>${p.friend_count || 0}</strong><span>Friends</span></article>
                <article class="panel profile-stat-panel"><strong>${activity.total_plays || 0}</strong><span>Plays</span></article>
              </section>
              <section class="settings-grid profile-social-layout">
                <article class="panel form-panel">
                  <div class="section-head"><h2>Swarm Activity</h2></div>
                  <div class="event-list compact-events">
                    ${(activity.active_sessions || []).slice(0, 4).map((s) => `<article class="event"><strong>${esc(s.title || s.bot_name)}</strong><p>${esc(s.bot_name)} / ${esc(s.channel_name || "voice")}</p></article>`).join("") || '<div class="empty-state">No live sessions</div>'}
                  </div>
                </article>
                <article class="panel form-panel">
                  <div class="section-head"><h2>Links</h2></div>
                  <div class="profile-link-list">
                    ${links.map((l) => `<a href="${esc(l.url)}" target="_blank" rel="noreferrer">${esc(l.label)}</a>`).join("")}
                    ${p.server_invite_url ? `<a href="${esc(p.server_invite_url)}" target="_blank" rel="noreferrer">Discord</a>` : ""}
                    ${!links.length && !p.server_invite_url ? '<div class="empty-state">No links</div>' : ""}
                  </div>
                </article>
              </section>
            `;
            document.getElementById("follow-btn").addEventListener("click", () =>
              swarmFetch("/api/users/" + encodeURIComponent(id) + "/follow", { method: "POST", body: JSON.stringify({ following: !p.followed_by_me }) })
                .then(() => { swarmToast("Done.", "success"); location.reload(); }).catch((e) => swarmToast(e.message, "error")));
            document.getElementById("friend-btn").addEventListener("click", () =>
              swarmFetch("/api/users/" + encodeURIComponent(id) + "/friend-request", { method: "POST" }).then(() => { swarmToast("Request sent.", "success"); location.reload(); }).catch((e) => swarmToast(e.message, "error")));
          } catch (err) { view.innerHTML = '<div class="notice notice-error">Profile not found.</div>'; }
        })();
      ]]
    else
      -- Full field set mirrors pages/ProfilePage.jsx -- the first pass only
      -- had display_name/bio/accent, so headline, tags, up to 5 custom
      -- links, avatar/banner/server-icon URLs, favorite bot, quote, invite
      -- URL, and all 6 visual-style pickers (banner/card/social/layout/
      -- header/border) were unreachable even though profiles.lua already
      -- validated and stored every one of them.
      local link_fields = {}
      for i = 1, 5 do
        link_fields[#link_fields + 1] = ([[
          <div class="two-col">
            <label class="field">Link %d label<input data-link-label="%d" maxlength="32"></label>
            <label class="field">Link %d URL<input data-link-url="%d" placeholder="https://..."></label>
          </div>
        ]]):format(i, i - 1, i, i - 1)
      end
      body = html.page({
        title = "Profile", eyebrow = "Account", lede = "Edit how you appear across the panel.",
        body = ([[
          <section class="profile-dashboard-grid" id="profile-stats"></section>
          <form id="profile-form" class="panel form-panel">
            <h3>Identity</h3>
            <label class="field">Display name<input name="display_name" maxlength="80"></label>
            <label class="field">Headline<input name="profile_headline" maxlength="140"></label>
            <label class="field">Bio<textarea name="bio" rows="3" maxlength="280"></textarea></label>
            <label class="field">Signature / quote<input name="profile_quote" maxlength="160" placeholder="A short motto, quote, or vibe descriptor"></label>
            <label class="field">Tags (comma separated)<input name="profile_tags_text" placeholder="tag1, tag2, tag3"></label>
            <label class="field">Favorite bot<select name="favorite_bot" id="favorite-bot-select"><option value="">None</option></select></label>
            <h3>Links</h3>
            <div class="link-editor">%s</div>
            <h3>Server</h3>
            <label class="field">Server name<input name="server_name" maxlength="120"></label>
            <label class="field">Discord invite<input name="server_invite_url" placeholder="https://discord.gg/..."></label>
            <label class="field">Server icon URL<input name="server_icon_url" placeholder="https://..."></label>
            <h3>Appearance</h3>
            <label class="field">Avatar URL<input name="avatar_url" placeholder="https://..."></label>
            <label class="field">Banner URL<input name="profile_banner_url" placeholder="https://..."></label>
            <label class="field">Accent color<input type="color" name="theme_accent"></label>
            <label class="field">Banner style<select name="profile_banner_mode"><option value="gradient">Gradient</option><option value="image">Image</option><option value="signal">Signal</option><option value="quiet">Quiet</option><option value="contrast">Contrast</option></select></label>
            <label class="field">Card style<select name="profile_card_style"><option value="solid">Solid</option><option value="glass">Glass</option><option value="outline">Outline</option><option value="terminal">Terminal</option></select></label>
            <label class="field">Social visibility<select name="profile_social_mode"><option value="open">Open</option><option value="friends">Friends</option><option value="quiet">Quiet</option></select></label>
            <label class="field">Profile layout<select name="profile_layout_mode"><option value="default">Default</option><option value="sidebar">Sidebar</option><option value="stacked">Stacked</option><option value="split">Split</option></select></label>
            <label class="field">Header style<select name="profile_header_style"><option value="solid">Solid</option><option value="glass">Glass</option><option value="blur">Blur</option><option value="transparent">Transparent</option><option value="gradient">Gradient</option></select></label>
            <label class="field">Border accent<select name="profile_border_accent"><option value="none">None</option><option value="solid">Solid</option><option value="glow">Glow</option><option value="pulse">Pulse</option><option value="neon">Neon</option></select></label>
            <label class="field field-inline"><input type="checkbox" name="public_profile"><span>Public profile</span></label>
            <button type="submit" class="button-link primary">Save</button>
          </form>
          <div id="profile-msg"></div>
          <h3>Account</h3>
          <form id="account-form" class="panel form-panel">
            <label class="field">Email<input type="email" name="email"></label>
            <button type="submit">Update email</button>
          </form>
          <form id="password-form" class="panel form-panel">
            <label class="field">New password<input type="password" name="password" minlength="8"></label>
            <button type="submit">Change password</button>
          </form>
        ]]):format(html.join(link_fields)),
      })
      script = [[
        (async () => {
          try {
            const res = await swarmFetch("/api/users/me");
            const p = res.profile || {};
            const activity = p.activity || {};
            document.getElementById("profile-stats").innerHTML = `
              <article class="panel profile-stat-panel"><strong>${p.follower_count || 0}</strong><span>Followers</span></article>
              <article class="panel profile-stat-panel"><strong>${p.following_count || 0}</strong><span>Following</span></article>
              <article class="panel profile-stat-panel"><strong>${p.friend_count || 0}</strong><span>Friends</span></article>
              <article class="panel profile-stat-panel"><strong>${activity.total_plays || 0}</strong><span>Plays</span></article>
            `;
            const f = document.getElementById("profile-form");
            const fields = ["display_name", "profile_headline", "bio", "profile_quote", "server_name",
              "server_invite_url", "server_icon_url", "avatar_url", "profile_banner_url",
              "profile_banner_mode", "profile_card_style", "profile_social_mode",
              "profile_layout_mode", "profile_header_style", "profile_border_accent", "favorite_bot"];
            for (const key of fields) if (f.elements[key]) f.elements[key].value = p[key] || "";
            f.theme_accent.value = p.theme_accent || "#89b4fa";
            f.public_profile.checked = !!p.public_profile;
            f.profile_tags_text.value = (p.profile_tags || []).join(", ");
            const sel = document.getElementById("favorite-bot-select");
            (res.favorite_bot_options || []).forEach((bot) => {
              const opt = document.createElement("option");
              opt.value = bot.key; opt.textContent = bot.display_name;
              sel.appendChild(opt);
            });
            if (p.favorite_bot) sel.value = p.favorite_bot;
            (p.profile_links || []).forEach((link, i) => {
              const labelEl = f.querySelector(`[data-link-label="${i}"]`);
              const urlEl = f.querySelector(`[data-link-url="${i}"]`);
              if (labelEl) labelEl.value = link.label || "";
              if (urlEl) urlEl.value = link.url || "";
            });
          } catch { /* ignore */ }
        })();
        document.getElementById("profile-form").addEventListener("submit", async (e) => {
          e.preventDefault();
          const f = e.target;
          const fd = new FormData(f);
          const payload = Object.fromEntries(fd);
          payload.public_profile = f.public_profile.checked;
          payload.profile_tags = (payload.profile_tags_text || "").split(",").map((t) => t.trim()).filter(Boolean);
          delete payload.profile_tags_text;
          const links = [];
          for (let i = 0; i < 5; i++) {
            const label = f.querySelector(`[data-link-label="${i}"]`).value.trim();
            const url = f.querySelector(`[data-link-url="${i}"]`).value.trim();
            if (label && url) links.push({ label, url });
          }
          payload.profile_links = links;
          try {
            await swarmFetch("/api/users/me", { method: "POST", body: JSON.stringify(payload) });
            document.getElementById("profile-msg").innerHTML = '<div class="notice notice-success">Saved.</div>';
          } catch (err) { document.getElementById("profile-msg").innerHTML = '<div class="notice notice-error">' + err.message + "</div>"; }
        });
        document.getElementById("account-form").addEventListener("submit", async (e) => {
          e.preventDefault();
          const fd = new FormData(e.target);
          try {
            await swarmFetch("/api/session/email", { method: "POST", body: JSON.stringify(Object.fromEntries(fd)) });
            swarmToast("Email updated.", "success");
          } catch (err) { swarmToast(err.message, "error"); }
        });
        document.getElementById("password-form").addEventListener("submit", async (e) => {
          e.preventDefault();
          const fd = new FormData(e.target);
          try {
            await swarmFetch("/api/session/password", { method: "POST", body: JSON.stringify(Object.fromEntries(fd)) });
            swarmToast("Password changed.", "success");
            e.target.reset();
          } catch (err) { swarmToast(err.message, "error"); }
        });
      ]]
    end
    return page_shell(req, a, is_public and ("/users/" .. tostring(target_id)) or "/profile", "Profile", body, script)
  end
  httpd.route("GET", "/profile", function(req) return render_profile(req, false) end)
  httpd.route("GET", "/users/:id", function(req) return render_profile(req, true) end)

  -- -----------------------------------------------------------------
  -- Appearance
  -- -----------------------------------------------------------------
  httpd.route("GET", "/appearance", function(req)
    local a, status, headers = cfg.require_auth_page(req)
    if not a then return status, "", headers end
    local function select_field(name, label, options)
      local opts = {}
      for _, o in ipairs(options) do opts[#opts + 1] = ("<option value=\"%s\">%s</option>"):format(o, o) end
      return ('<label class="field">%s<select name="%s">%s</select></label>'):format(html.esc(label), name, html.join(opts))
    end
    local function text_field(name, label, placeholder)
      return ('<label class="field">%s<input type="text" name="%s" placeholder="%s"></label>'):format(
        html.esc(label), name, html.esc(placeholder or ""))
    end
    local function range_field(name, label, min, max, step)
      return ('<label class="field">%s<input type="range" name="%s" min="%s" max="%s" step="%s"></label>'):format(
        html.esc(label), name, min, max, step)
    end
    local function check_field(name, label)
      return ('<label class="field field-inline"><input type="checkbox" name="%s"><span>%s</span></label>'):format(name, html.esc(label))
    end
    -- Full field set mirrors frontend/src/config.js's DEFAULT_PREFERENCES --
    -- the first Lua-rendered pass only had 8 of these ~23 fields, so most
    -- of the panel's per-user look customization was simply unreachable
    -- even though the backend (profiles.lua/routes.lua) already accepted
    -- and stored all of them.
    local body = html.page({
      title = "Appearance", eyebrow = "Look", lede = "Customize theme, layout, and motion.",
      body = ([[
        <div class="appearance-header-row">
          <div class="appearance-status-row">
            <span class="appearance-draft-pill clean" id="appearance-draft-pill">Saved</span>
          </div>
        </div>
        <div class="dashboard-grid appearance-layout">
        <form id="appearance-form" class="panel form-panel appearance-form">
          <h3>Theme</h3>
          %s%s
          <label class="field">Accent color<input type="color" name="accent_color"></label>
          <label class="field">Accent secondary (optional)<input type="color" name="accent_secondary"></label>
          %s
          <h3>Background</h3>
          %s
          <label class="field">Background color (custom_color mode)<input type="color" name="background_color"></label>
          %s
          <h3>Layout</h3>
          %s%s%s%s%s%s%s%s
          <h3>Cards &amp; motion</h3>
          %s%s%s%s
          %s%s
          <h3>Profile backdrop</h3>
          %s
          %s
          <h3>Misc</h3>
          %s%s%s
          <div class="appearance-form-actions">
            <button type="submit" class="button-link primary">Save</button>
            <button type="button" id="appearance-reset" class="button-link">Reset to defaults</button>
          </div>
        </form>
        <div class="panel appearance-preview">
          <div class="appearance-preview-shell">
            <div class="preview-topline"><span></span><strong>Live Preview</strong></div>
            <div class="appearance-preview-hero">
              <div class="preview-tabs"><span>Dashboard</span><span>Controls</span><span>Users</span></div>
              <h3>SwarmPanel</h3>
              <div class="appearance-preview-meta">
                <span class="appearance-value-pill" id="preview-theme-pill">Dark</span>
                <span class="appearance-value-pill" id="preview-density-pill">Comfortable</span>
              </div>
            </div>
            <div class="appearance-preview-shell-panel">
              <div class="appearance-preview-shell-topbar"><span>Fleet Command</span><span class="data-pill data-pill-live">Live</span></div>
              <div class="preview-card">
                <strong>Sample Bot Card</strong>
                <span>This is roughly how cards and accents will look with your current draft settings.</span>
              </div>
            </div>
            <p class="appearance-preview-note">Updates live as you edit below. Nothing is applied anywhere else until you hit Save.</p>
          </div>
        </div>
        </div>
        <div id="appearance-msg"></div>
      ]]):format(
        select_field("theme_mode", "Theme", { "dark", "light", "system" }),
        select_field("font_scale", "Font scale", { "normal", "large", "dense" }),
        select_field("panel_font_family", "Panel font", { "system", "serif", "mono", "rounded" }),
        select_field("background_mode", "Background", { "default", "midnight", "aurora", "ember", "custom_color", "custom_image" }),
        text_field("background_image_url", "Background image URL (custom_image mode)", "https://..."),
        select_field("layout_mode", "Layout", { "standard", "focused", "wide" }),
        select_field("density", "Density", { "comfortable", "compact" }),
        select_field("operator_layout", "Profile layout", { "command", "console", "compact" }),
        select_field("roster_layout", "Directory layout", { "cards", "signals", "ledger" }),
        select_field("tab_style", "Tabs", { "rail", "underline", "minimal" }),
        select_field("dashboard_density", "Dashboard density", { "command", "dense" }),
        select_field("sidebar_style", "Sidebar", { "full", "compact", "hidden" }),
        select_field("notification_position", "Toast position", { "br", "bl", "tr", "tc" }),
        select_field("card_shape", "Card shape", { "soft", "crisp" }),
        select_field("card_hover_effect", "Hover effect", { "lift", "glow", "border", "none" }),
        select_field("stream_card_style", "Bot card style", { "telemetry", "compact", "cinematic" }),
        select_field("bot_card_detail", "Bot card detail", { "full", "compact" }),
        select_field("motion", "Motion", { "standard", "reduced" }),
        select_field("panel_radius", "Corner radius", { "sharp", "medium", "soft" }),
        range_field("surface_opacity", "Surface opacity", "0.5", "1", "0.01"),
        range_field("surface_blur", "Surface blur (px)", "0", "32", "1"),
        text_field("profile_backdrop_image_url", "Profile backdrop image URL", "https://..."),
        range_field("profile_backdrop_strength", "Backdrop strength", "0", "0.55", "0.01"),
        check_field("show_bot_uptime", "Show bot uptime"),
        check_field("show_queue_pressure", "Show queue pressure"),
        check_field("compact_sidebar", "Compact sidebar")),
    })
    local script = [[
      const DEFAULT_PREFS = {
        theme_mode: "dark", accent_color: "#89b4fa", accent_secondary: "", background_mode: "default",
        background_color: "#0b0e18", background_image_url: "", layout_mode: "standard", density: "comfortable",
        card_shape: "soft", font_scale: "normal", motion: "standard", operator_layout: "command",
        roster_layout: "cards", tab_style: "rail", surface_opacity: 0.92, surface_blur: 18,
        stream_card_style: "telemetry", dashboard_density: "command", profile_backdrop_image_url: "",
        profile_backdrop_strength: 0.18, sidebar_style: "full", panel_font_family: "system",
        card_hover_effect: "lift", notification_position: "br", bot_card_detail: "full", panel_radius: "medium",
        show_bot_uptime: true, show_queue_pressure: true, compact_sidebar: false,
      };
      function applyPrefs(p) {
        const f = document.getElementById("appearance-form");
        for (const key of Object.keys(DEFAULT_PREFS)) {
          const el = f.elements[key];
          if (!el) continue;
          const value = (p[key] !== undefined && p[key] !== null && p[key] !== "") ? p[key] : DEFAULT_PREFS[key];
          if (el.type === "checkbox") el.checked = !!value && value !== "false";
          else el.value = value;
        }
      }
      (async () => {
        try {
          const res = await swarmFetch("/api/users/preferences");
          applyPrefs(res.preferences || {});
        } catch { applyPrefs({}); }
        updatePreview();
      })();
      document.getElementById("appearance-reset").addEventListener("click", () => { applyPrefs({}); updatePreview(); markDirty(); });
      const draftPill = document.getElementById("appearance-draft-pill");
      function markDirty() {
        draftPill.textContent = "Unsaved changes";
        draftPill.className = "appearance-draft-pill dirty";
      }
      function markClean() {
        draftPill.textContent = "Saved";
        draftPill.className = "appearance-draft-pill clean";
      }
      // Live preview: reads the CURRENT (possibly unsaved) form state so an
      // operator sees roughly how their draft looks before committing to
      // Save -- appearance-preview-* had full CSS with no consumer.
      function updatePreview() {
        const f = document.getElementById("appearance-form");
        const shell = document.querySelector(".appearance-preview-shell");
        const accent = f.elements.accent_color ? f.elements.accent_color.value : "#89b4fa";
        if (shell) shell.style.setProperty("--accent", accent);
        const themeMode = f.elements.theme_mode ? f.elements.theme_mode.value : "dark";
        document.getElementById("preview-theme-pill").textContent = themeMode.charAt(0).toUpperCase() + themeMode.slice(1);
        const density = f.elements.density ? f.elements.density.value : "comfortable";
        document.getElementById("preview-density-pill").textContent = density.charAt(0).toUpperCase() + density.slice(1);
      }
      document.getElementById("appearance-form").addEventListener("input", () => { markDirty(); updatePreview(); });
      document.getElementById("appearance-form").addEventListener("submit", async (e) => {
        e.preventDefault();
        const f = e.target;
        const payload = {};
        for (const key of Object.keys(DEFAULT_PREFS)) {
          if (!f.elements[key]) continue;
          payload[key] = f.elements[key].type === "checkbox" ? f.elements[key].checked : f.elements[key].value;
        }
        try {
          await swarmFetch("/api/users/preferences", { method: "POST", body: JSON.stringify(payload) });
          markClean();
          document.getElementById("appearance-msg").innerHTML = '<div class="notice notice-success">Saved. Reloading...</div>';
          setTimeout(() => window.location.reload(), 600);
        } catch (err) { document.getElementById("appearance-msg").innerHTML = '<div class="notice notice-error">' + err.message + "</div>"; }
      });
      updatePreview();
    ]]
    return page_shell(req, a, "/appearance", "Appearance", body, script)
  end)

  -- -----------------------------------------------------------------
  -- Diagnostics (admin)
  -- -----------------------------------------------------------------
  httpd.route("GET", "/diagnostics", function(req)
    local a, status, headers = cfg.require_auth_page(req)
    if not a then return status, "", headers end
    if not a.admin_mode then
      return 200, html.layout({ title = "Diagnostics", path = "/diagnostics", session = session_view(a),
        body = html.page({ title = "Diagnostics", body = html.notice("error", "Admin access required.") }) }),
        { ["Content-Type"] = "text/html; charset=utf-8" }
    end
    local body = html.page({
      title = "Diagnostics", eyebrow = "System", lede = "Stability, metrics, alert rules, and exports.",
      actions = '<button type="button" id="diag-refresh" class="button-link">Refresh Now</button>',
      body = [[
        <div id="diag-stability"></div>
        <div id="diag-metrics"></div>
        <h3>Alert Rules</h3>
        <form id="alert-rule-form" class="panel form-panel">
          <label class="field">Rule type<select name="rule_type" required>
            <option value="bot_offline">Bot offline</option>
            <option value="queue_stuck">Queue stuck</option>
            <option value="stale_metrics">Stale metrics</option>
            <option value="recovery_pending">Recovery pending</option>
          </select></label>
          <label class="field">Threshold (minutes)<input type="number" name="threshold_minutes" min="1" max="1440" value="5" required></label>
          <label class="field">Escalation (minutes, optional)<input type="number" name="escalation_minutes" min="1" max="10080"></label>
          <label class="switch"><input type="checkbox" name="enabled" checked> Enabled</label>
          <label class="switch"><input type="checkbox" name="escalate_email"> Escalate via email</label>
          <button type="submit" class="button-link primary">Add Rule</button>
        </form>
        <div id="diag-alerts"></div>
        <h3>Exports</h3>
        <div id="diag-exports"></div>
      ]],
    })
    local script = [[
      async function loadDiagnostics() {
        try {
          const stability = await swarmFetch("/api/stability");
          document.getElementById("diag-stability").innerHTML = '<pre class="json-panel">' + JSON.stringify(stability, null, 2).replace(/</g, "&lt;") + "</pre>";
        } catch { /* ignore */ }
        try {
          const metrics = await swarmFetch("/api/metrics");
          document.getElementById("diag-metrics").innerHTML = '<pre class="json-panel">' + JSON.stringify(metrics, null, 2).replace(/</g, "&lt;") + "</pre>";
        } catch { /* ignore */ }
      }
      async function loadAlerts() {
        try {
          const res = await swarmFetch("/api/alert-rules");
          document.getElementById("diag-alerts").innerHTML = (res.rules || []).map((r) => `
            <div class="alert-rule">
              <span><strong>${r.rule_type}</strong> — ${r.threshold_minutes}m${r.escalation_minutes ? `, escalate after ${r.escalation_minutes}m` : ""}${r.escalate_email ? " (email)" : ""}</span>
              <label class="switch"><input type="checkbox" data-toggle-rule="${r.id}" ${r.enabled ? "checked" : ""}> Enabled</label>
              <button type="button" data-delete-rule="${r.id}">Delete</button>
            </div>`).join("") || "<p>No alert rules.</p>";
        } catch { /* ignore */ }
      }
      async function loadExports() {
        try {
          const res = await swarmFetch("/api/exports");
          const rows = (res.snapshots || []).flatMap((snap) => (snap.files || []).map((f) =>
            `<div><a href="/api/exports/${snap.date}/${f.name}">${snap.date}/${f.name}</a> (${f.size_bytes}b)</div>`));
          document.getElementById("diag-exports").innerHTML = rows.join("") || "<p>No exports.</p>";
        } catch { /* ignore */ }
      }
      const alertForm = document.getElementById("alert-rule-form");
      alertForm.addEventListener("submit", async (e) => {
        e.preventDefault();
        const fd = new FormData(alertForm);
        try {
          await swarmFetch("/api/alert-rules", {
            method: "POST",
            body: JSON.stringify({
              rule_type: fd.get("rule_type"),
              threshold_minutes: Number(fd.get("threshold_minutes")),
              enabled: fd.get("enabled") === "on",
              escalation_minutes: fd.get("escalation_minutes") ? Number(fd.get("escalation_minutes")) : null,
              escalate_email: fd.get("escalate_email") === "on",
            }),
          });
          swarmToast("Alert rule created.", "success");
          alertForm.reset();
          loadAlerts();
        } catch (err) { swarmToast(err.message, "error"); }
      });
      document.getElementById("diag-alerts").addEventListener("click", async (e) => {
        const id = e.target.getAttribute("data-delete-rule");
        if (id) { await swarmFetch(`/api/alert-rules/${id}/delete`, { method: "POST" }).catch(() => {}); loadAlerts(); }
      });
      document.getElementById("diag-alerts").addEventListener("change", async (e) => {
        const id = e.target.getAttribute("data-toggle-rule");
        if (!id) return;
        try {
          await swarmFetch(`/api/alert-rules/${id}/update`, { method: "POST", body: JSON.stringify({ enabled: e.target.checked }) });
        } catch (err) { swarmToast(err.message, "error"); e.target.checked = !e.target.checked; }
      });
      swarmLiveRefresh(loadDiagnostics, 5000);
      swarmLiveRefresh(loadAlerts, 30000);
      swarmLiveRefresh(loadExports, 60000);
      document.getElementById("diag-refresh").addEventListener("click", () => {
        loadDiagnostics(); loadAlerts(); loadExports();
        swarmToast("Refreshed.", "success");
      });
    ]]
    return page_shell(req, a, "/diagnostics", "Diagnostics", body, script)
  end)
end

return M
