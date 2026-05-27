import { useCallback, useEffect, useState } from "react";
import { RefreshCw } from "lucide-react";
import { apiFetch } from "../api.js";
import { useLiveRefresh } from "../hooks/useLiveRefresh.js";
import { EventList, JsonPanel } from "../components/swarm.jsx";
import { Page, SectionHead } from "../components/ui.jsx";

export default function IntelPage({ ctx }) {
  const [state, setState] = useState({ events: [], metrics: null, stability: null });
  const load = useCallback(async ({ force = false } = {}) => {
    const [events, metrics, stability] = await Promise.allSettled([
      apiFetch("/api/events?limit=80", { force }),
      apiFetch("/api/metrics", { force }),
      apiFetch("/api/stability", { force }),
    ]);
    setState({
      events: events.status === "fulfilled" ? events.value.events || [] : [],
      metrics: metrics.status === "fulfilled" ? metrics.value : { error: metrics.reason?.message },
      stability: stability.status === "fulfilled" ? stability.value : { error: stability.reason?.message },
    });
  }, []);
  useEffect(() => { load(); }, [load]);
  useLiveRefresh(() => load(), { interval: 8_000 });
  return (
    <Page title="Errors And Metrics" eyebrow="Intel" actions={<button type="button" onClick={() => load({ force: true })}><RefreshCw size={16} />Refresh</button>}>
      <section className="dashboard-grid">
        <div className="panel wide"><SectionHead title="Events" count={state.events.length} /><EventList events={state.events} /></div>
        <div className="panel"><SectionHead title="Metrics" /><JsonPanel data={state.metrics} /></div>
        <div className="panel"><SectionHead title="Stability" /><JsonPanel data={state.stability} /></div>
      </section>
    </Page>
  );
}
