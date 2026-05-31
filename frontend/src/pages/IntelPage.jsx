import { useCallback, useEffect, useState } from "react";
import { RefreshCw } from "lucide-react";
import { apiFetch } from "../api.js";
import { useLiveRefresh } from "../hooks/useLiveRefresh.js";
import { EventList, JsonPanel } from "../components/swarm.jsx";
import { LoadingSection, Notice, Page, SectionHead } from "../components/ui.jsx";

export default function IntelPage({ ctx }) {
  const [state, setState] = useState({ events: [], metrics: null, stability: null, loading: true, error: "" });
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
  useEffect(() => { load(); }, [load]);
  useLiveRefresh(() => load({ force: true, background: true }), { interval: 5_000 });
  return (
    <Page title="Errors And Metrics" eyebrow="Intel" actions={<button type="button" onClick={() => load({ force: true })}><RefreshCw size={16} />Refresh</button>}>
      {state.error ? <Notice tone="error">{state.error}</Notice> : null}
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
