-- Server-rendered pages: Accounts, Databases, Gallery Admin, Lumisound
-- Admin, Intel, Audit Log. Same pattern as pages_ops.lua/pages_identity.lua.
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

  local function page_shell(req, a, path, title, body_html, extra_script)
    local script = ([[<script>%s</script>]]):format(extra_script or "")
    return 200, html.layout({
      title = title, path = path, session = session_view(a),
      token = req.cookies and req.cookies.swarm_session,
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
        <input type="search" placeholder="Search accounts..." data-debounced-search id="acct-search">
        <div id="bulk-actions" data-bulk-actions hidden>
          <button type="button" id="bulk-verify">Verify selected</button>
          <button type="button" id="bulk-delete">Delete selected</button>
        </div>
        <div id="accounts-table"></div>
      ]],
    })
    local script = [[
      let table;
      async function loadAccounts(q) {
        try {
          const res = await swarmFetch("/api/swarm-accounts/admin?query=" + encodeURIComponent(q || "") + "&limit=100");
          const rows = (res.accounts || []).map((acc) => `
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
        <div class="control-form">
          <label>Schema<select id="db-schema"></select></label>
          <label>Table<select id="db-table"></select></label>
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
          sel.innerHTML = (res.databases || []).map((d) => `<option value="${d.schema}">${d.schema}</option>`).join("");
          window.SWARM_DB_TABLES = {};
          (res.databases || []).forEach((d) => { window.SWARM_DB_TABLES[d.schema] = d.tables || []; });
          onSchemaChange();
        } catch (err) { swarmToast("Failed to load databases.", "error"); }
      }
      function onSchemaChange() {
        const schema = document.getElementById("db-schema").value;
        const tableSel = document.getElementById("db-table");
        tableSel.innerHTML = (window.SWARM_DB_TABLES[schema] || []).map((t) => `<option value="${t}">${t}</option>`).join("");
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
          const tbody = rows.map((r) => "<tr>" + cols.map((c) => `<td>${String(r[c] ?? "").replace(/</g,"&lt;")}</td>`).join("") + "</tr>").join("");
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
        <div id="gallery-summary"></div>
        <div class="control-form">
          <label>Table<select id="gallery-table"></select></label>
          <a id="gallery-csv-media" class="button-link" href="/api/image-gallery/admin/media/export.csv" target="_blank">Export Media CSV</a>
          <a id="gallery-csv-users" class="button-link" href="/api/image-gallery/admin/users/export.csv" target="_blank">Export Users CSV</a>
        </div>
        <div id="gallery-data"></div>
      ]],
    })
    local script = [[
      async function loadGallery() {
        try {
          const summary = await swarmFetch("/api/image-gallery/admin");
          document.getElementById("gallery-summary").innerHTML = '<pre class="json-panel">' + JSON.stringify(summary, null, 2).replace(/</g, "&lt;") + "</pre>";
        } catch { /* ignore */ }
        try {
          const tables = await swarmFetch("/api/image-gallery/tables");
          const sel = document.getElementById("gallery-table");
          sel.innerHTML = (tables.tables || []).map((t) => `<option value="${t}">${t}</option>`).join("");
          loadGalleryTable();
        } catch { /* ignore */ }
      }
      async function loadGalleryTable() {
        const table = document.getElementById("gallery-table").value;
        if (!table) return;
        try {
          const res = await swarmFetch(`/api/image-gallery/table-data?table_name=${table}&limit=100`);
          const rows = res.rows || [];
          if (!rows.length) { document.getElementById("gallery-data").innerHTML = "<p>No rows.</p>"; return; }
          const cols = Object.keys(rows[0]).slice(0, 9);
          const thead = cols.map((c) => `<th>${c}</th>`).join("");
          const tbody = rows.map((r) => "<tr>" + cols.map((c) => `<td>${String(r[c] ?? "").replace(/</g,"&lt;")}</td>`).join("") + "</tr>").join("");
          document.getElementById("gallery-data").innerHTML = `<table class="data-table"><thead><tr>${thead}</tr></thead><tbody>${tbody}</tbody></table>`;
        } catch (err) { swarmToast("Failed to load table.", "error"); }
      }
      document.getElementById("gallery-table").addEventListener("change", loadGalleryTable);
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
    local body = html.page({
      title = "Lumisound Admin", eyebrow = "Companion App", lede = "Users, uploads, and bug reports.",
      body = '<div id="lumisound-data">' .. html.empty_state("Loading...") .. "</div>",
    })
    local script = [[
      async function loadLumisound() {
        try {
          const res = await swarmFetch("/api/lumisound/admin");
          document.getElementById("lumisound-data").innerHTML = '<pre class="json-panel">' + JSON.stringify(res, null, 2).replace(/</g, "&lt;") + "</pre>";
        } catch (err) { swarmToast("Failed to load Lumisound data.", "error"); }
      }
      swarmLiveRefresh(loadLumisound, 15000);
    ]]
    return page_shell(req, a, "/lumisound-admin", "Lumisound Admin", body, script)
  end)

  -- -----------------------------------------------------------------
  -- Intel (admin)
  -- -----------------------------------------------------------------
  httpd.route("GET", "/intel", function(req)
    local a, status, headers = cfg.require_auth_page(req)
    if not a then return status, "", headers end
    if not a.admin_mode then return denied(req, a, "/intel", "Intel") end
    local body = html.page({
      title = "Intel", eyebrow = "Admin", lede = "Trends, anomalies, and raw events.",
      body = [[
        <div id="intel-metrics"></div>
        <h3>Recent Events</h3>
        <div id="intel-events"></div>
      ]],
    })
    local script = [[
      async function loadIntel() {
        try {
          const [metrics, stability, events] = await Promise.all([
            swarmFetch("/api/metrics"), swarmFetch("/api/stability"), swarmFetch("/api/events?limit=80"),
          ]);
          document.getElementById("intel-metrics").innerHTML =
            '<pre class="json-panel">' + JSON.stringify({ metrics, stability }, null, 2).replace(/</g, "&lt;") + "</pre>";
          const rows = (events.events || []).map((e) =>
            `<tr><td>${e.created_at||""}</td><td>${(e.event_type||"").replace(/</g,"&lt;")}</td><td>${(e.severity||"").replace(/</g,"&lt;")}</td></tr>`).join("");
          document.getElementById("intel-events").innerHTML =
            '<table class="data-table"><thead><tr><th>Time</th><th>Type</th><th>Severity</th></tr></thead><tbody>' + (rows || '<tr><td colspan="3">No events.</td></tr>') + "</tbody></table>";
        } catch (err) { swarmToast("Failed to load intel.", "error"); }
      }
      swarmLiveRefresh(loadIntel, 5000);
    ]]
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
          document.getElementById("audit-rows").innerHTML = (res.entries || []).map((e) => {
            let diff = "";
            try {
              const d = JSON.parse(e.details || "{}");
              diff = `<pre class="json-panel">before: ${JSON.stringify(d.before)}\nafter: ${JSON.stringify(d.after)}</pre>`;
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
