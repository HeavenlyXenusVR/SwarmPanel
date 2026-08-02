-- Server-rendered pages: Messages, Profile, Appearance, Diagnostics.
-- Same pattern as pages_ops.lua: shell server-side, data via swarmFetch
-- against the existing JSON API.
local httpd = require("httpd")
local html = require("html")

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
      script = [[
        (async () => {
          const view = document.getElementById("profile-view");
          const id = view.dataset.profileId;
          try {
            const res = await swarmFetch("/api/users/" + encodeURIComponent(id) + "/profile");
            const p = res.profile || {};
            view.innerHTML = `
              <div class="profile-header"><h2>${(p.display_name||p.username||"Unknown").replace(/</g,"&lt;")}</h2>
              <p>${(p.bio||"").replace(/</g,"&lt;")}</p></div>
              <div class="profile-actions">
                <button type="button" id="follow-btn">Follow</button>
                <button type="button" id="friend-btn">Add friend</button>
                <a href="/messages">Message</a>
              </div>`;
            document.getElementById("follow-btn").addEventListener("click", () =>
              swarmFetch("/api/users/" + encodeURIComponent(id) + "/follow", { method: "POST" }).then(() => swarmToast("Followed.", "success")).catch((e) => swarmToast(e.message, "error")));
            document.getElementById("friend-btn").addEventListener("click", () =>
              swarmFetch("/api/users/" + encodeURIComponent(id) + "/friend-request", { method: "POST" }).then(() => swarmToast("Request sent.", "success")).catch((e) => swarmToast(e.message, "error")));
          } catch (err) { view.innerHTML = '<div class="notice notice-error">Profile not found.</div>'; }
        })();
      ]]
    else
      body = html.page({
        title = "Profile", eyebrow = "Account", lede = "Edit how you appear across the panel.",
        body = [[
          <form id="profile-form" class="panel form-panel">
            <label class="field">Display name<input name="display_name"></label>
            <label class="field">Bio<textarea name="bio" rows="3"></textarea></label>
            <label class="field">Accent color<input type="color" name="theme_accent"></label>
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
        ]],
      })
      script = [[
        (async () => {
          try {
            const res = await swarmFetch("/api/users/me");
            const p = res.profile || {};
            const f = document.getElementById("profile-form");
            f.display_name.value = p.display_name || "";
            f.bio.value = p.bio || "";
            f.theme_accent.value = p.theme_accent || "#89b4fa";
          } catch { /* ignore */ }
        })();
        document.getElementById("profile-form").addEventListener("submit", async (e) => {
          e.preventDefault();
          const fd = new FormData(e.target);
          try {
            await swarmFetch("/api/users/me", { method: "POST", body: JSON.stringify(Object.fromEntries(fd)) });
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
    local body = html.page({
      title = "Appearance", eyebrow = "Look", lede = "Customize theme, layout, and motion.",
      body = ([[
        <form id="appearance-form" class="panel form-panel">
          %s%s%s%s%s%s%s%s
          <label class="field">Accent color<input type="color" name="accent_color"></label>
          <button type="submit" class="button-link primary">Save</button>
        </form>
        <div id="appearance-msg"></div>
      ]]):format(
        select_field("theme_mode", "Theme", { "dark", "light", "system" }),
        select_field("background_mode", "Background", { "default", "midnight", "aurora", "ember", "custom_color", "custom_image" }),
        select_field("layout_mode", "Layout", { "standard", "focused", "wide" }),
        select_field("density", "Density", { "comfortable", "compact" }),
        select_field("card_shape", "Card shape", { "soft", "crisp" }),
        select_field("motion", "Motion", { "standard", "reduced" }),
        select_field("tab_style", "Tabs", { "rail", "underline", "minimal" }),
        select_field("card_hover_effect", "Hover effect", { "lift", "glow", "border", "none" })),
    })
    local script = [[
      (async () => {
        try {
          const res = await swarmFetch("/api/users/preferences");
          const p = res.preferences || {};
          const f = document.getElementById("appearance-form");
          for (const key of Object.keys(p)) if (f.elements[key]) f.elements[key].value = p[key];
        } catch { /* defaults stay */ }
      })();
      document.getElementById("appearance-form").addEventListener("submit", async (e) => {
        e.preventDefault();
        const fd = new FormData(e.target);
        try {
          await swarmFetch("/api/users/preferences", { method: "POST", body: JSON.stringify(Object.fromEntries(fd)) });
          document.getElementById("appearance-msg").innerHTML = '<div class="notice notice-success">Saved. Reloading...</div>';
          setTimeout(() => window.location.reload(), 600);
        } catch (err) { document.getElementById("appearance-msg").innerHTML = '<div class="notice notice-error">' + err.message + "</div>"; }
      });
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
      body = [[
        <div id="diag-stability"></div>
        <div id="diag-metrics"></div>
        <h3>Alert Rules</h3>
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
          document.getElementById("diag-alerts").innerHTML = (res.rules || []).map((r) =>
            `<div class="alert-rule"><span>${r.rule_type}</span><button data-delete-rule="${r.id}">Delete</button></div>`).join("") || "<p>No alert rules.</p>";
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
      document.getElementById("diag-alerts").addEventListener("click", async (e) => {
        const id = e.target.getAttribute("data-delete-rule");
        if (id) { await swarmFetch(`/api/alert-rules/${id}/delete`, { method: "POST" }).catch(() => {}); loadAlerts(); }
      });
      swarmLiveRefresh(loadDiagnostics, 5000);
      swarmLiveRefresh(loadAlerts, 30000);
      swarmLiveRefresh(loadExports, 60000);
    ]]
    return page_shell(req, a, "/diagnostics", "Diagnostics", body, script)
  end)
end

return M
