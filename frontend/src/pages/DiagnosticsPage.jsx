import { useCallback, useEffect, useState } from "react";
import { Plus, RefreshCw, Trash2 } from "lucide-react";
import { apiFetch, query } from "../api.js";
import { useLiveRefresh } from "../hooks/useLiveRefresh.js";
import { JsonPanel } from "../components/swarm.jsx";
import { EmptyState, LoadingSection, Notice, Page, SectionHead } from "../components/ui.jsx";
import { titleCase } from "../utils/format.js";

const ALERT_RULE_TYPES = [
  { value: "bot_offline", label: "Bot Offline" },
  { value: "queue_stuck", label: "Queue Stuck" },
  { value: "stale_metrics", label: "Stale Metrics" },
  { value: "recovery_pending", label: "Recovery Pending" },
];

function AlertRulesPanel({ ctx }) {
  const [rules, setRules] = useState([]);
  const [loading, setLoading] = useState(true);
  const [ruleType, setRuleType] = useState(ALERT_RULE_TYPES[0].value);
  const [thresholdMinutes, setThresholdMinutes] = useState(5);
  const [saving, setSaving] = useState(false);
  const showToast = ctx.showToast;

  const load = useCallback(async ({ background = false, force = false } = {}) => {
    try {
      if (!background) setLoading(true);
      const result = await apiFetch("/api/alert-rules", { force });
      setRules(result.rules || []);
    } catch (error) {
      if (!background) showToast(error.message, "error");
    } finally {
      if (!background) setLoading(false);
    }
  }, [showToast]);
  useEffect(() => { load(); }, [load]);
  useLiveRefresh(() => load({ background: true, force: true }), { interval: 30_000 });

  async function addRule(event) {
    event.preventDefault();
    setSaving(true);
    try {
      await apiFetch("/api/alert-rules", {
        method: "POST",
        body: JSON.stringify({ rule_type: ruleType, threshold_minutes: Number(thresholdMinutes) || 5, enabled: true }),
      });
      showToast("Alert rule created.", "success");
      await load({ force: true });
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      setSaving(false);
    }
  }

  async function toggleRule(rule) {
    try {
      await apiFetch(`/api/alert-rules/${rule.id}/update`, {
        method: "POST",
        body: JSON.stringify({ enabled: !rule.enabled }),
      });
      await load({ force: true });
    } catch (error) {
      showToast(error.message, "error");
    }
  }

  async function deleteRule(rule) {
    try {
      await apiFetch(`/api/alert-rules/${rule.id}/delete`, { method: "POST" });
      showToast("Alert rule deleted.", "success");
      await load({ force: true });
    } catch (error) {
      showToast(error.message, "error");
    }
  }

  return (
    <div className="panel wide">
      <SectionHead title="Alert Rules" count={rules.length} />
      <form className="toolbar" onSubmit={addRule}>
        <select value={ruleType} onChange={(event) => setRuleType(event.target.value)}>
          {ALERT_RULE_TYPES.map((type) => <option key={type.value} value={type.value}>{type.label}</option>)}
        </select>
        <input
          type="number"
          min="1"
          max="1440"
          value={thresholdMinutes}
          onChange={(event) => setThresholdMinutes(event.target.value)}
          style={{ width: 90 }}
          aria-label="Threshold minutes"
        />
        <span className="muted">min before firing</span>
        <button type="submit" disabled={saving}><Plus size={14} />Add Rule</button>
      </form>
      {loading ? null : rules.length ? (
        <div className="table-wrap">
          <table className="data-table">
            <thead><tr><th>Type</th><th>Threshold</th><th>Status</th><th>Actions</th></tr></thead>
            <tbody>
              {rules.map((rule) => (
                <tr key={rule.id}>
                  <td>{titleCase(rule.rule_type)}</td>
                  <td>{rule.threshold_minutes} min</td>
                  <td><span className={`data-pill data-pill-${rule.enabled ? "live" : "off"}`}>{rule.enabled ? "Enabled" : "Disabled"}</span></td>
                  <td className="table-actions">
                    <button type="button" onClick={() => toggleRule(rule)}>{rule.enabled ? "Disable" : "Enable"}</button>
                    <button className="danger" type="button" onClick={() => deleteRule(rule)}><Trash2 size={14} />Delete</button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : (
        <EmptyState title="No alert rules configured" compact />
      )}
    </div>
  );
}

export default function DiagnosticsPage({ ctx }) {
  const [data, setData] = useState(null);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);
  const load = useCallback(async (force = false, background = false) => {
    try {
      if (!background) setLoading(true);
      setData(await apiFetch(`/api/system-diagnostics${query({ force })}`, { force }));
      setError("");
    } catch (loadError) {
      setError(loadError.message);
    } finally {
      if (!background) setLoading(false);
    }
  }, []);
  useEffect(() => { load(false); }, [load]);
  useLiveRefresh(() => load(true, true), { interval: 5_000 });
  return (
    <Page title="System Runtime" eyebrow="Diagnostics" actions={<button type="button" onClick={() => load(true)}><RefreshCw size={16} />Force</button>}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      <section className="dashboard-grid">
        <AlertRulesPanel ctx={ctx} />
      </section>
      <LoadingSection
        loading={loading}
        title="Inspecting system runtime"
        tip="SwarmPanel is collecting live backend diagnostics, health, and runtime state."
        count={4}
        minHeight={280}
      >
        <JsonPanel data={data} />
      </LoadingSection>
    </Page>
  );
}
