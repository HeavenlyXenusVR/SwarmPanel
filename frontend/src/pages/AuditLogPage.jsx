import { useCallback, useEffect, useState } from "react";
import { RefreshCw, RotateCcw, Search } from "lucide-react";
import { apiFetch, query } from "../api.js";
import { useLiveRefresh } from "../hooks/useLiveRefresh.js";
import { EmptyState, Notice, Page, SectionHead, SkeletonGrid } from "../components/ui.jsx";
import { formatRelativeTime, formatTime } from "../utils/format.js";

const REVERTIBLE_ACTIONS = new Set(["alert_rule_update", "swarm_account_update"]);

function parseDiff(details) {
  if (!details) return null;
  try {
    const parsed = JSON.parse(details);
    if (parsed && typeof parsed === "object" && parsed.before && parsed.after) return parsed;
  } catch {
    return null;
  }
  return null;
}

function DetailsCell({ details }) {
  const diff = parseDiff(details);
  if (!diff) return details ? <>{details}</> : <span className="muted">-</span>;
  const keys = Array.from(new Set([...Object.keys(diff.before), ...Object.keys(diff.after)]));
  return (
    <div className="audit-diff">
      {keys.map((key) => (
        <div key={key} className="audit-diff-row">
          <code>{key}</code>
          <span className="audit-diff-before">{String(diff.before[key] ?? "—")}</span>
          <span className="audit-diff-arrow">→</span>
          <span className="audit-diff-after">{String(diff.after[key] ?? "—")}</span>
        </div>
      ))}
    </div>
  );
}

export default function AuditLogPage({ ctx }) {
  const [entries, setEntries] = useState([]);
  const [total, setTotal] = useState(0);
  const [actionFilter, setActionFilter] = useState("");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [revertingId, setRevertingId] = useState(null);
  const showToast = ctx.showToast;

  const load = useCallback(async ({ background = false, force = false } = {}) => {
    try {
      if (!background) setLoading(true);
      const result = await apiFetch(`/api/audit-log${query({ limit: 200, action: actionFilter })}`, { force });
      setEntries(result.data?.entries || []);
      setTotal(result.data?.total || 0);
      setError("");
    } catch (loadError) {
      setError(loadError.message);
      if (!background) showToast(loadError.message, "error");
    } finally {
      if (!background) setLoading(false);
    }
  }, [actionFilter, showToast]);

  useEffect(() => { load(); }, [load]);
  useLiveRefresh(() => load({ background: true, force: true }), { interval: 15_000 });

  async function revertEntry(entry) {
    if (!window.confirm(`Revert "${entry.action}" back to its prior values?`)) return;
    setRevertingId(entry.id);
    try {
      await apiFetch(`/api/audit-log/${entry.id}/revert`, { method: "POST" });
      showToast("Reverted.", "success");
      await load({ force: true });
    } catch (revertError) {
      showToast(revertError.message, "error");
    } finally {
      setRevertingId(null);
    }
  }

  const actionOptions = Array.from(new Set(entries.map((entry) => entry.action))).sort();

  return (
    <Page
      title="Audit Log"
      eyebrow="Admin Trail"
      lede="Every destructive or administrative action taken through the panel, newest first."
      actions={<button type="button" onClick={() => load({ force: true })}><RefreshCw size={16} />Refresh</button>}
    >
      {error ? <Notice tone="error">{error}</Notice> : null}
      <div className="toolbar">
        <div className="search-box">
          <Search size={16} />
          <input
            value={actionFilter}
            onChange={(event) => setActionFilter(event.target.value)}
            placeholder="Filter by exact action (e.g. truncate_table)"
            list="audit-log-actions"
          />
          <datalist id="audit-log-actions">
            {actionOptions.map((action) => <option key={action} value={action} />)}
          </datalist>
        </div>
        {actionFilter ? <button type="button" onClick={() => setActionFilter("")}>Clear</button> : null}
      </div>
      <SectionHead title="Entries" count={total || entries.length} />
      {loading ? <SkeletonGrid count={4} /> : entries.length ? (
        <div className="table-wrap">
          <table className="data-table">
            <thead>
              <tr>
                <th>When</th>
                <th>Actor</th>
                <th>Action</th>
                <th>Target</th>
                <th>Details</th>
                {ctx.isOwner ? <th>Revert</th> : null}
              </tr>
            </thead>
            <tbody>
              {entries.map((entry) => (
                <tr key={entry.id}>
                  <td><time className="table-mono" title={formatTime(entry.created_at)}>{formatRelativeTime(entry.created_at)}</time></td>
                  <td>{entry.actor_username || "unknown"}</td>
                  <td><span className="data-pill data-pill-soft">{entry.action}</span></td>
                  <td>{entry.target_type ? <code className="table-mono">{entry.target_type}:{entry.target_id}</code> : <span className="muted">-</span>}</td>
                  <td className="table-cell-wide"><DetailsCell details={entry.details} /></td>
                  {ctx.isOwner ? (
                    <td className="table-actions">
                      {REVERTIBLE_ACTIONS.has(entry.action) ? (
                        <button type="button" disabled={revertingId === entry.id} onClick={() => revertEntry(entry)}>
                          <RotateCcw size={14} />{revertingId === entry.id ? "Reverting" : "Revert"}
                        </button>
                      ) : null}
                    </td>
                  ) : null}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : (
        <EmptyState title="No audit log entries yet" compact />
      )}
    </Page>
  );
}
