import { useCallback, useEffect, useState } from "react";
import { RefreshCw, Search } from "lucide-react";
import { apiFetch, query } from "../api.js";
import { useLiveRefresh } from "../hooks/useLiveRefresh.js";
import { EmptyState, Notice, Page, SectionHead, SkeletonGrid } from "../components/ui.jsx";
import { formatRelativeTime, formatTime } from "../utils/format.js";

export default function AuditLogPage({ ctx }) {
  const [entries, setEntries] = useState([]);
  const [total, setTotal] = useState(0);
  const [actionFilter, setActionFilter] = useState("");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
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
              </tr>
            </thead>
            <tbody>
              {entries.map((entry) => (
                <tr key={entry.id}>
                  <td><time className="table-mono" title={formatTime(entry.created_at)}>{formatRelativeTime(entry.created_at)}</time></td>
                  <td>{entry.actor_username || "unknown"}</td>
                  <td><span className="data-pill data-pill-soft">{entry.action}</span></td>
                  <td>{entry.target_type ? <code className="table-mono">{entry.target_type}:{entry.target_id}</code> : <span className="muted">-</span>}</td>
                  <td className="table-cell-wide">{entry.details || <span className="muted">-</span>}</td>
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
