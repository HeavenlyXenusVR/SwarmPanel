-- Server-rendered pages: Accounts, Databases, Gallery Admin, Lumisound
-- Admin, Intel, Audit Log. Same pattern as pages_ops.lua/pages_identity.lua.
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

  local function page_shell(req, a, path, title, body_html, extra_script)
    local script = ([[<script>%s</script>]]):format(extra_script or "")
    local prefs = a and accounts.get_panel_preferences(a.username, a.guild_id) or nil
    return 200, html.layout({
      title = title, path = path, session = session_view(a),
      token = req.cookies and req.cookies.swarm_session, preferences = prefs,
      body = body_html .. script,
    }), { ["Content-Type"] = "text/html; charset=utf-8" }
  end

  local function denied(req, a, path, title)
    return 200, html.layout({ title = title, path = path, session = session_view(a),
      body = html.page({ title = title, body = html.notice("error", "You don't have access to this page.") }) }),
      { ["Content-Type"] = "text/html; charset=utf-8" }
  end

  -- -----------------------------------------------------------------
  -- Accounts (admin)
  -- -----------------------------------------------------------------
  httpd.route("GET", "/accounts", function(req)
    local a, status, headers = cfg.require_auth_page(req)
    if not a then return status, "", headers end
    if not a.admin_mode then return denied(req, a, "/accounts", "Accounts") end
    local body = html.page({
      title = "Accounts", eyebrow = "Admin", lede = "Recover and manage swarm accounts.",
      body = [[
        <div class="search-box">
          <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true"><circle cx="7" cy="7" r="5" stroke="currentColor" stroke-width="1.6"/><path d="M11 11L14.5 14.5" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>
          <input type="search" placeholder="Search accounts..." data-debounced-search id="acct-search">
        </div>
        <div id="bulk-actions" class="bulk-actions-bar" data-bulk-actions hidden>
          <button type="button" id="bulk-verify">Verify selected</button>
          <button type="button" id="bulk-delete">Delete selected</button>
        </div>
        <div id="accounts-table">]] .. html.skeleton_grid(4) .. [[</div>
      ]],
    })
    local script = [[
      let table;
      async function loadAccounts(q) {
        try {
          const res = await swarmFetch("/api/swarm-accounts/admin?query=" + encodeURIComponent(q || "") + "&limit=100");
          const rows = ((res.data && res.data.users) || []).map((acc) => `
            <tr>
              <td><input type="checkbox" data-select-row value="${acc.id}"></td>
              <td>${(acc.username||"").replace(/</g,"&lt;")}</td>
              <td>${acc.email_verified ? "verified" : "unverified"}</td>
              <td>${acc.panel_role||"user"}</td>
              <td>
                <button data-verify="${acc.id}">Verify</button>
                <button data-reset="${acc.id}">Reset PW</button>
                <button data-mod="${acc.id}">Toggle Mod</button>
                <button data-delete="${acc.id}">Delete</button>
              </td>
            </tr>`).join("");
          document.getElementById("accounts-table").innerHTML = `
            <table class="data-table" id="accounts-tbl">
              <thead><tr><th><input type="checkbox" data-select-all></th><th>Username</th><th>Email</th><th>Role</th><th>Actions</th></tr></thead>
              <tbody>${rows || '<tr><td colspan="5">No accounts.</td></tr>'}</tbody>
            </table>`;
          table = document.getElementById("accounts-tbl");
        } catch (err) { swarmToast("Failed to load accounts.", "error"); }
      }
      document.getElementById("acct-search").addEventListener("swarm:search", (e) => loadAccounts(e.detail.query));
      loadAccounts("");
      document.getElementById("accounts-table").addEventListener("click", async (e) => {
        const t = e.target;
        try {
          if (t.hasAttribute("data-verify")) await swarmFetch("/api/swarm-accounts/email-verified", { method: "POST", body: JSON.stringify({ account_id: t.getAttribute("data-verify"), verified: true }) });
          else if (t.hasAttribute("data-reset")) await swarmFetch("/api/swarm-accounts/reset-password", { method: "POST", body: JSON.stringify({ account_id: t.getAttribute("data-reset") }) });
          else if (t.hasAttribute("data-mod")) await swarmFetch("/api/swarm-accounts/moderator", { method: "POST", body: JSON.stringify({ account_id: t.getAttribute("data-mod") }) });
          else if (t.hasAttribute("data-delete")) { if (!confirm("Delete this account?")) return; await swarmFetch("/api/swarm-accounts/delete", { method: "POST", body: JSON.stringify({ account_id: t.getAttribute("data-delete") }) }); }
          else return;
          swarmToast("Done.", "success");
          loadAccounts(document.getElementById("acct-search").value);
        } catch (err) { swarmToast(err.message, "error"); }
      });
      document.getElementById("bulk-verify").addEventListener("click", async () => {
        const ids = swarmSelectedIds(table);
        try { await swarmFetch("/api/swarm-accounts/bulk-verify", { method: "POST", body: JSON.stringify({ account_ids: ids }) }); loadAccounts(""); } catch (err) { swarmToast(err.message, "error"); }
      });
      document.getElementById("bulk-delete").addEventListener("click", async () => {
        const ids = swarmSelectedIds(table);
        if (!confirm("Delete " + ids.length + " accounts?")) return;
        try { await swarmFetch("/api/swarm-accounts/bulk-delete", { method: "POST", body: JSON.stringify({ account_ids: ids }) }); loadAccounts(""); } catch (err) { swarmToast(err.message, "error"); }
      });
    ]]
    return page_shell(req, a, "/accounts", "Accounts", body, script)
  end)

  -- -----------------------------------------------------------------
  -- Databases (admin)
  -- -----------------------------------------------------------------
  httpd.route("GET", "/databases", function(req)
    local a, status, headers = cfg.require_auth_page(req)
    if not a then return status, "", headers end
    if not a.admin_mode then return denied(req, a, "/databases", "Databases") end
    local body = html.page({
      title = "Databases", eyebrow = "Admin", lede = "Browse raw schema tables.",
      body = [[
        <div class="panel form-panel">
          <label class="field">Schema<select id="db-schema"></select></label>
          <label class="field">Table<select id="db-table"></select></label>
          <a id="db-csv" class="button-link" target="_blank">Export CSV</a>
        </div>
        <div id="db-data"></div>
      ]],
    })
    local script = [[
      async function loadSchemas() {
        try {
          const res = await swarmFetch("/api/databases?include_tables=true");
          const sel = document.getElementById("db-schema");
          sel.innerHTML = (res.schemas || []).map((d) => `<option value="${d.schema}">${d.schema}</option>`).join("");
          window.SWARM_DB_TABLES = {};
          (res.schemas || []).forEach((d) => { window.SWARM_DB_TABLES[d.schema] = d.tables || []; });
          onSchemaChange();
        } catch (err) { swarmToast("Failed to load databases.", "error"); }
      }
      function onSchemaChange() {
        const schema = document.getElementById("db-schema").value;
        const tableSel = document.getElementById("db-table");
        tableSel.innerHTML = (window.SWARM_DB_TABLES[schema] || []).map((t) => `<option value="${t.table_name}">${t.table_name} (${t.estimated_rows})</option>`).join("");
        loadTableData();
      }
      async function loadTableData() {
        const schema = document.getElementById("db-schema").value;
        const table = document.getElementById("db-table").value;
        if (!schema || !table) return;
        document.getElementById("db-csv").href = `/api/database/data?schema_name=${schema}&table_name=${table}&format=csv`;
        try {
          const res = await swarmFetch(`/api/database/data?schema_name=${schema}&table_name=${table}&limit=100`);
          const rows = res.rows || [];
          if (!rows.length) { document.getElementById("db-data").innerHTML = "<p>No rows.</p>"; return; }
          const cols = Object.keys(rows[0]).slice(0, 9);
          const thead = cols.map((c) => `<th>${c}</th>`).join("");
          const tbody = rows.map((r) => "<tr>" + cols.map((c) => swarmTableCell(c, r[c])).join("") + "</tr>").join("");
          document.getElementById("db-data").innerHTML = `<table class="data-table"><thead><tr>${thead}</tr></thead><tbody>${tbody}</tbody></table>`;
        } catch (err) { swarmToast("Failed to load table.", "error"); }
      }
      document.getElementById("db-schema").addEventListener("change", onSchemaChange);
      document.getElementById("db-table").addEventListener("change", loadTableData);
      loadSchemas();
    ]]
    return page_shell(req, a, "/databases", "Databases", body, script)
  end)

  -- -----------------------------------------------------------------
  -- Gallery Admin (image_gallery_owner)
  -- -----------------------------------------------------------------
  httpd.route("GET", "/gallery-admin", function(req)
    local a, status, headers = cfg.require_auth_page(req)
    if not a then return status, "", headers end
    if not ((a.admin_mode == true) and (a.site_owner == true)) then return denied(req, a, "/gallery-admin", "Gallery Admin") end
    local body = html.page({
      title = "Gallery Admin", eyebrow = "Image Gallery", lede = "Users, media, comments, and reports.",
      body = [[
        <div class="loading-section is-loading" id="gallery-loading-section">
          <div class="loading-section-content">
            <div id="gallery-summary"></div>
            <div class="panel form-panel">
              <label class="field">Table<select id="gallery-table"></select></label>
              <a id="gallery-csv-media" class="button-link" href="/api/image-gallery/admin/media/export.csv" target="_blank">Export Media CSV</a>
              <a id="gallery-csv-users" class="button-link" href="/api/image-gallery/admin/users/export.csv" target="_blank">Export Users CSV</a>
            </div>
            <div id="gallery-bulk-actions" class="bulk-actions-bar" data-bulk-actions hidden>
              <button type="button" id="gallery-bulk-delete" class="danger">Delete selected</button>
            </div>
            <div id="gallery-data">]] .. html.skeleton_grid(4) .. [[</div>
          </div>
          <div class="loading-section-overlay">
            <div class="loading-tip">Fetching Image Gallery admin data...</div>
          </div>
        </div>
      ]],
    })
    local script = [[
      // Row deletion only exists on the backend for these three tables
      // (users/media_items/media_comments -- see gallery.lua's
      // delete_image_gallery_user/media/comment) -- other browsable tables
      // (categories, media_reports, media_collections) stay read-only here,
      // same as they always were, rather than pointing a delete button at
      // an endpoint that doesn't exist.
      const GALLERY_DELETE_CONFIG = {
        users: { idKey: "user_id", single: "/api/image-gallery/users/delete", bulk: "/api/image-gallery/admin/users/bulk-delete" },
        media_items: { idKey: "media_id", single: "/api/image-gallery/media/delete", bulk: "/api/image-gallery/admin/media/bulk-delete" },
        media_comments: { idKey: "comment_id", single: "/api/image-gallery/comments/delete", bulk: "/api/image-gallery/admin/comments/bulk-delete" },
      };
      async function loadGallery() {
        try {
          const summary = await swarmFetch("/api/image-gallery/admin");
          document.getElementById("gallery-summary").innerHTML = '<pre class="json-panel">' + JSON.stringify(summary, null, 2).replace(/</g, "&lt;") + "</pre>";
        } catch { /* ignore */ }
        try {
          const tables = await swarmFetch("/api/image-gallery/tables");
          const sel = document.getElementById("gallery-table");
          sel.innerHTML = (tables.tables || []).map((t) => `<option value="${t.table_name}">${t.table_name} (${t.estimated_rows})</option>`).join("");
          loadGalleryTable();
        } catch { /* ignore */ }
        document.getElementById("gallery-loading-section").classList.remove("is-loading");
      }
      function currentGalleryDeleteConfig() {
        return GALLERY_DELETE_CONFIG[document.getElementById("gallery-table").value];
      }
      async function loadGalleryTable() {
        const table = document.getElementById("gallery-table").value;
        if (!table) return;
        document.getElementById("gallery-bulk-actions").hidden = true;
        try {
          const res = await swarmFetch(`/api/image-gallery/table-data?table_name=${table}&limit=100`);
          const rows = res.rows || [];
          if (!rows.length) { document.getElementById("gallery-data").innerHTML = "<p>No rows.</p>"; return; }
          const cols = Object.keys(rows[0]).slice(0, 9);
          const deletable = currentGalleryDeleteConfig();
          const thead = (deletable ? '<th><input type="checkbox" data-select-all></th>' : "") + cols.map((c) => `<th>${c}</th>`).join("") + (deletable ? "<th>Actions</th>" : "");
          const tbody = rows.map((r) => "<tr>"
            + (deletable ? `<td><input type="checkbox" data-select-row value="${r.id}"></td>` : "")
            + cols.map((c) => swarmTableCell(c, r[c])).join("")
            + (deletable ? `<td><button type="button" data-gallery-delete-row="${r.id}">Delete</button></td>` : "")
            + "</tr>").join("");
          document.getElementById("gallery-data").innerHTML = `<table class="data-table" id="gallery-table-el"><thead><tr>${thead}</tr></thead><tbody>${tbody}</tbody></table>`;
        } catch (err) { swarmToast("Failed to load table.", "error"); }
      }
      document.getElementById("gallery-table").addEventListener("change", loadGalleryTable);
      document.getElementById("gallery-data").addEventListener("click", async (e) => {
        const id = e.target.getAttribute("data-gallery-delete-row");
        if (!id) return;
        const cfg = currentGalleryDeleteConfig();
        if (!cfg || !confirm("Delete this row? This cannot be undone.")) return;
        try {
          await swarmFetch(cfg.single, { method: "POST", body: JSON.stringify({ [cfg.idKey]: id }) });
          swarmToast("Deleted.", "success");
          loadGalleryTable();
        } catch (err) { swarmToast(err.message, "error"); }
      });
      document.getElementById("gallery-bulk-delete").addEventListener("click", async () => {
        const cfg = currentGalleryDeleteConfig();
        const ids = Array.from(document.querySelectorAll("#gallery-table-el [data-select-row]:checked")).map((b) => b.value);
        if (!cfg || !ids.length || !confirm(`Delete ${ids.length} selected row(s)? This cannot be undone.`)) return;
        try {
          await swarmFetch(cfg.bulk, { method: "POST", body: JSON.stringify({ ids }) });
          swarmToast("Deleted.", "success");
          loadGalleryTable();
        } catch (err) { swarmToast(err.message, "error"); }
      });
      loadGallery();
    ]]
    return page_shell(req, a, "/gallery-admin", "Gallery Admin", body, script)
  end)

  -- -----------------------------------------------------------------
  -- Lumisound Admin (admin or moderator)
  -- -----------------------------------------------------------------
  httpd.route("GET", "/lumisound-admin", function(req)
    local a, status, headers = cfg.require_auth_page(req)
    if not a then return status, "", headers end
    if not (a.admin_mode or a.moderator) then return denied(req, a, "/lumisound-admin", "Lumisound Admin") end
    -- Full port of LumisoundAdminPage.jsx (150 lines: metric grid + 6 live
    -- data tables with real admin actions) -- the first Lua pass just
    -- JSON.stringify()'d the whole /api/lumisound/admin response into a
    -- <pre>, which lost every admin action (suspend/reinstate users,
    -- delete uploads, resolve/reopen bug reports all already existed as
    -- working API endpoints -- routes.lua's /api/lumisound/users/active,
    -- /api/lumisound/uploads/delete, /api/lumisound/bug-reports/status --
    -- just with no UI left to call them from).
    local body = html.page({
      title = "Lumisound", eyebrow = "Admin Workspace", lede = "Account, library, and activity data for the Lumisound iOS app.",
      body = [[
        <div id="lumisound-metrics" class="metric-grid"></div>
        <div class="dashboard-grid">
          <div class="panel wide"><div class="section-head"><h2>Listening Now</h2></div><div id="lumisound-now-playing"></div></div>
          <div class="panel wide"><div class="section-head"><h2>Recent Plays</h2></div><div id="lumisound-recent-plays"></div></div>
          <div class="panel wide"><div class="section-head"><h2>Users</h2></div><div id="lumisound-users"></div></div>
          <div class="panel wide"><div class="section-head"><h2>Recent Uploads</h2></div><div id="lumisound-uploads"></div></div>
          <div class="panel"><div class="section-head"><h2>Bug Reports</h2></div><div id="lumisound-bugs"></div></div>
          <div class="panel"><div class="section-head"><h2>Active Listen Rooms</h2></div><div id="lumisound-rooms"></div></div>
        </div>
      ]],
    })
    -- Uses [=[ ]=] instead of [[ ]] -- the JS below has array-literal
    -- patterns like ["upload_count", "Uploads"]] whose trailing "]]" would
    -- otherwise close a plain Lua long-bracket string early and truncate
    -- the rest of the script silently.
    local script = [=[
      function lsEsc(s) { return String(s == null ? "" : s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }
      function lsBytes(n) {
        const v = Number(n) || 0;
        if (v <= 0) return "0 B";
        const units = ["B", "KB", "MB", "GB"];
        const exp = Math.min(units.length - 1, Math.floor(Math.log(v) / Math.log(1024)));
        return (v / 1024 ** exp).toFixed(exp ? 1 : 0) + " " + units[exp];
      }
      function lsDuration(sec) {
        const v = Math.max(0, Math.floor(Number(sec) || 0));
        return Math.floor(v / 60) + ":" + String(v % 60).padStart(2, "0");
      }
      function lsTable(rows, cols, rowHtml) {
        if (!rows || !rows.length) return '<div class="empty-state">No rows.</div>';
        const thead = cols.map(([, label]) => `<th>${lsEsc(label)}</th>`).join("") + "<th>Actions</th>";
        const tbody = rows.map((r) => `<tr>${cols.map(([key, , fmt]) => `<td>${lsEsc(fmt ? fmt(r[key], r) : (r[key] ?? "—"))}</td>`).join("")}<td>${rowHtml ? rowHtml(r) : ""}</td></tr>`).join("");
        return `<div class="table-wrap"><table class="data-table"><thead><tr>${thead}</tr></thead><tbody>${tbody}</tbody></table></div>`;
      }
      async function mutateLumisound(path, payload, message, confirmText) {
        if (confirmText && !confirm(confirmText)) return;
        try {
          await swarmFetch(path, { method: "POST", body: JSON.stringify(payload) });
          swarmToast(message, "success");
          loadLumisound();
        } catch (err) { swarmToast(err.message, "error"); }
      }
      async function loadLumisound() {
        try {
          const res = await swarmFetch("/api/lumisound/admin");
          const d = res.data || {};
          const summary = d.summary || {};
          const users = d.users || [];
          const uploads = d.uploads || [];
          const bugReports = d.bug_reports || [];
          const listenRooms = d.listen_rooms || [];
          const nowPlaying = d.now_playing || [];
          const recentPlays = d.recent_plays || [];

          document.getElementById("lumisound-metrics").innerHTML = [
            ["Users", summary.users ?? users.length], ["Active Users", summary.active_users ?? 0],
            ["Listening Now", summary.listening_now ?? nowPlaying.length], ["Plays (24h)", summary.plays_24h ?? 0],
            ["Uploads", summary.uploads ?? uploads.length], ["Upload Storage", lsBytes(summary.uploads_storage_bytes)],
            ["Playlists", summary.playlists ?? 0], ["Plays Logged", summary.play_history ?? 0],
            ["Open Bug Reports", summary.bug_reports_open ?? bugReports.length], ["Active Listen Rooms", summary.listen_rooms_active ?? listenRooms.length],
          ].map(([label, value]) => `<div class="metric"><span class="metric-value">${lsEsc(value)}</span><span class="metric-label">${lsEsc(label)}</span></div>`).join("");

          document.getElementById("lumisound-now-playing").innerHTML = lsTable(nowPlaying,
            [["username", "User"], ["title", "Title"], ["artist", "Artist"], ["source", "Source"]],
            (r) => `<span>${lsEsc(lsDuration(r.position_seconds))} / ${lsEsc(lsDuration(r.duration_seconds))}</span>`);

          document.getElementById("lumisound-recent-plays").innerHTML = lsTable(recentPlays,
            [["username", "User"], ["title", "Title"], ["artist", "Artist"], ["played_at", "Played At"], ["listen_seconds", "Listened (s)"]]);

          document.getElementById("lumisound-users").innerHTML = lsTable(users,
            [["username", "Username"], ["display_name", "Display Name"], ["email", "Email"], ["created_at", "Created"], ["playlist_count", "Playlists"], ["upload_count", "Uploads"]],
            (r) => (r.is_active === false || r.is_active === 0)
              ? `<button type="button" data-ls-reinstate="${r.id}">Reinstate</button>`
              : `<button type="button" class="danger" data-ls-suspend="${r.id}" data-username="${lsEsc(r.username || r.id)}">Suspend</button>`);

          document.getElementById("lumisound-uploads").innerHTML = lsTable(uploads,
            [["title", "Title"], ["filename", "Filename"], ["artist", "Artist"], ["username", "User"], ["file_size_bytes", "Size", lsBytes], ["uploaded_at", "Uploaded"]],
            (r) => `<button type="button" class="danger" data-ls-delete-upload="${r.id}" data-title="${lsEsc(r.title || r.filename || r.id)}">Delete</button>`);

          document.getElementById("lumisound-bugs").innerHTML = lsTable(bugReports,
            [["username", "User"], ["category", "Category"], ["description", "Description"], ["status", "Status"], ["created_at", "Created"]],
            (r) => r.status === "resolved"
              ? `<button type="button" data-ls-reopen="${r.id}">Reopen</button>`
              : `<button type="button" data-ls-resolve="${r.id}">Resolve</button>`);

          document.getElementById("lumisound-rooms").innerHTML = lsTable(listenRooms,
            [["room_code", "Code"], ["title", "Title"], ["artist", "Artist"], ["host_username", "Host"], ["is_playing", "Playing"], ["updated_at", "Updated"]]);
        } catch (err) { swarmToast("Failed to load Lumisound data.", "error"); }
      }
      document.body.addEventListener("click", (e) => {
        const t = e.target;
        if (t.hasAttribute("data-ls-suspend")) mutateLumisound("/api/lumisound/users/active", { user_id: t.getAttribute("data-ls-suspend"), active: false }, "User suspended.", `Suspend Lumisound user "${t.getAttribute("data-username")}"? They will be blocked from login/API access.`);
        else if (t.hasAttribute("data-ls-reinstate")) mutateLumisound("/api/lumisound/users/active", { user_id: t.getAttribute("data-ls-reinstate"), active: true }, "User reinstated.");
        else if (t.hasAttribute("data-ls-delete-upload")) mutateLumisound("/api/lumisound/uploads/delete", { upload_id: t.getAttribute("data-ls-delete-upload") }, "Upload deleted.", `Delete upload "${t.getAttribute("data-title")}"? This cannot be undone.`);
        else if (t.hasAttribute("data-ls-resolve")) mutateLumisound("/api/lumisound/bug-reports/status", { report_id: t.getAttribute("data-ls-resolve"), status: "resolved" }, "Bug report resolved.");
        else if (t.hasAttribute("data-ls-reopen")) mutateLumisound("/api/lumisound/bug-reports/status", { report_id: t.getAttribute("data-ls-reopen"), status: "open" }, "Bug report reopened.");
      });
      swarmLiveRefresh(loadLumisound, 15000);
    ]=]
    return page_shell(req, a, "/lumisound-admin", "Lumisound Admin", body, script)
  end)

  -- -----------------------------------------------------------------
  -- Intel (admin)
  -- -----------------------------------------------------------------
  httpd.route("GET", "/intel", function(req)
    local a, status, headers = cfg.require_auth_page(req)
    if not a then return status, "", headers end
    if not a.admin_mode then return denied(req, a, "/intel", "Intel") end
    -- Ports IntelPage.jsx's 24h TrendChart section (SVG line chart + area
    -- fill + anomaly markers + hover tooltip) -- the first Lua pass never
    -- called /api/metrics/history or /api/metrics/anomalies at all, and
    -- (separately) swarm_metrics_history had stopped receiving new rows
    -- the moment the Python app -- the only thing that ever wrote to it --
    -- was retired. Both are fixed now: main.lua runs a copas thread that
    -- samples fleet totals into that table every 5 minutes (see
    -- metrics.capture_metrics_snapshot), and this page actually reads it.
    local body = html.page({
      title = "Errors And Metrics", eyebrow = "Intel", lede = "Trends, anomalies, and raw events.",
      body = [[
        <div id="intel-anomaly-banner"></div>
        <div class="panel wide">
          <div class="section-head"><h2>24h Trends</h2></div>
          <div class="trend-chart-grid" id="intel-trends"></div>
        </div>
        <div class="dashboard-grid">
          <div class="panel wide"><div class="section-head"><h2>Events</h2></div><div id="intel-events"></div></div>
          <div class="panel"><div class="section-head"><h2>Metrics</h2></div><div id="intel-metrics"></div></div>
          <div class="panel"><div class="section-head"><h2>Stability</h2></div><div id="intel-stability"></div></div>
        </div>
      ]],
    })
    local script = [=[
      const TREND_METRICS = [
        { key: "queued_tracks", label: "Queued Tracks (24h)", color: "var(--accent)" },
        { key: "active_bots", label: "Active Bots (24h)", color: "var(--ok)" },
      ];
      const TREND_W = 560, TREND_H = 160, TREND_PAD = { top: 12, right: 14, bottom: 22, left: 14 };
      function intelEsc(s) { return String(s == null ? "" : s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }
      function fmtTime(iso) { const d = new Date(iso); return Number.isFinite(d.getTime()) ? d.toLocaleString() : String(iso || ""); }
      function renderTrendChart(points, label, color, anomalies) {
        const safePoints = (points || []).filter((p) => p && p.captured_at);
        const gid = "trend-gradient-" + label.replace(/[^a-z0-9]/gi, "");
        if (!safePoints.length) {
          return `<div class="trend-chart trend-chart-empty"><div class="empty-state">No ${intelEsc(label || "metric")} history yet</div></div>`;
        }
        const values = safePoints.map((p) => Number(p.metric_value) || 0);
        const times = safePoints.map((p) => new Date(p.captured_at).getTime());
        const minValue = Math.min(0, ...values), maxValue = Math.max(1, ...values);
        const minTime = Math.min(...times), maxTime = Math.max(...times);
        const innerW = TREND_W - TREND_PAD.left - TREND_PAD.right, innerH = TREND_H - TREND_PAD.top - TREND_PAD.bottom;
        const xFor = (i) => TREND_PAD.left + ((times[i] - minTime) / (maxTime - minTime || 1)) * innerW;
        const yFor = (v) => TREND_PAD.top + innerH - ((v - minValue) / (maxValue - minValue || 1)) * innerH;
        const linePath = safePoints.map((_, i) => `${i === 0 ? "M" : "L"}${xFor(i).toFixed(2)},${yFor(values[i]).toFixed(2)}`).join(" ");
        const areaPath = `${linePath} L${xFor(safePoints.length - 1).toFixed(2)},${(TREND_PAD.top + innerH).toFixed(2)} L${xFor(0).toFixed(2)},${(TREND_PAD.top + innerH).toFixed(2)} Z`;
        const latest = values[values.length - 1];
        const anomalyTimes = new Set((anomalies || []).map((p) => p.captured_at));
        const anomalyCircles = safePoints.map((p, i) => anomalyTimes.has(p.captured_at)
          ? `<circle cx="${xFor(i)}" cy="${yFor(values[i])}" r="4.5" fill="var(--danger)" stroke="var(--panel)" stroke-width="1.5"><title>Anomaly: ${values[i]} at ${intelEsc(fmtTime(p.captured_at))}</title></circle>` : "").join("");
        return `
          <div class="trend-chart" data-trend-chart data-points='${JSON.stringify(safePoints.map((p, i) => ({ x: xFor(i), y: yFor(values[i]), value: values[i], time: p.captured_at })))}'>
            <div class="trend-chart-head"><span>${intelEsc(label)}</span><strong>${latest}</strong></div>
            <svg viewBox="0 0 ${TREND_W} ${TREND_H}" class="trend-chart-svg" role="img" aria-label="${intelEsc(label)} trend, latest value ${latest}">
              <defs><linearGradient id="${gid}" x1="0" y1="0" x2="0" y2="1"><stop offset="0%" stop-color="${color}" stop-opacity="0.28"/><stop offset="100%" stop-color="${color}" stop-opacity="0"/></linearGradient></defs>
              <line x1="${TREND_PAD.left}" x2="${TREND_W - TREND_PAD.right}" y1="${TREND_PAD.top + innerH}" y2="${TREND_PAD.top + innerH}" class="trend-chart-axis"/>
              <path d="${areaPath}" fill="url(#${gid})" stroke="none"/>
              <path d="${linePath}" fill="none" stroke="${color}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
              ${anomalyCircles}
              <line class="trend-chart-crosshair" data-crosshair y1="${TREND_PAD.top}" y2="${TREND_PAD.top + innerH}" x1="0" x2="0" visibility="hidden"/>
            </svg>
            <div class="trend-chart-tooltip trend-chart-tooltip-muted"><span>Hover the chart for a point-in-time reading.</span></div>
          </div>
        `;
      }
      function wireTrendHover(container) {
        container.querySelectorAll("[data-trend-chart]").forEach((chart) => {
          const svg = chart.querySelector("svg");
          const tooltip = chart.querySelector(".trend-chart-tooltip");
          const crosshair = chart.querySelector("[data-crosshair]");
          const points = JSON.parse(chart.getAttribute("data-points") || "[]");
          if (!points.length) return;
          svg.addEventListener("mousemove", (e) => {
            const rect = svg.getBoundingClientRect();
            const relX = ((e.clientX - rect.left) / rect.width) * TREND_W;
            let nearest = 0, nearestDist = Infinity;
            points.forEach((p, i) => { const d = Math.abs(p.x - relX); if (d < nearestDist) { nearestDist = d; nearest = i; } });
            const p = points[nearest];
            tooltip.className = "trend-chart-tooltip";
            tooltip.innerHTML = `<strong>${p.value}</strong><span>${intelEsc(fmtTime(p.time))}</span>`;
            if (crosshair) {
              crosshair.setAttribute("x1", p.x); crosshair.setAttribute("x2", p.x);
              crosshair.setAttribute("visibility", "visible");
            }
          });
          svg.addEventListener("mouseleave", () => {
            tooltip.className = "trend-chart-tooltip trend-chart-tooltip-muted";
            tooltip.innerHTML = "<span>Hover the chart for a point-in-time reading.</span>";
            if (crosshair) crosshair.setAttribute("visibility", "hidden");
          });
        });
      }
      async function loadTrends() {
        try {
          const results = await Promise.all(TREND_METRICS.map((m) =>
            Promise.all([
              swarmFetch(`/api/metrics/history?metric=${m.key}&hours=24`).catch(() => ({ points: [] })),
              swarmFetch(`/api/metrics/anomalies?metric=${m.key}&hours=24`).catch(() => ({ anomalies: [] })),
            ])
          ));
          const container = document.getElementById("intel-trends");
          container.innerHTML = results.map(([hist, anom], i) =>
            renderTrendChart(hist.points, TREND_METRICS[i].label, TREND_METRICS[i].color, anom.anomalies)).join("");
          wireTrendHover(container);
          const anomalyCount = results.reduce((sum, [, anom]) => sum + (anom.anomalies || []).length, 0);
          document.getElementById("intel-anomaly-banner").innerHTML = anomalyCount
            ? `<div class="notice notice-error">${anomalyCount} anomal${anomalyCount === 1 ? "y" : "ies"} flagged in the last 24h — points marked on the trend charts above deviate sharply from the window average.</div>`
            : "";
        } catch { /* ignore */ }
      }
      async function loadIntel() {
        try {
          const [metricsRes, stability, events] = await Promise.all([
            swarmFetch("/api/metrics"), swarmFetch("/api/stability"), swarmFetch("/api/events?limit=80"),
          ]);
          document.getElementById("intel-metrics").innerHTML = '<pre class="json-panel">' + JSON.stringify(metricsRes, null, 2).replace(/</g, "&lt;") + "</pre>";
          document.getElementById("intel-stability").innerHTML = '<pre class="json-panel">' + JSON.stringify(stability, null, 2).replace(/</g, "&lt;") + "</pre>";
          // .event/-error/-warning had full CSS (severity-tinted card
          // borders) but the events feed was rendered as a bare 3-column
          // table with no description column at all -- description (the
          // actually useful part of each event) was silently dropped.
          const cards = (events.events || []).map((e) => {
            const level = (e.level || "info").toLowerCase();
            const cls = level === "error" ? "event-error" : level === "warning" ? "event-warning" : "";
            return `<div class="event ${cls}">
              <div><strong>${(e.title || e.type || "Event").replace(/</g, "&lt;")}</strong><span>${e.timestamp || ""}</span></div>
              <p>${(e.description || "").replace(/</g, "&lt;")}</p>
              <div><small>${(e.source || "").replace(/</g, "&lt;")}</small><small>${level}</small></div>
            </div>`;
          }).join("");
          document.getElementById("intel-events").innerHTML = cards || '<div class="empty-state">No events.</div>';
        } catch (err) { swarmToast("Failed to load intel.", "error"); }
      }
      swarmLiveRefresh(loadIntel, 5000);
      loadTrends();
      swarmLiveRefresh(loadTrends, 60000);
    ]=]
    return page_shell(req, a, "/intel", "Intel", body, script)
  end)

  -- -----------------------------------------------------------------
  -- Audit Log (admin or moderator)
  -- -----------------------------------------------------------------
  httpd.route("GET", "/audit-log", function(req)
    local a, status, headers = cfg.require_auth_page(req)
    if not a then return status, "", headers end
    if not (a.admin_mode or a.moderator) then return denied(req, a, "/audit-log", "Audit Log") end
    local body = html.page({
      title = "Audit Log", eyebrow = "Admin", lede = "Every recorded admin action.",
      body = '<div id="audit-rows">' .. html.empty_state("Loading...") .. "</div>",
    })
    local script = ([[
      const canRevert = %s;
      async function loadAudit() {
        try {
          const res = await swarmFetch("/api/audit-log?limit=200");
          document.getElementById("audit-rows").innerHTML = ((res.data && res.data.entries) || []).map((e) => {
            let diff = "";
            try {
              const d = JSON.parse(e.details || "{}");
              if (d && typeof d === "object" && (d.before || d.after)) {
                const keys = Array.from(new Set([...Object.keys(d.before || {}), ...Object.keys(d.after || {})])).sort();
                diff = keys.length ? `<div class="audit-diff">${keys.map((k) => `
                  <div class="audit-diff-row">
                    <code>${k.replace(/</g, "&lt;")}</code>
                    <span class="audit-diff-before">${JSON.stringify((d.before || {})[k])}</span>
                    <span class="audit-diff-arrow">&rarr;</span>
                    <span class="audit-diff-after">${JSON.stringify((d.after || {})[k])}</span>
                  </div>`).join("")}</div>` : "";
              } else {
                diff = `<pre class="json-panel">${JSON.stringify(d, null, 2).replace(/</g, "&lt;")}</pre>`;
              }
            } catch { diff = (e.details || "").replace(/</g, "&lt;"); }
            return `<div class="audit-row">
              <strong>${(e.action||"").replace(/</g,"&lt;")}</strong> by ${(e.actor_username||"").replace(/</g,"&lt;")} at ${e.created_at||""}
              ${diff}
              ${canRevert ? `<button data-revert="${e.id}">Revert</button>` : ""}
            </div>`;
          }).join("") || "<p>No audit entries.</p>";
        } catch (err) { swarmToast("Failed to load audit log.", "error"); }
      }
      document.getElementById("audit-rows").addEventListener("click", async (e) => {
        const id = e.target.getAttribute("data-revert");
        if (!id) return;
        if (!confirm("Revert this action?")) return;
        try { await swarmFetch(`/api/audit-log/${id}/revert`, { method: "POST" }); loadAudit(); } catch (err) { swarmToast(err.message, "error"); }
      });
      swarmLiveRefresh(loadAudit, 15000);
    ]]):format(a.site_owner and "true" or "false")
    return page_shell(req, a, "/audit-log", "Audit Log", body, script)
  end)
end

return M
