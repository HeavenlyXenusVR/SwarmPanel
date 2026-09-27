-- Admin section: Overview hub, Diagnostics, Intel, Audit Log, Accounts,
-- Databases, Gallery Admin, Lumisound Admin. Access rules per screen match
-- nav.lua's `when` gates; a screen the session can't use renders the
-- shared access-denied page inside the normal shell.
local httpd = require("httpd")
local html = require("html")
local accounts = require("accounts")
local kit = require("page_kit")
local nav = require("nav")

local M = {}

function M.register(cfg)
  local session_view, page_shell, denied = kit.session_view, kit.page_shell, kit.denied

  -- -----------------------------------------------------------------
  -- Admin overview: one landing screen listing every admin tool this
  -- session can use, generated from nav.lua so it can't drift from the
  -- sidebar.
  -- -----------------------------------------------------------------
  httpd.route("GET", "/admin", function(req)
    local a, status, headers = cfg.require_auth_page(req)
    if not a then return status, "", headers end
    if not kit.allowed(a, "/admin") then
      local message = a.site_owner and "Turn Admin On in the top bar to open the admin tools."
        or "You don't have access to the admin tools."
      return denied(req, a, "/admin", "Admin", message)
    end
    local section = nav.visible_section(session_view(a), "admin")
    local cards = {}
    for _, item in ipairs(section and section.items or {}) do
      if item.to ~= "/admin" then
        cards[#cards + 1] = ([[<a class="hub-card" href="%s"><span class="hub-card-glyph" aria-hidden="true">%s</span><span class="hub-card-copy"><strong>%s</strong><small>%s</small></span></a>]]):format(
          html.esc(item.to), item.glyph, html.esc(item.label), html.esc(item.blurb or ""))
      end
    end
    -- Stat tiles are filled from GET /api/admin/overview; a tile whose
    -- stat isn't returned (e.g. open reports for a moderator) is removed.
    local tiles = {
      { key = "bots", label = "Bots online" },
      { key = "alert_rules_enabled", label = "Alert rules on" },
      { key = "audit_entries_recent", label = "Audit entries (24h)" },
      { key = "open_reports", label = "Open gallery reports" },
    }
    local tile_html = {}
    for _, t in ipairs(tiles) do
      tile_html[#tile_html + 1] = ('<div class="metric" data-stat="%s"><span class="metric-value">&mdash;</span><span class="metric-label">%s</span></div>'):format(
        html.esc(t.key), html.esc(t.label))
    end
    local body = html.page({
      title = "Overview", eyebrow = "Admin", lede = "Every admin and moderation tool you can use, in one place.",
      body = '<div class="metric-grid" id="admin-stats">' .. table.concat(tile_html, "") .. "</div>"
        .. (#cards > 0 and ('<div class="hub-grid">' .. table.concat(cards, "") .. "</div>")
        or html.empty_state("No admin tools are available to this account.")),
    })
    local script = [[
      async function loadAdminStats() {
        const res = await swarmFetch("/api/admin/overview");
        const values = {
          bots: res.bots_total != null ? `${res.bots_online} / ${res.bots_total}` : null,
          alert_rules_enabled: res.alert_rules_enabled,
          audit_entries_recent: res.audit_entries_recent,
          open_reports: res.open_reports,
        };
        document.querySelectorAll("#admin-stats [data-stat]").forEach((tile) => {
          const v = values[tile.getAttribute("data-stat")];
          if (v == null) { tile.remove(); return; }
          tile.querySelector(".metric-value").textContent = String(v);
          const warn = tile.getAttribute("data-stat") === "open_reports" ? Number(v) > 0
            : tile.getAttribute("data-stat") === "bots" ? res.bots_online < res.bots_total : false;
          tile.classList.toggle("metric-warn", warn);
        });
      }
      swarmLiveRefresh(loadAdminStats, 30000);
    ]]
    return page_shell(req, a, "/admin", "Admin", body, script)
  end)

  -- -----------------------------------------------------------------
  -- Diagnostics (admin)
  -- -----------------------------------------------------------------
  httpd.route("GET", "/diagnostics", function(req)
    local a, status, headers = cfg.require_auth_page(req)
    if not a then return status, "", headers end
    if not kit.allowed(a, "/diagnostics") then return denied(req, a, "/diagnostics", "Diagnostics", "Admin access required.") end
    local body = html.page({
      title = "Diagnostics", eyebrow = "Admin", lede = "Stability, metrics, alert rules, and exports.",
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

  -- -----------------------------------------------------------------
  -- Accounts (admin)
  -- -----------------------------------------------------------------
  httpd.route("GET", "/accounts", function(req)
    local a, status, headers = cfg.require_auth_page(req)
    if not a then return status, "", headers end
    if not kit.allowed(a, "/accounts") then return denied(req, a, "/accounts", "Accounts") end
    local body = html.page({
      title = "Accounts", eyebrow = "Admin", lede = "Recover and manage swarm accounts.",
      body = [[
        <div class="account-status-stack" id="account-status-stack"></div>
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
          const accts = (res.data && res.data.users) || [];
          window.SWARM_ACCOUNTS_BY_ID = {};
          accts.forEach((acc) => { window.SWARM_ACCOUNTS_BY_ID[acc.id] = acc; });
          const rows = accts.map((acc) => `
            <tr>
              <td class="table-cell-select"><input type="checkbox" data-select-row value="${acc.id}"></td>
              <td>${(acc.username||"").replace(/</g,"&lt;")}</td>
              <td>${acc.email_verified ? "verified" : "unverified"}</td>
              <td>${acc.panel_role||"user"}</td>
              <td>
                <div class="table-actions">
                  <button data-edit="${acc.id}">Edit</button>
                  <button data-verify="${acc.id}">Verify</button>
                  <button data-resend="${acc.id}">Resend Verify</button>
                  <button data-reset="${acc.id}">Reset PW</button>
                  <button data-mod="${acc.id}">Toggle Mod</button>
                  <button class="danger" data-delete="${acc.id}">Delete</button>
                </div>
              </td>
            </tr>
            <tr id="acct-edit-row-${acc.id}" hidden><td colspan="5"></td></tr>`).join("");
          document.getElementById("accounts-table").innerHTML = `
            <table class="data-table" id="accounts-tbl">
              <thead><tr><th><input type="checkbox" data-select-all></th><th>Username</th><th>Email</th><th>Role</th><th>Actions</th></tr></thead>
              <tbody>${rows || '<tr><td colspan="5">No accounts.</td></tr>'}</tbody>
            </table>`;
          table = document.getElementById("accounts-tbl");
          const verifiedCount = accts.filter((acc) => acc.email_verified).length;
          const modCount = accts.filter((acc) => acc.panel_role === "moderator").length;
          document.getElementById("account-status-stack").innerHTML = accts.length ? `
            <div class="notice">${accts.length} account${accts.length === 1 ? "" : "s"} shown -- ${verifiedCount} verified, ${accts.length - verifiedCount} unverified, ${modCount} moderator${modCount === 1 ? "" : "s"}.</div>
          ` : "";
        } catch (err) { swarmToast("Failed to load accounts.", "error"); }
      }
      function renderEditForm(id) {
        const row = document.getElementById("acct-edit-row-" + id);
        if (!row) return;
        if (!row.hidden) { row.hidden = true; row.firstElementChild.innerHTML = ""; return; }
        const acc = window.SWARM_ACCOUNTS_BY_ID[id] || {};
        row.hidden = false;
        row.firstElementChild.innerHTML = `
          <form class="panel form-panel" data-edit-account="${id}">
            <label class="field">Username<input type="text" name="username" value="${(acc.username||"").replace(/"/g,"&quot;")}"></label>
            <label class="field">Display name<input type="text" name="display_name" value="${(acc.display_name||"").replace(/"/g,"&quot;")}"></label>
            <label class="field">Email<input type="email" name="email" value="${(acc.email||"").replace(/"/g,"&quot;")}"></label>
            <label class="field">Guild ID<input type="text" name="guild_id" value="${(acc.guild_id||"").toString().replace(/"/g,"&quot;")}"></label>
            <label class="field">Server name<input type="text" name="server_name" value="${(acc.server_name||"").replace(/"/g,"&quot;")}"></label>
            <label class="field-inline"><input type="checkbox" name="public_profile" ${acc.public_profile ? "checked" : ""}> Public profile</label>
            <div class="actions-row">
              <button type="submit">Save</button>
              <button type="button" data-edit-cancel="${id}">Cancel</button>
            </div>
          </form>`;
      }
      document.getElementById("acct-search").addEventListener("swarm:search", (e) => loadAccounts(e.detail.query));
      loadAccounts("");
      document.getElementById("accounts-table").addEventListener("click", async (e) => {
        const t = e.target;
        if (t.hasAttribute("data-edit")) { renderEditForm(t.getAttribute("data-edit")); return; }
        if (t.hasAttribute("data-edit-cancel")) { renderEditForm(t.getAttribute("data-edit-cancel")); return; }
        try {
          if (t.hasAttribute("data-verify")) await swarmFetch("/api/swarm-accounts/email-verified", { method: "POST", body: JSON.stringify({ account_id: t.getAttribute("data-verify"), verified: true }) });
          else if (t.hasAttribute("data-resend")) {
            const res = await swarmFetch("/api/swarm-accounts/resend-verification", { method: "POST", body: JSON.stringify({ account_id: t.getAttribute("data-resend") }) });
            swarmToast(res.already_verified ? "Already verified." : (res.verification_sent ? "Verification code sent." : "Could not send verification code."), res.verification_sent || res.already_verified ? "success" : "error");
            return;
          }
          else if (t.hasAttribute("data-reset")) await swarmFetch("/api/swarm-accounts/reset-password", { method: "POST", body: JSON.stringify({ account_id: t.getAttribute("data-reset") }) });
          else if (t.hasAttribute("data-mod")) await swarmFetch("/api/swarm-accounts/moderator", { method: "POST", body: JSON.stringify({ account_id: t.getAttribute("data-mod") }) });
          else if (t.hasAttribute("data-delete")) { if (!confirm("Delete this account?")) return; await swarmFetch("/api/swarm-accounts/delete", { method: "POST", body: JSON.stringify({ account_id: t.getAttribute("data-delete") }) }); }
          else return;
          swarmToast("Done.", "success");
          loadAccounts(document.getElementById("acct-search").value);
        } catch (err) { swarmToast(err.message, "error"); }
      });
      document.getElementById("accounts-table").addEventListener("submit", async (e) => {
        const id = e.target.getAttribute("data-edit-account");
        if (!id) return;
        e.preventDefault();
        const f = e.target.elements;
        try {
          await swarmFetch("/api/swarm-accounts/update", { method: "POST", body: JSON.stringify({
            account_id: id, username: f.username.value, display_name: f.display_name.value,
            email: f.email.value, guild_id: f.guild_id.value, server_name: f.server_name.value,
            public_profile: f.public_profile.checked,
          }) });
          swarmToast("Account updated.", "success");
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
    if not kit.allowed(a, "/databases") then return denied(req, a, "/databases", "Databases") end
    local body = html.page({
      title = "Databases", eyebrow = "Admin", lede = "Browse raw schema tables.",
      body = [[
        <div class="panel form-panel">
          <label class="field">Schema<select id="db-schema"></select></label>
          <label class="field">Table<select id="db-table"></select></label>
          <div class="actions-row">
            <a id="db-csv" class="button-link" target="_blank">Export CSV</a>
            <button type="button" id="db-truncate-table-btn" class="danger">Truncate Table</button>
            <button type="button" id="db-truncate-schema-btn" class="danger">Truncate Schema</button>
          </div>
        </div>
        <div id="db-truncate-form"></div>
        <div id="db-data"></div>
      ]],
    })
    -- Truncate Table/Schema previously had a full, double-confirmation-gated
    -- backend (POST /api/database/truncate-table|schema, already used by the
    -- iOS app's Database Viewer) with zero web UI reaching it at all.
    -- Mirrors the same two-phrase confirmation the app requires exactly
    -- (routes.lua's literal "TRUNCATE schema.table" / "TRUNCATE ALL schema"
    -- text, plus an optional server-configured owner phrase).
    local script = [[
      function renderTruncateForm(kind) {
        const schema = document.getElementById("db-schema").value;
        const table = document.getElementById("db-table").value;
        const box = document.getElementById("db-truncate-form");
        if (!schema || (kind === "table" && !table)) { box.innerHTML = ""; return; }
        const expected = kind === "table" ? `TRUNCATE ${schema}.${table}` : `TRUNCATE ALL ${schema}`;
        box.innerHTML = `
          <form class="panel form-panel" data-truncate-kind="${kind}">
            <div class="notice notice-error">This permanently deletes ${kind === "table" ? `every row in ${schema}.${table}` : `every table in the ${schema} schema`}. This cannot be undone.</div>
            <label class="field">Type exactly: <code>${expected}</code><input type="text" name="confirm_text" required autocomplete="off"></label>
            <label class="field">Owner confirmation phrase (if one is configured on this server)<input type="text" name="owner_confirm_text" autocomplete="off"></label>
            <div class="actions-row">
              <button type="submit" class="danger">Confirm Truncate</button>
              <button type="button" id="db-truncate-cancel">Cancel</button>
            </div>
          </form>`;
      }
      document.getElementById("db-truncate-table-btn").addEventListener("click", () => renderTruncateForm("table"));
      document.getElementById("db-truncate-schema-btn").addEventListener("click", () => renderTruncateForm("schema"));
      document.getElementById("db-truncate-form").addEventListener("click", (e) => {
        if (e.target.id === "db-truncate-cancel") document.getElementById("db-truncate-form").innerHTML = "";
      });
      document.getElementById("db-truncate-form").addEventListener("submit", async (e) => {
        e.preventDefault();
        const kind = e.target.getAttribute("data-truncate-kind");
        const schema = document.getElementById("db-schema").value;
        const table = document.getElementById("db-table").value;
        const confirmText = e.target.elements.confirm_text.value;
        const ownerConfirmText = e.target.elements.owner_confirm_text.value;
        try {
          const path = kind === "table" ? "/api/database/truncate-table" : "/api/database/truncate-schema";
          const body = kind === "table"
            ? { schema_name: schema, table_name: table, confirm_text: confirmText, owner_confirm_text: ownerConfirmText }
            : { schema_name: schema, confirm_text: confirmText, owner_confirm_text: ownerConfirmText };
          const res = await swarmFetch(path, { method: "POST", body: JSON.stringify(body) });
          swarmToast(res.message || "Truncated.", "success");
          document.getElementById("db-truncate-form").innerHTML = "";
          loadTableData();
        } catch (err) { swarmToast(err.message, "error"); }
      });
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
    if not kit.allowed(a, "/gallery-admin") then return denied(req, a, "/gallery-admin", "Gallery") end
    local body = html.page({
      title = "Gallery", eyebrow = "Admin", lede = "Image Gallery users, media, comments, and reports.",
      body = [[
        <div class="loading-section is-loading" id="gallery-loading-section">
          <div class="loading-section-content">
            <div id="gallery-summary"></div>
            <div class="panel form-panel">
              <label class="field">Table<select id="gallery-table"></select></label>
              <div class="actions-row">
                <a id="gallery-csv-media" class="button-link" href="/api/image-gallery/admin/media/export.csv" target="_blank">Export Media CSV</a>
                <a id="gallery-csv-users" class="button-link" href="/api/image-gallery/admin/users/export.csv" target="_blank">Export Users CSV</a>
              </div>
            </div>
            <div id="gallery-bulk-actions" class="bulk-actions-bar" data-bulk-actions hidden>
              <button type="button" id="gallery-bulk-delete" class="danger">Delete selected</button>
            </div>
            <div id="gallery-data">]] .. html.skeleton_grid(4) .. [[</div>
          </div>
          <dialog id="gallery-user-dialog" class="panel manage-dialog">
            <form method="dialog" id="gallery-user-form">
              <div class="section-head"><h2 id="gallery-user-title">Manage user</h2><button type="submit" value="cancel" class="icon-button" aria-label="Close">&times;</button></div>
              <label class="field">Username<input name="username" autocomplete="off"></label>
              <label class="field">Display name<input name="display_name" autocomplete="off"></label>
              <label class="field">Email<input name="email" type="email" autocomplete="off"></label>
              <label class="check-field"><input type="checkbox" name="public_profile"> Public profile</label>
              <div class="actions-row"><button type="button" class="button-link primary" data-gu="save">Save details</button></div>
              <div class="manage-dialog-status" id="gallery-user-status"></div>
              <div class="actions-row">
                <button type="button" data-gu="email-verified"></button>
                <button type="button" data-gu="age-verified"></button>
                <button type="button" data-gu="resend">Resend verification email</button>
              </div>
              <label class="field">New password<input name="new_password" type="password" autocomplete="new-password" minlength="8"></label>
              <div class="actions-row"><button type="button" class="danger" data-gu="reset-password">Reset password</button></div>
            </form>
          </dialog>
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
      const GALLERY_STATUSES = ["open", "reviewed", "dismissed"];
      let galleryRows = [];

      // Per-user management (users table): edit details, flip email/age
      // verification, resend the verification email, reset the password --
      // the same /api/image-gallery/users/* endpoints the iOS app's
      // Gallery moderation screen uses.
      const userDialog = document.getElementById("gallery-user-dialog");
      const userForm = document.getElementById("gallery-user-form");
      let managedUser = null;
      function renderManagedUser() {
        const u = managedUser;
        document.getElementById("gallery-user-title").textContent = `Manage ${u.username || "user " + u.id}`;
        userForm.username.value = u.username || "";
        userForm.display_name.value = u.display_name || "";
        userForm.email.value = u.email || "";
        userForm.public_profile.checked = u.public_profile === true || u.public_profile === 1 || u.public_profile === "t";
        userForm.new_password.value = "";
        const emailOk = !!u.email_verified_at, ageOk = !!u.age_verified_at;
        document.getElementById("gallery-user-status").innerHTML =
          `<span class="data-pill ${emailOk ? "data-pill-live" : "data-pill-off"}">Email ${emailOk ? "verified" : "unverified"}</span>
           <span class="data-pill ${ageOk ? "data-pill-live" : "data-pill-off"}">Age ${ageOk ? "verified" : "unverified"}</span>`;
        userForm.querySelector('[data-gu="email-verified"]').textContent = emailOk ? "Mark email unverified" : "Mark email verified";
        userForm.querySelector('[data-gu="age-verified"]').textContent = ageOk ? "Mark age unverified" : "Mark age verified";
        userForm.querySelector('[data-gu="resend"]').disabled = emailOk || !u.email;
      }
      function openManagedUser(id) {
        managedUser = galleryRows.find((r) => String(r.id) === String(id));
        if (!managedUser || !userDialog) return;
        renderManagedUser();
        userDialog.showModal();
      }
      if (userForm) {
        userForm.addEventListener("click", async (e) => {
          const btn = e.target.closest("[data-gu]");
          if (!btn || !managedUser) return;
          const op = btn.getAttribute("data-gu");
          const id = managedUser.id;
          btn.disabled = true;
          try {
            let res;
            if (op === "save") {
              res = await swarmFetch("/api/image-gallery/users/update", { method: "POST", body: JSON.stringify({
                user_id: id, username: userForm.username.value.trim(), display_name: userForm.display_name.value.trim(),
                email: userForm.email.value.trim(), public_profile: userForm.public_profile.checked,
              }) });
              swarmToast("User updated.", "success");
            } else if (op === "email-verified" || op === "age-verified") {
              const field = op === "email-verified" ? "email_verified_at" : "age_verified_at";
              res = await swarmFetch(`/api/image-gallery/users/${op}`, { method: "POST", body: JSON.stringify({ user_id: id, verified: !managedUser[field] }) });
              swarmToast("Verification updated.", "success");
            } else if (op === "resend") {
              res = await swarmFetch("/api/image-gallery/users/resend-verification", { method: "POST", body: JSON.stringify({ user_id: id }) });
              swarmToast(res.already_verified ? "Already verified." : res.email_verification_sent ? "Verification email sent." : "Email could not be sent.", res.email_verification_sent || res.already_verified ? "success" : "error");
              res = null;
            } else if (op === "reset-password") {
              const pw = userForm.new_password.value;
              if (pw.length < 8) { swarmToast("New password must be at least 8 characters.", "error"); return; }
              if (!confirm(`Reset the password for ${managedUser.username}?`)) return;
              await swarmFetch("/api/image-gallery/users/reset-password", { method: "POST", body: JSON.stringify({ user_id: id, new_password: pw }) });
              swarmToast("Password reset.", "success");
            }
            if (res && res.user) { managedUser = Object.assign({}, managedUser, res.user); renderManagedUser(); }
            loadGalleryTable();
          } catch (err) {
            swarmToast(err.message, "error");
          } finally {
            btn.disabled = false;
            if (managedUser) renderManagedUser();
          }
        });
      }
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
          const isReports = table === "media_reports";
          const thead = (deletable ? '<th><input type="checkbox" data-select-all></th>' : "") + cols.map((c) => `<th>${c}</th>`).join("") + (deletable || isReports ? "<th>Actions</th>" : "");
          const tbody = rows.map((r) => "<tr>"
            + (deletable ? `<td class="table-cell-select"><input type="checkbox" data-select-row value="${r.id}"></td>` : "")
            + cols.map((c) => swarmTableCell(c, r[c])).join("")
            + (deletable ? `<td class="table-actions">${table === "users" ? `<button type="button" data-gallery-manage="${swarmEsc(r.id)}">Manage</button>` : ""}<button type="button" data-gallery-delete-row="${swarmEsc(r.id)}">Delete</button></td>` : "")
            + (isReports ? `<td class="table-actions">
                <select data-report-status="${r.id}">${GALLERY_STATUSES.map((s) => `<option value="${s}" ${s === r.status ? "selected" : ""}>${s}</option>`).join("")}</select>
                <button type="button" data-report-save="${r.id}">Save</button>
              </td>` : "")
            + "</tr>").join("");
          galleryRows = rows;
          document.getElementById("gallery-data").innerHTML = `<table class="data-table" id="gallery-table-el"><thead><tr>${thead}</tr></thead><tbody>${tbody}</tbody></table>`;
        } catch (err) { swarmToast("Failed to load table.", "error"); }
      }
      document.getElementById("gallery-table").addEventListener("change", loadGalleryTable);
      document.getElementById("gallery-data").addEventListener("click", async (e) => {
        const manageId = e.target.getAttribute("data-gallery-manage");
        if (manageId) { openManagedUser(manageId); return; }
        const deleteId = e.target.getAttribute("data-gallery-delete-row");
        const saveId = e.target.getAttribute("data-report-save");
        if (saveId) {
          const status = document.querySelector(`[data-report-status="${saveId}"]`).value;
          try {
            await swarmFetch("/api/image-gallery/reports/status", { method: "POST", body: JSON.stringify({ report_id: saveId, status }) });
            swarmToast("Report updated.", "success");
            loadGalleryTable();
          } catch (err) { swarmToast(err.message, "error"); }
          return;
        }
        if (!deleteId) return;
        const cfg = currentGalleryDeleteConfig();
        if (!cfg || !confirm("Delete this row? This cannot be undone.")) return;
        try {
          await swarmFetch(cfg.single, { method: "POST", body: JSON.stringify({ [cfg.idKey]: deleteId }) });
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
    return page_shell(req, a, "/gallery-admin", "Gallery", body, script)
  end)

  -- -----------------------------------------------------------------
  -- Lumisound Admin (admin or moderator)
  -- -----------------------------------------------------------------
  httpd.route("GET", "/lumisound-admin", function(req)
    local a, status, headers = cfg.require_auth_page(req)
    if not a then return status, "", headers end
    if not kit.allowed(a, "/lumisound-admin") then return denied(req, a, "/lumisound-admin", "Lumisound") end
    -- Full port of LumisoundAdminPage.jsx (150 lines: metric grid + 6 live
    -- data tables with real admin actions) -- the first Lua pass just
    -- JSON.stringify()'d the whole /api/lumisound/admin response into a
    -- <pre>, which lost every admin action (suspend/reinstate users,
    -- delete uploads, resolve/reopen bug reports all already existed as
    -- working API endpoints -- routes.lua's /api/lumisound/users/active,
    -- /api/lumisound/uploads/delete, /api/lumisound/bug-reports/status --
    -- just with no UI left to call them from).
    local body = html.page({
      title = "Lumisound", eyebrow = "Admin", lede = "Account, library, and activity data for the Lumisound iOS app.",
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
          // Instant feedback rather than waiting for the next live-push
          // tick (up to 15s away) -- same pattern as Controls/Friends.
          swarmFetch("/api/lumisound/admin").then(applyLumisound).catch(() => {});
        } catch (err) { swarmToast(err.message, "error"); }
      }
      function applyLumisound(res) {
        try {
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
      window.swarmLive.watch("lumisound_admin", (msg) => {
        if (msg.type === "snapshot_error") { swarmToast("Failed to load Lumisound data.", "error"); return; }
        if (msg.type === "snapshot") applyLumisound(msg.data);
      });
    ]=]
    return page_shell(req, a, "/lumisound-admin", "Lumisound", body, script)
  end)

  -- -----------------------------------------------------------------
  -- Intel (admin)
  -- -----------------------------------------------------------------
  httpd.route("GET", "/intel", function(req)
    local a, status, headers = cfg.require_auth_page(req)
    if not a then return status, "", headers end
    if not kit.allowed(a, "/intel") then return denied(req, a, "/intel", "Intel") end
    -- Ports IntelPage.jsx's 24h TrendChart section (SVG line chart + area
    -- fill + anomaly markers + hover tooltip) -- the first Lua pass never
    -- called /api/metrics/history or /api/metrics/anomalies at all, and
    -- (separately) swarm_metrics_history had stopped receiving new rows
    -- the moment the Python app -- the only thing that ever wrote to it --
    -- was retired. Both are fixed now: main.lua runs a copas thread that
    -- samples fleet totals into that table every 5 minutes (see
    -- metrics.capture_metrics_snapshot), and this page actually reads it.
    local body = html.page({
      title = "Intel", eyebrow = "Admin", lede = "Errors, trends, anomalies, and raw events.",
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
      function applyTrends(out) {
        const container = document.getElementById("intel-trends");
        container.innerHTML = TREND_METRICS.map((m) => {
          const t = out[m.key] || { points: [], anomalies: [] };
          return renderTrendChart(t.points, m.label, m.color, t.anomalies);
        }).join("");
        wireTrendHover(container);
        const anomalyCount = TREND_METRICS.reduce((sum, m) => sum + ((out[m.key] || {}).anomalies || []).length, 0);
        document.getElementById("intel-anomaly-banner").innerHTML = anomalyCount
          ? `<div class="notice notice-error">${anomalyCount} anomal${anomalyCount === 1 ? "y" : "ies"} flagged in the last 24h — points marked on the trend charts above deviate sharply from the window average.</div>`
          : "";
      }
      window.swarmLive.watch("trends", (msg) => {
        if (msg.type === "snapshot") applyTrends(msg.data);
      });
      function applyIntelMetrics(metricsRes) {
        document.getElementById("intel-metrics").innerHTML = '<pre class="json-panel">' + JSON.stringify(metricsRes, null, 2).replace(/</g, "&lt;") + "</pre>";
      }
      function applyIntelStability(stability) {
        document.getElementById("intel-stability").innerHTML = '<pre class="json-panel">' + JSON.stringify(stability, null, 2).replace(/</g, "&lt;") + "</pre>";
      }
      function applyIntelEvents(events) {
        // .event/-error/-warning had full CSS (severity-tinted card
        // borders) but the events feed was rendered as a bare 3-column
        // table with no description column at all -- description (the
        // actually useful part of each event) was silently dropped.
        const cards = (events.events || []).map(swarmEventCard).join("");
        document.getElementById("intel-events").innerHTML = cards || '<div class="empty-state">No events.</div>';
      }
      window.swarmLive.watch("metrics_snapshot", (msg) => {
        if (msg.type === "snapshot_error") { swarmToast("Failed to load intel.", "error"); return; }
        if (msg.type === "snapshot") applyIntelMetrics(msg.data);
      });
      window.swarmLive.watch("stability", (msg) => {
        if (msg.type === "snapshot") applyIntelStability(msg.data);
      });
      window.swarmLive.watch("events", (msg) => {
        if (msg.type === "snapshot") applyIntelEvents(msg.data);
      });
    ]=]
    return page_shell(req, a, "/intel", "Intel", body, script)
  end)

  -- -----------------------------------------------------------------
  -- Audit Log (admin or moderator)
  -- -----------------------------------------------------------------
  httpd.route("GET", "/audit-log", function(req)
    local a, status, headers = cfg.require_auth_page(req)
    if not a then return status, "", headers end
    if not kit.allowed(a, "/audit-log") then return denied(req, a, "/audit-log", "Audit Log") end
    local body = html.page({
      title = "Audit Log", eyebrow = "Admin", lede = "Every recorded admin action.",
      body = '<div id="audit-rows">' .. html.empty_state("Loading...") .. "</div>",
    })
    local script = ([[
      const canRevert = %s;
      function applyAudit(res) {
        try {
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
        try {
          await swarmFetch(`/api/audit-log/${id}/revert`, { method: "POST" });
          swarmFetch("/api/audit-log?limit=200").then(applyAudit).catch(() => {});
        } catch (err) { swarmToast(err.message, "error"); }
      });
      window.swarmLive.watch("audit_log", (msg) => {
        if (msg.type === "snapshot_error") { swarmToast("Failed to load audit log.", "error"); return; }
        if (msg.type === "snapshot") applyAudit(msg.data);
      });
    ]]):format(a.site_owner and "true" or "false")
    return page_shell(req, a, "/audit-log", "Audit Log", body, script)
  end)
end

return M
