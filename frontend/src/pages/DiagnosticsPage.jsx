import { useCallback, useEffect, useState } from "react";
import { RefreshCw } from "lucide-react";
import { apiFetch, query } from "../api.js";
import { useLiveRefresh } from "../hooks/useLiveRefresh.js";
import { JsonPanel } from "../components/swarm.jsx";
import { LoadingSection, Notice, Page } from "../components/ui.jsx";

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
