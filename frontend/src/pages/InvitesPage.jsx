import { useCallback, useEffect, useState } from "react";
import { RefreshCw } from "lucide-react";
import { cachedFetch } from "../api.js";
import { useLiveRefresh } from "../hooks/useLiveRefresh.js";
import { InviteCard } from "../components/swarm.jsx";
import { EmptyState, LoadingSection, Notice, Page } from "../components/ui.jsx";

export default function InvitesPage({ ctx }) {
  const [data, setData] = useState(null);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);
  const load = useCallback(async ({ background = false, force = false } = {}) => {
    try {
      if (!background) setLoading(true);
      setData(await cachedFetch("/api/bots", { ttl: background ? 4_000 : 8_000, staleTtl: background ? 8_000 : 20_000, force: background || force }));
      setError("");
    } catch (loadError) {
      if (!background) setError(loadError.message);
    } finally {
      if (!background) setLoading(false);
    }
  }, []);
  useEffect(() => { load(); }, [load]);
  useLiveRefresh(() => load({ background: true, force: true }), { interval: 5_000 });
  return (
    <Page title="Bot Access" eyebrow="Invites" actions={<button type="button" onClick={() => load({ force: true })}><RefreshCw size={16} />Refresh</button>}>
      {error ? <Notice tone="error">{error}</Notice> : null}
      <LoadingSection
        loading={loading}
        title="Gathering invite roster"
        tip="SwarmPanel is checking which bots are ready to join this guild."
        count={3}
        minHeight={260}
      >
        <div className="invite-grid">
          {(data?.invite_bots || []).map((bot) => <InviteCard bot={bot} key={bot.key} />)}
        </div>
        {!loading && !(data?.invite_bots || []).length ? <EmptyState title="No inviteable bots yet" /> : null}
      </LoadingSection>
    </Page>
  );
}
