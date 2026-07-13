import { useCallback, useEffect, useState } from "react";
import { Activity, KeyRound, ListMusic, RefreshCw, Search, Shield, ShieldAlert, ShieldCheck, Trash2, Webhook } from "lucide-react";
import { apiFetch, query } from "../api.js";
import { useLiveRefresh } from "../hooks/useLiveRefresh.js";
import { DataTable } from "../components/swarm.jsx";
import { Metric, MetricGrid, Page, SectionHead, SkeletonGrid } from "../components/ui.jsx";

export default function AccountsPage({ ctx }) {
  const [q, setQ] = useState("");
  const [rows, setRows] = useState([]);
  const [stability, setStability] = useState(null);
  const [metrics, setMetrics] = useState(null);
  const [loading, setLoading] = useState(true);
  const [passwords, setPasswords] = useState({});
  const [selectedIds, setSelectedIds] = useState(() => new Set());
  const [bulkBusy, setBulkBusy] = useState("");
  const showToast = ctx.showToast;
  const load = useCallback(async ({ background = false, force = false } = {}) => {
    try {
      if (!background) setLoading(true);
      const [accounts, stabilityData, metricsData] = await Promise.allSettled([
        apiFetch(`/api/swarm-accounts/admin${query({ query: q, limit: 100 })}`, { force }),
        apiFetch("/api/stability", { force }),
        apiFetch("/api/metrics", { force }),
      ]);
      if (accounts.status === "fulfilled") setRows(accounts.value.data?.accounts || accounts.value.data || []);
      if (stabilityData.status === "fulfilled") setStability(stabilityData.value);
      if (metricsData.status === "fulfilled") setMetrics(metricsData.value);
    } catch (error) {
      if (!background) showToast(error.message, "error");
    } finally {
      if (!background) setLoading(false);
    }
  }, [showToast, q]);
  useEffect(() => { load(); }, [load]);
  useLiveRefresh(() => load({ background: true, force: true }), { interval: 5_000 });
  async function mutate(path, payload, message) {
    try {
      await apiFetch(path, { method: "POST", body: JSON.stringify(payload) });
      showToast(message, "success");
      await load();
    } catch (error) {
      showToast(error.message, "error");
    }
  }

  function onToggleRow(id, checked) {
    setSelectedIds((current) => {
      const next = new Set(current);
      if (checked) next.add(id); else next.delete(id);
      return next;
    });
  }
  function onToggleAll(checked) {
    setSelectedIds(checked ? new Set(rows.map((row) => row.id)) : new Set());
  }

  async function bulkAction(kind, path, extraPayload, successVerb) {
    const ids = Array.from(selectedIds);
    if (!ids.length) return;
    if (kind === "delete" && !window.confirm(`Delete ${ids.length} selected account(s)? This cannot be undone.`)) return;
    setBulkBusy(kind);
    try {
      const result = await apiFetch(path, { method: "POST", body: JSON.stringify({ ids, ...extraPayload }) });
      const failedCount = result.failed?.length || 0;
      showToast(
        failedCount ? `${successVerb} ${result.succeeded.length}, ${failedCount} failed.` : `${successVerb} ${result.succeeded.length} account(s).`,
        failedCount ? "error" : "success",
      );
      setSelectedIds(new Set());
      await load({ force: true });
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      setBulkBusy("");
    }
  }

  return (
    <Page title="SwarmPanel Recovery" eyebrow="Accounts" actions={<button type="button" onClick={() => load({ force: true })}><RefreshCw size={16} />Refresh</button>}>
      <MetricGrid>
        <Metric icon={Activity} label="Metric Bots" value={metrics?.totals?.bots || 0} />
        <Metric icon={ListMusic} label="Live Queue" value={metrics?.totals?.queued_tracks || 0} />
        <Metric icon={ListMusic} label="Backup Queue" value={metrics?.totals?.backup_tracks || 0} />
        <Metric icon={ShieldAlert} label="Recovery Cooldowns" value={stability?.cooldowns?.length || 0} />
      </MetricGrid>
      {loading ? <SkeletonGrid count={4} /> : (
        <section className="dashboard-grid">
          <div className="panel wide">
            <SectionHead title="Recovery Metrics" count={metrics?.bots?.length || 0} />
            <DataTable rows={(metrics?.bots || []).map((bot) => ({
              bot: bot.display_name || bot.key,
              status: bot.status,
              guilds: bot.metrics?.length || 0,
              queue: (bot.metrics || []).reduce((sum, row) => sum + Number(row.queue_count || 0), 0),
              backup: (bot.metrics || []).reduce((sum, row) => sum + Number(row.backup_queue_count || 0), 0),
              recovering: (bot.metrics || []).filter((row) => row.recovery_pending).length,
              stale: (bot.metrics || []).filter((row) => row.stale).length,
            }))} />
          </div>
          <div className="panel">
            <SectionHead title="Cooldowns" count={stability?.cooldowns?.length || 0} />
            <DataTable rows={stability?.cooldowns || []} />
          </div>
          <div className="panel wide">
            <SectionHead title="Recent Repairs" count={stability?.recent_repairs?.length || 0} />
            <DataTable rows={stability?.recent_repairs || []} />
          </div>
        </section>
      )}
      <div className="toolbar"><div className="search-box"><Search size={16} /><input value={q} onChange={(event) => setQ(event.target.value)} placeholder="Search accounts" /></div></div>
      {selectedIds.size ? (
        <div className="bulk-actions-bar">
          <strong>{selectedIds.size}</strong>
          <span>account{selectedIds.size === 1 ? "" : "s"} selected</span>
          <button type="button" disabled={Boolean(bulkBusy)} onClick={() => bulkAction("verify", "/api/swarm-accounts/bulk-verify", { verified: true }, "Verified")}>
            <ShieldCheck size={14} />{bulkBusy === "verify" ? "Verifying..." : "Verify Selected"}
          </button>
          <button className="danger" type="button" disabled={Boolean(bulkBusy)} onClick={() => bulkAction("delete", "/api/swarm-accounts/bulk-delete", {}, "Deleted")}>
            <Trash2 size={14} />{bulkBusy === "delete" ? "Deleting..." : "Delete Selected"}
          </button>
        </div>
      ) : null}
      <DataTable
        rows={rows}
        selectable
        selectedIds={selectedIds}
        onToggleRow={onToggleRow}
        onToggleAll={onToggleAll}
        actions={(row) => (
          <div className="table-actions">
            <button type="button" onClick={() => mutate("/api/swarm-accounts/email-verified", { account_id: row.id, verified: !row.verification_verified }, "Verification flag updated.")}><ShieldCheck size={14} />Verify</button>
            <input className="mini-input" type="password" placeholder="new password" value={passwords[row.id] || ""} onChange={(event) => setPasswords((current) => ({ ...current, [row.id]: event.target.value }))} />
            <button type="button" disabled={!String(passwords[row.id] || "").trim()} onClick={() => mutate("/api/swarm-accounts/reset-password", { account_id: row.id, new_password: passwords[row.id] || "" }, "Password reset.")}><KeyRound size={14} />Reset</button>
            <button type="button" disabled={!row.verification_webhook_configured} onClick={() => mutate("/api/swarm-accounts/resend-verification", { account_id: row.id }, "Verification code sent.")}><Webhook size={14} />Code</button>
            {ctx.isOwner ? (
              <button
                type="button"
                onClick={() => mutate(
                  "/api/swarm-accounts/moderator",
                  { account_id: row.id, moderator: row.panel_role !== "moderator" },
                  row.panel_role === "moderator" ? "Moderator access revoked." : "Moderator access granted.",
                )}
              >
                <Shield size={14} />{row.panel_role === "moderator" ? "Revoke Mod" : "Make Mod"}
              </button>
            ) : null}
            <button className="danger" type="button" onClick={() => mutate("/api/swarm-accounts/delete", { account_id: row.id }, "Account deleted.")}><Trash2 size={14} />Delete</button>
          </div>
        )}
      />
    </Page>
  );
}
