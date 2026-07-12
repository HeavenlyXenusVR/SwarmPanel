import { useCallback, useEffect, useState } from "react";
import { RefreshCw } from "lucide-react";
import { apiFetch, query } from "../api.js";
import { useLiveRefresh } from "../hooks/useLiveRefresh.js";
import { EventList, JsonPanel, TrendChart } from "../components/swarm.jsx";
import { LoadingSection, Notice, Page, SectionHead } from "../components/ui.jsx";

const TREND_METRICS = [
  { key: "queued_tracks", label: "Queued Tracks (24h)", color: "var(--accent)" },
  { key: "active_bots", label: "Active Bots (24h)", color: "var(--ok)" },
];

export default function IntelPage({ ctx }) {
  const [state, setState] = useState({ events: [], metrics: null, stability: null, loading: true, error: "" });
  const [trends, setTrends] = useState({});
  const load = useCallback(async ({ force = false, background = false } = {}) => {
    if (!background) setState((current) => ({ ...current, loading: true, error: "" }));
    const [events, metrics, stability] = await Promise.allSettled([
      apiFetch("/api/events?limit=80", { force }),
      apiFetch("/api/metrics", { force }),
      apiFetch("/api/stability", { force }),
    ]);
    setState({
      events: events.status === "fulfilled" ? events.value.events || [] : [],
      metrics: metrics.status === "fulfilled" ? metrics.value : { error: metrics.reason?.message },
      stability: stability.status === "fulfilled" ? stability.value : { error: stability.reason?.message },
      loading: false,
      error: events.status === "rejected" ? (events.reason?.message || "Failed to load events.") : "",
    });
  }, []);
  const loadTrends = useCallback(async ({ force = false } = {}) => {
    const results = await Promise.allSettled(
      TREND_METRICS.map((metric) => apiFetch(`/api/metrics/history${query({ metric: metric.key, hours: 24 })}`, { force }))
    );
    const next = {};
    results.forEach((result, index) => {
      next[TREND_METRICS[index].key] = result.status === "fulfilled" ? result.value.points || [] : [];
    });
    setTrends(next);
  }, []);
  useEffect(() => { load(); loadTrends(); }, [load, loadTrends]);
  useLiveRefresh(() => load({ force: true, background: true }), { interval: 5_000 });
  useLiveRefresh(() => loadTrends({ force: true }), { interval: 60_000 });
  return (
    <Page title="Errors And Metrics" eyebrow="Intel" actions={<button type="button" onClick={() => { load({ force: true }); loadTrends({ force: true }); }}><RefreshCw size={16} />Refresh</button>}>
      {state.error ? <Notice tone="error">{state.error}</Notice> : null}
      <section className="dashboard-grid">
        <div className="panel wide">
          <SectionHead title="24h Trends" />
          <div className="trend-chart-grid">
            {TREND_METRICS.map((metric) => (
              <TrendChart key={metric.key} points={trends[metric.key] || []} label={metric.label} color={metric.color} />
            ))}
          </div>
        </div>
      </section>
      <LoadingSection loading={state.loading} title="Loading intel data" tip="SwarmPanel is collecting events, metrics, and stability data." count={4} minHeight={280}>
        <section className="dashboard-grid">
          <div className="panel wide"><SectionHead title="Events" count={state.events.length} /><EventList events={state.events} /></div>
          <div className="panel"><SectionHead title="Metrics" /><JsonPanel data={state.metrics} /></div>
          <div className="panel"><SectionHead title="Stability" /><JsonPanel data={state.stability} /></div>
        </section>
      </LoadingSection>
    </Page>
  );
}
