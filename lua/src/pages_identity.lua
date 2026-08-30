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
      guild_id = a.guild_id,
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
    -- BUGFIX: same class of bug as /friends (see that route's comment) --
    -- messages are guild-account-scoped (account_id_for_auth in routes.lua
    -- requires a.guild_id), so the bare env-configured admin login can
    -- never load a thread list/search here either. Same fix: a clear
    -- explanation instead of a page that's guaranteed to error forever.
    if not a.guild_id then
      local body = html.page({
        title = "Messages", eyebrow = "Inbox", lede = "Direct messages with other operators.",
        body = [[
          <div class="empty-state">
            <p>Messages are tied to a guild account, not the site admin login.</p>
            <p>Log in with a guild account (one registered to a specific bot/guild) to use Messages.</p>
          </div>
        ]],
      })
      return page_shell(req, a, "/messages", "Messages", body, "")
    end
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
      // BUGFIX (live-push migration): was swarmFetch on 5s/4s
      // swarmLiveRefresh polls. Threads list watches "threads" (fixed, no
      // params, matches Social's Messages tab). The active conversation is
      // per-CONNECTION state (routes.lua's "thread_messages" builder takes
      // account_id as a watch param) -- resubscribed every time a different
      // thread is opened, same pattern as Controls' bot_key/guild_id.
      let activeThread = null;
      function applyThreads(data) {
        document.getElementById("msg-threads").innerHTML = ((data && data.threads) || []).map((t) =>
          `<button type="button" class="thread-item" data-thread="${t.account_id}">${(t.username||"Unknown").replace(/</g,"&lt;")}</button>`
        ).join("") || "<p>No conversations yet.</p>";
      }
      window.swarmLive.watch("threads", (msg) => { if (msg.type === "snapshot") applyThreads(msg.data); });

      function applyMessages(data) {
        document.getElementById("msg-list").innerHTML = ((data && data.messages) || []).map((m) =>
          `<div class="msg-bubble ${m.mine ? "mine" : ""}">${(m.body||"").replace(/</g,"&lt;")}</div>`).join("");
      }
      window.swarmLive.watch("thread_messages", (msg) => { if (msg.type === "snapshot") applyMessages(msg.data); });

      async function openThread(id) {
        activeThread = id;
        const box = document.getElementById("msg-conversation");
        box.innerHTML = '<div id="msg-list"></div><form id="msg-form"><input name="body" placeholder="Message..." required><button type="submit">Send</button></form>';
        window.swarmLive.resubscribe("thread_messages", { account_id: id });
        try { applyMessages(await swarmFetch(`/api/messages/${id}`)); } catch { /* ignore -- the live watch will catch up */ }
        document.getElementById("msg-form").addEventListener("submit", async (e) => {
          e.preventDefault();
          const input = e.target.body;
          if (!input.value.trim()) return;
          try {
            await swarmFetch(`/api/messages/${activeThread}`, { method: "POST", body: JSON.stringify({ body: input.value }) });
            input.value = "";
            applyMessages(await swarmFetch(`/api/messages/${activeThread}`));
          } catch (err) { swarmToast(err.message, "error"); }
        });
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
            // BUGFIX: profile_header_style/profile_layout_mode were validated
            // and stored (profiles.lua, every looks.lua preset sets one of
            // these) but had NO CSS anywhere -- picking Glass/Blur/
            // Transparent/Gradient or Sidebar/Stacked/Split changed nothing.
            // See the .profile-header-*/.profile-layout-* rules added to
            // app.css.
            //
            // profile_backdrop_image_url/strength are NOT wired here:
            // despite the field living in "Profile backdrop" on /appearance,
            // it's stored in the VIEWER's own panel_preferences, not on any
            // individual profile -- /api/users/:id/profile (this endpoint)
            // doesn't and shouldn't return it. --profile-backdrop/
            // --profile-backdrop-strength are set once at the .app-shell
            // root (html.lua's panel_style()) from the logged-in viewer's
            // own preferences and inherit down into .public-profile-hero
            // automatically; setting them again here from profile data that
            // doesn't exist would just shadow that inherited value with
            // "none" for every profile page, silently breaking it.
            const HEADER_STYLES = new Set(["solid", "glass", "blur", "transparent", "gradient"]);
            const LAYOUT_MODES = new Set(["default", "sidebar", "stacked", "split"]);
            const headerStyle = HEADER_STYLES.has(p.profile_header_style) ? p.profile_header_style : "solid";
            const layoutMode = LAYOUT_MODES.has(p.profile_layout_mode) ? p.profile_layout_mode : "default";
            const heroStyle = `--accent:${accent};--profile-banner-url:${p.profile_banner_url ? `url("${String(p.profile_banner_url).replace(/["\\]/g, "\\$&")}")` : "none"}`;
            const guildLabel = p.server_name || `Guild ${p.guild_id || "profile"}`;
            const socialLabel = { open: "Open", friends: "Friends Only", quiet: "Quiet" }[String(p.profile_social_mode || "open").toLowerCase()] || "Open";

            const followDisabled = !p.followed_by_me && !perms.can_follow;
            const friendLocked = ["friends", "pending_out", "self"].includes(p.friend_status);
            const friendLabel = p.friend_status === "friends" ? "Friends" : p.friend_status === "pending_out" ? "Pending" : "Friend";

            view.className = `public-profile-shell profile-layout-${layoutMode}`;
            view.setAttribute("style", heroStyle);
            view.innerHTML = `
              <section class="panel public-profile-hero public-profile-card-${esc(cardStyle)} public-profile-banner-${esc(bannerMode)} profile-border-${esc(borderAccent)} profile-header-${esc(headerStyle)}" style="${heroStyle}">
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
                    <span>${esc(socialLabel)}</span>
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
          <div class="dashboard-grid profile-workbench operator-layout-command">
          <div class="profile-editor">
          <form id="profile-form" class="panel form-panel">
            <div class="appearance-cluster">
              <div class="appearance-cluster-head">
                <h3>Quick Looks</h3>
                <p>Apply a full profile look in one tap, then fine-tune anything below.</p>
              </div>
              <div class="appearance-preset-grid" id="profile-preset-grid"></div>
            </div>
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
          </div>
          <div class="profile-account-panel">
            <div class="panel public-profile-preview public-profile-preview-card" id="profile-preview-panel">
              <p class="page-lede">Live Preview</p>
              <section class="public-profile-hero" id="profile-live-preview">
                <div class="avatar profile-avatar-xl avatar-presence" id="preview-avatar-wrap">
                  <span class="avatar-fallback" id="preview-avatar-fallback">SP</span>
                  <span class="presence-dot avatar-dot online" aria-hidden="true"></span>
                </div>
                <div class="public-profile-copy">
                  <strong id="preview-display-name">—</strong>
                  <p id="preview-headline"></p>
                  <p id="preview-bio" class="muted"></p>
                  <p id="preview-quote" class="muted"></p>
                  <div class="chip-row" id="preview-tags"></div>
                  <div class="chip-row" id="preview-meta"></div>
                </div>
              </section>
            </div>
            <h3>Getting Started</h3>
            <div class="panel form-panel" id="profile-checklist"></div>
            <h3>Account</h3>
            <form id="account-form" class="panel form-panel">
              <label class="field">Email<input type="email" name="email"></label>
              <button type="submit">Update email</button>
            </form>
            <form id="password-form" class="panel form-panel">
              <label class="field">New password<input type="password" name="password" minlength="8"></label>
              <button type="submit">Change password</button>
            </form>
            <h3>Verification</h3>
            <div class="panel form-panel" id="verification-panel">
              <div id="verification-status"></div>
              <div class="segmented" role="tablist">
                <button type="button" class="active" data-verify-mode="webhook">Server Webhook</button>
                <button type="button" data-verify-mode="discord">Discord DM</button>
              </div>
              <form id="verify-webhook-form" data-verify-webhook>
                <label class="field">Discord Verification Webhook<input type="text" name="verification_webhook_url" placeholder="https://discord.com/api/webhooks/..."></label>
                <button type="submit">Save &amp; Send Code</button>
              </form>
              <form id="verify-discord-form" data-verify-discord hidden>
                <label class="field">Your Discord User ID<input type="text" name="discord_user_id" placeholder="1234567890123456"></label>
                <button type="submit">Save &amp; Send Code</button>
              </form>
              <form id="verify-code-form">
                <label class="field">Verification code<input type="text" name="code" inputmode="numeric" placeholder="123456"></label>
                <button type="submit">Verify</button>
                <button type="button" id="verify-resend">Resend Code</button>
              </form>
            </div>
          </div>
          </div>
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
            updateProfilePreview();
            renderVerificationStatus(p);
            renderProfileChecklist(p);
          } catch { /* ignore */ }
        })();
        // Quick Looks: looks.lua's PROFILE_LOOKS (server-owned profile
        // style bundles, same /api/appearance/presets response that
        // Appearance's Quick Presets now reads its "panel" half from) had
        // no consumer at all for its "profile" half until this.
        (async () => {
          try {
            const res = await swarmFetch("/api/appearance/presets");
            const grid = document.getElementById("profile-preset-grid");
            (res.profile || []).forEach((preset) => {
              const card = document.createElement("button");
              card.type = "button";
              card.className = "appearance-preset-card";
              card.setAttribute("data-profile-preset", JSON.stringify(preset.patch));
              card.innerHTML = `<strong>${preset.title.replace(/</g, "&lt;")}</strong><span>${(preset.note || "").replace(/</g, "&lt;")}</span>`;
              grid.appendChild(card);
            });
          } catch { /* Quick Looks are additive -- the rest of the form still works without them */ }
        })();
        document.getElementById("profile-form").addEventListener("click", (e) => {
          const btn = e.target.closest("[data-profile-preset]");
          if (!btn) return;
          const patch = JSON.parse(btn.getAttribute("data-profile-preset"));
          const f = document.getElementById("profile-form");
          for (const [key, value] of Object.entries(patch)) {
            if (f.elements[key]) f.elements[key].value = value;
          }
          updateProfilePreview();
          swarmToast("Look applied -- Save to keep it.", "success");
        });
        // Verification panel: both /api/session/verification-webhook and the
        // newer /api/session/verification-discord (straight-DM alternative)
        // had zero UI reaching them before this -- registration was the
        // only place a webhook could ever be entered, and there was no way
        // at all to add/change a verification method or enter a code after
        // registering.
        function renderVerificationStatus(p) {
          const box = document.getElementById("verification-status");
          if (p.verification_verified) {
            box.innerHTML = '<div class="notice notice-success">Verified.</div>';
          } else if (p.verification_pending) {
            box.innerHTML = '<div class="notice">Verification pending -- enter the code you received below.</div>';
          } else {
            box.innerHTML = '<div class="notice">Not verified yet.</div>';
          }
          const wf = document.getElementById("verify-webhook-form");
          if (wf.elements.verification_webhook_url) wf.elements.verification_webhook_url.value = p.verification_webhook_url || "";
          const df = document.getElementById("verify-discord-form");
          if (df.elements.discord_user_id) df.elements.discord_user_id.value = p.discord_user_id || "";
        }
        // check-row had CSS (a compact labeled-checkbox row) but nothing
        // ever rendered it -- a quick-glance setup checklist for a new
        // account, read-only checkboxes reflecting real profile state.
        function renderProfileChecklist(p) {
          const items = [
            ["Account verified", !!p.verification_verified],
            ["Display name set", !!(p.display_name && p.display_name !== p.username)],
            ["Avatar set", !!p.avatar_url],
            ["Bio written", !!p.bio],
            ["Profile is public", !!p.public_profile],
          ];
          document.getElementById("profile-checklist").innerHTML = items.map(([label, done]) => `
            <label class="check-row"><input type="checkbox" disabled ${done ? "checked" : ""}><span>${label}</span></label>
          `).join("");
        }
        document.querySelectorAll("[data-verify-mode]").forEach((btn) => {
          btn.addEventListener("click", () => {
            document.querySelectorAll("[data-verify-mode]").forEach((b) => b.classList.toggle("active", b === btn));
            const mode = btn.getAttribute("data-verify-mode");
            document.querySelector("[data-verify-webhook]").hidden = mode !== "webhook";
            document.querySelector("[data-verify-discord]").hidden = mode !== "discord";
          });
        });
        document.getElementById("verify-webhook-form").addEventListener("submit", async (e) => {
          e.preventDefault();
          const url = e.target.elements.verification_webhook_url.value.trim();
          try {
            const res = await swarmFetch("/api/session/verification-webhook", { method: "POST", body: JSON.stringify({ verification_webhook_url: url }) });
            swarmToast(res.verification_sent ? "Code sent to your webhook." : "Saved.", "success");
            renderVerificationStatus(res.profile || {});
          } catch (err) { swarmToast(err.message, "error"); }
        });
        document.getElementById("verify-discord-form").addEventListener("submit", async (e) => {
          e.preventDefault();
          const id = e.target.elements.discord_user_id.value.trim();
          try {
            const res = await swarmFetch("/api/session/verification-discord", { method: "POST", body: JSON.stringify({ discord_user_id: id }) });
            swarmToast(res.verification_sent ? "Code sent via Discord DM." : "Saved.", "success");
            renderVerificationStatus(res.profile || {});
          } catch (err) { swarmToast(err.message, "error"); }
        });
        document.getElementById("verify-code-form").addEventListener("submit", async (e) => {
          e.preventDefault();
          const code = e.target.elements.code.value.trim();
          try {
            const res = await swarmFetch("/api/session/verification/verify", { method: "POST", body: JSON.stringify({ code }) });
            swarmToast("Verified.", "success");
            renderVerificationStatus(res.profile || {});
          } catch (err) { swarmToast(err.message, "error"); }
        });
        document.getElementById("verify-resend").addEventListener("click", async () => {
          try {
            const res = await swarmFetch("/api/session/resend-verification", { method: "POST" });
            swarmToast(res.already_verified ? "Already verified." : (res.verification_sent ? "Code resent." : "Could not resend."), res.verification_sent || res.already_verified ? "success" : "error");
          } catch (err) { swarmToast(err.message, "error"); }
        });
        // Live preview -- public-profile-preview/-preview-card had CSS but no
        // consumer. Reads the CURRENT (unsaved) form state, same pattern as
        // Appearance's draft preview, so the operator sees roughly how the
        // public profile will read before committing to Save. Uses the exact
        // same class scheme (public-profile-card-*/public-profile-banner-*/
        // profile-border-*) the real /users/:id public view renders (see
        // render_profile's script above), so every visual-style field --
        // banner mode, card style, border accent -- actually shows a change
        // here instead of only the 3 fields (accent/name/bio) this covered
        // before.
        const BORDER_ACCENTS = new Set(["none", "glow", "pulse", "neon", "solid"]);
        const HEADER_STYLES = new Set(["solid", "glass", "blur", "transparent", "gradient"]);
        function initialsFor(label) {
          const parts = String(label || "").trim().split(/\s+/).filter(Boolean);
          if (!parts.length) return "SP";
          return (parts[0][0] + (parts[1] ? parts[1][0] : "")).toUpperCase();
        }
        function updateProfilePreview() {
          const f = document.getElementById("profile-form");
          if (!f) return;
          const accent = f.theme_accent.value || "#89b4fa";
          const bannerMode = f.profile_banner_mode.value || "gradient";
          const cardStyle = f.profile_card_style.value || "solid";
          const borderAccent = BORDER_ACCENTS.has(f.profile_border_accent.value) ? f.profile_border_accent.value : "none";
          const headerStyle = HEADER_STYLES.has(f.profile_header_style.value) ? f.profile_header_style.value : "solid";
          const bannerUrl = f.profile_banner_url.value.trim();
          const hero = document.getElementById("profile-live-preview");
          hero.className = `public-profile-hero public-profile-card-${cardStyle} public-profile-banner-${bannerMode} profile-border-${borderAccent} profile-header-${headerStyle}`;
          hero.style.setProperty("--accent", accent);
          hero.style.setProperty("--profile-banner-url", bannerUrl ? `url("${bannerUrl.replace(/["\\]/g, "\\$&")}")` : "none");
          // --profile-backdrop/--profile-backdrop-strength intentionally NOT
          // set here: that's the VIEWER's own preference (edited on
          // /appearance, not this form) inherited from the .app-shell root
          // -- this preview naturally shows it already, same as any other
          // profile card would for whoever's logged in.
          document.getElementById("profile-preview-panel").style.setProperty("--accent", accent);
          const avatarUrl = f.avatar_url.value.trim();
          const avatarWrap = document.getElementById("preview-avatar-wrap");
          const label = f.display_name.value || "Unnamed Operator";
          if (avatarUrl) {
            avatarWrap.innerHTML = `<img class="avatar-image" src="${avatarUrl.replace(/"/g, "&quot;")}" alt=""><span class="presence-dot avatar-dot online" aria-hidden="true"></span>`;
          } else {
            avatarWrap.innerHTML = `<span class="avatar-fallback">${initialsFor(label)}</span><span class="presence-dot avatar-dot online" aria-hidden="true"></span>`;
          }
          document.getElementById("preview-display-name").textContent = label;
          document.getElementById("preview-headline").textContent = f.profile_headline.value || "";
          document.getElementById("preview-bio").textContent = f.bio.value || "No bio yet.";
          document.getElementById("preview-quote").textContent = f.profile_quote.value || "";
          const tags = (f.profile_tags_text.value || "").split(",").map((t) => t.trim()).filter(Boolean).slice(0, 5);
          const favBot = document.getElementById("favorite-bot-select");
          const favLabel = favBot && favBot.selectedOptions[0] && favBot.value ? favBot.selectedOptions[0].textContent : "";
          document.getElementById("preview-tags").innerHTML = tags.map((t) => `<span>${t.replace(/</g, "&lt;")}</span>`).join("")
            + (favLabel ? `<span>${favLabel.replace(/</g, "&lt;")}</span>` : "");
          // profile_social_mode/public_profile/server_name aren't visual
          // styles (they gate what OTHER accounts can see/do, or affect the
          // full public page rather than this hero mockup), but they were
          // previously invisible anywhere in the editor -- shown here as
          // plain status chips so changing them isn't a total black box.
          const socialLabel = { open: "Open", friends: "Friends Only", quiet: "Quiet" }[f.profile_social_mode.value] || "Open";
          const visibilityLabel = f.public_profile.checked ? "Public profile" : "Private profile";
          const serverName = f.server_name.value.trim();
          document.getElementById("preview-meta").innerHTML = [socialLabel, visibilityLabel, serverName]
            .filter(Boolean).map((t) => `<span>${t.replace(/</g, "&lt;")}</span>`).join("");
        }
        document.getElementById("profile-form").addEventListener("input", updateProfilePreview);
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
    -- Admin mode already had a toggle in the topbar (data-admin-toggle,
    -- html.lua's layout()) -- this is a second entry point to the exact
    -- same /api/session/admin-mode call for operators who look for it in
    -- Settings instead, not a new permission surface. Still site-owner-only
    -- server-side (routes.lua's is_site_owner check) regardless of what
    -- renders here.
    local admin_toggle_section = a.site_owner and ([[
      <div class="appearance-cluster">
        <div class="appearance-cluster-head">
          <h3>Admin Mode</h3>
          <p>Switch between your normal guild-scoped view and the unrestricted admin view.</p>
        </div>
        <label class="field field-inline">
          <span>Admin mode</span>
          <input type="checkbox" id="settings-admin-mode-toggle" %s>
        </label>
      </div>
    ]]):format(a.admin_mode and "checked" or "") or ""

    local body = html.page({
      title = "Appearance", eyebrow = "Look", lede = "Customize theme, layout, and motion.",
      body = ([[
        <div class="appearance-header-row">
          <div class="appearance-status-row">
            <span class="appearance-draft-pill clean" id="appearance-draft-pill">Saved</span>
          </div>
        </div>
        %s
        <div class="dashboard-grid appearance-layout">
        <form id="appearance-form" class="panel form-panel appearance-form">
          <div class="appearance-cluster">
            <div class="appearance-cluster-head">
              <h3>Quick Presets</h3>
              <p>Apply a full look in one tap, then fine-tune anything below.</p>
            </div>
            <div class="appearance-preset-grid">
              <button type="button" class="appearance-preset-card" data-preset="midnight_ops">
                <strong>Midnight Ops</strong>
                <span>Deep blue-black, cool accent, soft cards.</span>
              </button>
              <button type="button" class="appearance-preset-card" data-preset="aurora_glass">
                <strong>Aurora Glass</strong>
                <span>Aurora backdrop, green accent, glow hover.</span>
              </button>
              <button type="button" class="appearance-preset-card" data-preset="ember_signal">
                <strong>Ember Signal</strong>
                <span>Warm ember backdrop, red accent, crisp cards.</span>
              </button>
            </div>
            <div class="appearance-preset-grid" id="server-preset-grid"></div>
          </div>
          <h3>Theme</h3>
          %s%s
          <div class="appearance-color-row"><span>Accent color</span><span id="accent-color-hex">#89b4fa</span><input type="color" class="appearance-color-swatch" name="accent_color"></div>
          <div class="appearance-color-row"><span>Accent secondary (optional)</span><span id="accent-secondary-hex">--</span><input type="color" class="appearance-color-swatch" name="accent_secondary"></div>
          <div class="appearance-color-row"><span>Gradient preview (Save buttons use this)</span><span id="accent-gradient-swatch" style="display:inline-block;width:64px;height:20px;border-radius:6px;border:1px solid var(--line)"></span></div>
          %s
          <h3>Background</h3>
          %s
          <div class="appearance-color-row"><span>Background color (custom_color mode)</span><span id="background-color-hex">#0b0e18</span><input type="color" class="appearance-color-swatch" name="background_color"></div>
          %s
          <h3>Layout</h3>
          %s%s%s%s%s%s%s%s
          <h3>Cards &amp; motion</h3>
          %s%s%s%s
          %s%s
          <!-- BUGFIX: this template had 25 format placeholders against 27
               :format() args (2 short) -- string.format() doesn't error on
               unconsumed *extra* args, it just silently drops them, so
               show_queue_pressure/compact_sidebar's checkboxes never
               rendered at all, and every placeholder from here on consumed
               the WRONG arg one section early: surface_opacity/surface_blur
               rendered under "Profile backdrop" and profile_backdrop_*/
               show_bot_uptime rendered under "Misc". Added the 2 missing
               placeholders here so surface_opacity/surface_blur land in
               their own (correct) "Cards & motion" section instead of
               borrowing Profile backdrop's slots. -->
          %s%s
          <h3>Profile backdrop</h3>
          <p class="page-lede">Applies to every profile card you view (yours and others'), not just this preview widget -- it's a personal skin, not part of any one profile.</p>
          %s
          %s
          <div class="appearance-color-row"><span>Backdrop preview</span><span id="profile-backdrop-readout">Off</span></div>
          <h3>Misc</h3>
          %s%s%s
          <div class="appearance-form-actions">
            <button type="submit" class="button-link primary">Save</button>
            <button type="button" id="appearance-reset" class="button-link">Reset to defaults</button>
          </div>
        </form>
        <div class="panel appearance-preview">
          <div class="appearance-preview-shell" id="appearance-preview-shell">
            <div class="preview-topline"><span></span><strong>Live Preview</strong></div>
            <div class="appearance-preview-hero">
              <div class="preview-tabs"><span class="nav-item">Dashboard</span><span class="nav-item">Controls</span><span class="nav-item">Users</span></div>
              <h3>SwarmPanel</h3>
              <div class="appearance-preview-meta">
                <span class="appearance-value-pill" id="preview-theme-pill">Dark</span>
                <span class="appearance-value-pill" id="preview-density-pill">Comfortable</span>
              </div>
            </div>
            <div class="appearance-preview-shell-panel">
              <div class="appearance-preview-shell-topbar"><span>Fleet Command</span><span class="data-pill data-pill-live">Live</span></div>
              <div class="preview-card bot-card">
                <strong>Sample Bot Card</strong>
                <span>This is roughly how cards and accents will look with your current draft settings.</span>
                <div class="chip-row">
                  <span data-bot-uptime>heartbeat 4s ago</span>
                  <span data-queue-pressure>3 queued</span>
                </div>
              </div>
            </div>
            <div class="chip-row" id="preview-mini-stats">
              <span class="appearance-mini-stat" id="preview-accent-stat">Accent --</span>
              <span class="appearance-mini-stat" id="preview-shape-stat">Cards --</span>
              <span class="appearance-mini-stat" id="preview-hover-stat">Hover --</span>
              <span class="appearance-mini-stat" id="preview-radius-stat">Radius --</span>
              <span class="appearance-mini-stat" id="preview-font-stat">Font --</span>
            </div>
            <p class="appearance-preview-note">Updates live as you edit below. Nothing is applied anywhere else until you hit Save.</p>
          </div>
        </div>
        </div>
        <div id="appearance-msg"></div>
      ]]):format(
        admin_toggle_section,
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
      const APPEARANCE_PRESETS = {
        midnight_ops: { theme_mode: "dark", background_mode: "midnight", accent_color: "#89b4fa", card_shape: "soft", card_hover_effect: "lift" },
        aurora_glass: { theme_mode: "dark", background_mode: "aurora", accent_color: "#7ee787", card_shape: "soft", card_hover_effect: "glow" },
        ember_signal: { theme_mode: "dark", background_mode: "ember", accent_color: "#f38ba8", card_shape: "crisp", card_hover_effect: "border" },
      };
      // Delegated (not per-button) so server-provided presets fetched below
      // -- added to the grid well after this script runs -- still work.
      document.getElementById("appearance-form").addEventListener("click", (e) => {
        const btn = e.target.closest("[data-preset]");
        if (!btn) return;
        const preset = APPEARANCE_PRESETS[btn.getAttribute("data-preset")];
        if (!preset) return;
        const f = document.getElementById("appearance-form");
        for (const [key, value] of Object.entries(preset)) {
          if (f.elements[key]) f.elements[key].value = value;
        }
        updatePreview();
        markDirty();
        swarmToast("Preset applied -- Save to keep it.", "success");
      });
      // Server-owned presets (looks.lua's PANEL_LOOKS, "new look bundles ship
      // without a frontend redeploy") extend the three hardcoded ones above
      // rather than replacing them -- GET /api/appearance/presets existed
      // with no frontend caller at all until this.
      (async () => {
        try {
          const res = await swarmFetch("/api/appearance/presets");
          const grid = document.getElementById("server-preset-grid");
          (res.panel || []).forEach((preset) => {
            APPEARANCE_PRESETS[preset.id] = preset.patch;
            const card = document.createElement("button");
            card.type = "button";
            card.className = "appearance-preset-card";
            card.setAttribute("data-preset", preset.id);
            card.innerHTML = `<strong>${preset.title.replace(/</g, "&lt;")}</strong><span>${(preset.note || "").replace(/</g, "&lt;")}</span>`;
            grid.appendChild(card);
          });
        } catch { /* server presets are additive -- the 3 built-in ones still work */ }
      })();
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
      //
      // Every field below is applied via the *exact same* class-name and
      // CSS-variable scheme html.lua's panel_class()/panel_style() use on
      // the real page (see app.css's .panel-* rules) -- ported to JS here
      // rather than reinvented, so "what the preview shows" and "what
      // Save+reload actually produces" can never drift apart. Applied to
      // #appearance-preview-shell (not the outer .appearance-preview panel,
      // which has its own ::before decoration that a `panel-bg-*::before`
      // class would otherwise collide with) -- CSS custom properties still
      // inherit down to every element inside it either way.
      // Mirrors colorutil.lua's auto_secondary()/gradient() exactly (+150deg
      // hue rotation, lightness pulled toward mid-range) so the preview
      // swatch shows the SAME gradient html.lua's panel_style() will
      // actually render once saved -- html.lua now always computes
      // --accent-gradient server-side (using this same fallback when no
      // accent_secondary is set), so this is preview parity, not a second
      // implementation of the feature.
      function hexToRgb(hex) {
        const m = /^#?([0-9a-f]{6})$/i.exec(hex || "");
        if (!m) return null;
        const n = parseInt(m[1], 16);
        return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
      }
      function rgbToHex(r, g, b) {
        const c = (v) => Math.max(0, Math.min(255, Math.round(v))).toString(16).padStart(2, "0");
        return "#" + c(r) + c(g) + c(b);
      }
      function rgbToHsl(r, g, b) {
        r /= 255; g /= 255; b /= 255;
        const max = Math.max(r, g, b), min = Math.min(r, g, b);
        let h = 0, s = 0; const l = (max + min) / 2;
        const d = max - min;
        if (d !== 0) {
          s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
          if (max === r) h = (g - b) / d + (g < b ? 6 : 0);
          else if (max === g) h = (b - r) / d + 2;
          else h = (r - g) / d + 4;
          h /= 6;
        }
        return [h, s, l];
      }
      function hueToRgb(p, q, t) {
        if (t < 0) t += 1;
        if (t > 1) t -= 1;
        if (t < 1 / 6) return p + (q - p) * 6 * t;
        if (t < 1 / 2) return q;
        if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
        return p;
      }
      function hslToRgb(h, s, l) {
        if (s === 0) return [l * 255, l * 255, l * 255];
        const q = l < 0.5 ? l * (1 + s) : l + s - l * s;
        const p = 2 * l - q;
        return [hueToRgb(p, q, h + 1 / 3) * 255, hueToRgb(p, q, h) * 255, hueToRgb(p, q, h - 1 / 3) * 255];
      }
      function autoSecondary(hex) {
        const rgb = hexToRgb(hex);
        if (!rgb) return "#7c3aed";
        let [h, s, l] = rgbToHsl(...rgb);
        h = (h + 150 / 360) % 1;
        l = Math.max(0, Math.min(1, l * 0.7 + 0.5 * 0.3));
        return rgbToHex(...hslToRgb(h, Math.max(s, 0.45), l));
      }
      function accentGradientFromForm(f) {
        const accent = val(f, "accent_color", "#89b4fa") || "#89b4fa";
        const secondary = val(f, "accent_secondary", "") || autoSecondary(accent);
        return `linear-gradient(135deg, ${accent}, ${secondary})`;
      }
      const BG_PRESET_COLORS = { default: "#0d1117", midnight: "#090b12", aurora: "#101821", ember: "#17100d" };
      function val(f, name, fallback) {
        const el = f.elements[name];
        if (!el) return fallback;
        return el.type === "checkbox" ? el.checked : el.value;
      }
      function panelClassesFromForm(f) {
        const notifyPos = val(f, "notification_position", "br") || "br";
        const classes = [
          "panel-theme-" + (val(f, "theme_mode", "dark") || "dark"),
          "panel-bg-" + (val(f, "background_mode", "default") || "default"),
          "panel-layout-" + (val(f, "layout_mode", "standard") || "standard"),
          "panel-density-" + (val(f, "density", "comfortable") || "comfortable"),
          "panel-shape-" + (val(f, "card_shape", "soft") || "soft"),
          "panel-font-" + (val(f, "font_scale", "normal") || "normal"),
          "panel-motion-" + (val(f, "motion", "standard") || "standard"),
          "panel-operator-" + (val(f, "operator_layout", "command") || "command"),
          "panel-roster-" + (val(f, "roster_layout", "cards") || "cards"),
          "panel-tabs-" + (val(f, "tab_style", "rail") || "rail"),
          "panel-stream-" + (val(f, "stream_card_style", "telemetry") || "telemetry"),
          "panel-dashboard-" + (val(f, "dashboard_density", "command") || "command"),
          "panel-hover-" + (val(f, "card_hover_effect", "lift") || "lift"),
          notifyPos !== "br" ? "panel-notify-" + notifyPos : "",
          "panel-radius-" + (val(f, "panel_radius", "medium") || "medium"),
          "panel-fontfamily-" + (val(f, "panel_font_family", "system") || "system"),
          "panel-nav-" + (val(f, "sidebar_style", "full") || "full"),
          "panel-detail-" + (val(f, "bot_card_detail", "full") || "full"),
          val(f, "show_bot_uptime", true) === false ? "panel-hide-uptime" : "",
          val(f, "show_queue_pressure", true) === false ? "panel-hide-queue-pressure" : "",
          val(f, "compact_sidebar", false) === true ? "panel-compact-nav" : "",
        ];
        return classes.filter(Boolean);
      }
      function panelStyleFromForm(f) {
        const accent = val(f, "accent_color", "#89b4fa") || "#89b4fa";
        const mode = val(f, "background_mode", "default") || "default";
        const bg = mode === "custom_color" ? (val(f, "background_color", "#0b0e18") || "#0b0e18") : (BG_PRESET_COLORS[mode] || BG_PRESET_COLORS.default);
        const imgUrl = val(f, "background_image_url", "");
        const useImage = mode === "custom_image" && /^https?:\/\//.test(imgUrl || "");
        const surfaceOpacity = Math.min(1, Math.max(0.35, parseFloat(val(f, "surface_opacity", 0.92)) || 0.92));
        const surfaceBlur = Math.min(36, Math.max(0, parseFloat(val(f, "surface_blur", 18)) || 18));
        const props = {
          "--accent": accent,
          "--bg": bg,
          "--panel-bg-image": useImage ? `url("${imgUrl.replace(/["\\]/g, "\\$&")}")` : "none",
          "--surface-opacity": String(surfaceOpacity),
          "--surface-blur": surfaceBlur + "px",
          "--accent-gradient": accentGradientFromForm(f),
        };
        return props;
      }
      function updatePreview() {
        const f = document.getElementById("appearance-form");
        const shell = document.getElementById("appearance-preview-shell");
        if (shell) {
          shell.className = "appearance-preview-shell " + panelClassesFromForm(f).join(" ");
          const props = panelStyleFromForm(f);
          for (const [k, v] of Object.entries(props)) shell.style.setProperty(k, v);
        }
        const accent = val(f, "accent_color", "#89b4fa") || "#89b4fa";
        const themeMode = val(f, "theme_mode", "dark") || "dark";
        document.getElementById("preview-theme-pill").textContent = themeMode.charAt(0).toUpperCase() + themeMode.slice(1);
        const density = val(f, "density", "comfortable") || "comfortable";
        document.getElementById("preview-density-pill").textContent = density.charAt(0).toUpperCase() + density.slice(1);
        document.getElementById("preview-accent-stat").textContent = "Accent " + accent;
        const cardShape = val(f, "card_shape", "soft") || "soft";
        document.getElementById("preview-shape-stat").textContent = "Cards " + (cardShape.charAt(0).toUpperCase() + cardShape.slice(1));
        const hoverEffect = val(f, "card_hover_effect", "lift") || "lift";
        document.getElementById("preview-hover-stat").textContent = "Hover " + (hoverEffect.charAt(0).toUpperCase() + hoverEffect.slice(1));
        const radius = val(f, "panel_radius", "medium") || "medium";
        document.getElementById("preview-radius-stat").textContent = "Radius " + (radius.charAt(0).toUpperCase() + radius.slice(1));
        const fontScale = val(f, "font_scale", "normal") || "normal";
        document.getElementById("preview-font-stat").textContent = "Font " + (fontScale.charAt(0).toUpperCase() + fontScale.slice(1));
        document.getElementById("accent-color-hex").textContent = accent;
        document.getElementById("accent-secondary-hex").textContent = (f.elements.accent_secondary && f.elements.accent_secondary.value) || "--";
        document.getElementById("background-color-hex").textContent = (f.elements.background_color && f.elements.background_color.value) || "#0b0e18";
        document.getElementById("accent-gradient-swatch").style.background = accentGradientFromForm(f);
        const backdropUrl = (val(f, "profile_backdrop_image_url", "") || "").trim();
        const backdropStrength = Math.round((parseFloat(val(f, "profile_backdrop_strength", 0.18)) || 0.18) * 100);
        document.getElementById("profile-backdrop-readout").textContent = /^https?:\/\//.test(backdropUrl)
          ? `Image set, ${backdropStrength}% strength` : `No image -- ${backdropStrength}% accent tint only`;
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
      const adminModeToggle = document.getElementById("settings-admin-mode-toggle");
      if (adminModeToggle) {
        adminModeToggle.addEventListener("change", async () => {
          const enabled = adminModeToggle.checked;
          try {
            await swarmFetch("/api/session/admin-mode", { method: "POST", body: JSON.stringify({ enabled }) });
            swarmToast(enabled ? "Admin mode on." : "Admin mode off.", "success");
            window.location.reload();
          } catch (err) {
            adminModeToggle.checked = !enabled;
            swarmToast(err.message, "error");
          }
        });
      }
    ]]
    return page_shell(req, a, "/appearance", "Appearance", body, script)
  end)

  -- -----------------------------------------------------------------
  -- My Other Projects
  -- -----------------------------------------------------------------
  httpd.route("GET", "/other-projects", function(req)
    local a, status, headers = cfg.require_auth_page(req)
    if not a then return status, "", headers end

    local body = html.page({
      eyebrow = "Elsewhere", title = "My Other Projects", lede = "A couple of other things I've built.",
      body = [[
        <div class="project-card-grid">
          <a class="project-card liquid-glass" href="https://gallery.xenusanimations.studio" target="_blank" rel="noopener noreferrer">
            <div class="project-card-logo"><img src="/static/images/image-gallery.png" alt="" loading="lazy" decoding="async"></div>
            <div class="project-card-copy"><h3>Image Gallery</h3><p>Curated media deck for uploads, collections, and social feeds.</p></div>
            <div class="project-card-cta"><span>Open</span></div>
          </a>
          <button type="button" class="project-card liquid-glass" id="lumisound-download-card">
            <div class="project-card-logo"><img src="/static/images/lumisound.png" alt="" loading="lazy" decoding="async"></div>
            <div class="project-card-copy"><h3>Lumisound</h3><p>iOS music app. Downloads the latest build straight from GitHub.</p></div>
            <div class="project-card-cta" id="lumisound-download-cta"><span>Download latest</span></div>
          </button>
        </div>
      ]],
    })
    local script = [[
      const lumisoundCard = document.getElementById("lumisound-download-card");
      const lumisoundCta = document.getElementById("lumisound-download-cta");
      if (lumisoundCard) {
        lumisoundCard.addEventListener("click", async () => {
          if (lumisoundCard.disabled) return;
          lumisoundCard.disabled = true;
          lumisoundCta.innerHTML = "<span>Fetching…</span>";
          try {
            const headers = {};
            if (window.SWARM_TOKEN) headers.Authorization = "Bearer " + window.SWARM_TOKEN;
            const res = await fetch("/api/projects/lumisound/download", { headers });
            if (!res.ok) {
              let detail = res.statusText;
              try { detail = (await res.json()).detail || detail; } catch {}
              throw new Error(detail);
            }
            const disposition = res.headers.get("content-disposition") || "";
            const match = disposition.match(/filename="([^"]+)"/);
            const filename = match ? match[1] : "Lumisound.ipa";
            const blob = await res.blob();
            const url = URL.createObjectURL(blob);
            const link = document.createElement("a");
            link.href = url;
            link.download = filename;
            document.body.appendChild(link);
            link.click();
            link.remove();
            URL.revokeObjectURL(url);
            swarmToast("Lumisound download started.", "success");
          } catch (err) {
            swarmToast(err.message, "error");
          } finally {
            lumisoundCard.disabled = false;
            lumisoundCta.innerHTML = "<span>Download latest</span>";
          }
        });
      }
    ]]
    return page_shell(req, a, "/other-projects", "My Other Projects", body, script)
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
      function applyStability(stability) {
        document.getElementById("diag-stability").innerHTML = '<pre class="json-panel">' + JSON.stringify(stability, null, 2).replace(/</g, "&lt;") + "</pre>";
      }
      function applyDiagMetrics(metrics) {
        document.getElementById("diag-metrics").innerHTML = '<pre class="json-panel">' + JSON.stringify(metrics, null, 2).replace(/</g, "&lt;") + "</pre>";
      }
      function applyAlerts(res) {
        document.getElementById("diag-alerts").innerHTML = (res.rules || []).map((r) => `
          <div class="alert-rule">
            <span><strong>${r.rule_type}</strong> — ${r.threshold_minutes}m${r.escalation_minutes ? `, escalate after ${r.escalation_minutes}m` : ""}${r.escalate_email ? " (email)" : ""}</span>
            <label class="switch"><input type="checkbox" data-toggle-rule="${r.id}" ${r.enabled ? "checked" : ""}> Enabled</label>
            <button type="button" data-delete-rule="${r.id}">Delete</button>
          </div>`).join("") || "<p>No alert rules.</p>";
      }
      function applyExports(res) {
        const rows = (res.snapshots || []).flatMap((snap) => (snap.files || []).map((f) =>
          `<div><a href="/api/exports/${snap.date}/${f.name}">${snap.date}/${f.name}</a> (${f.size_bytes}b)</div>`));
        document.getElementById("diag-exports").innerHTML = rows.join("") || "<p>No exports.</p>";
      }
      window.swarmLive.watch("stability", (msg) => { if (msg.type === "snapshot") applyStability(msg.data); });
      window.swarmLive.watch("metrics_snapshot", (msg) => { if (msg.type === "snapshot") applyDiagMetrics(msg.data); });
      window.swarmLive.watch("alert_rules", (msg) => { if (msg.type === "snapshot") applyAlerts(msg.data); });
      window.swarmLive.watch("exports", (msg) => { if (msg.type === "snapshot") applyExports(msg.data); });
      function refreshAlerts() { swarmFetch("/api/alert-rules").then(applyAlerts).catch(() => {}); }
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
          refreshAlerts();
        } catch (err) { swarmToast(err.message, "error"); }
      });
      document.getElementById("diag-alerts").addEventListener("click", async (e) => {
        const id = e.target.getAttribute("data-delete-rule");
        if (id) { await swarmFetch(`/api/alert-rules/${id}/delete`, { method: "POST" }).catch(() => {}); refreshAlerts(); }
      });
      document.getElementById("diag-alerts").addEventListener("change", async (e) => {
        const id = e.target.getAttribute("data-toggle-rule");
        if (!id) return;
        try {
          await swarmFetch(`/api/alert-rules/${id}/update`, { method: "POST", body: JSON.stringify({ enabled: e.target.checked }) });
        } catch (err) { swarmToast(err.message, "error"); e.target.checked = !e.target.checked; }
      });
      document.getElementById("diag-refresh").addEventListener("click", () => {
        swarmFetch("/api/stability").then(applyStability).catch(() => {});
        swarmFetch("/api/metrics").then(applyDiagMetrics).catch(() => {});
        refreshAlerts();
        swarmFetch("/api/exports").then(applyExports).catch(() => {});
        swarmToast("Refreshed.", "success");
      });
    ]]
    return page_shell(req, a, "/diagnostics", "Diagnostics", body, script)
  end)
end

return M
