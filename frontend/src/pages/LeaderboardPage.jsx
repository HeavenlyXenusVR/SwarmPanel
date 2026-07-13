import { useCallback, useEffect, useState } from "react";
import { RefreshCw } from "lucide-react";
import { cachedFetch, query } from "../api.js";
import { useLiveRefresh } from "../hooks/useLiveRefresh.js";
import { DataTable } from "../components/swarm.jsx";
import { EmptyState, LoadingSection, Notice, Page, SectionHead } from "../components/ui.jsx";

export default function LeaderboardPage({ ctx }) {
  const [bots, setBots] = useState([]);
  const [botKey, setBotKey] = useState("");
  const [guildId, setGuildId] = useState(ctx.session.guild_id || ctx.session.account_guild_id || "");
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  useEffect(() => {
    cachedFetch("/api/bots", { ttl: 15_000, staleTtl: 30_000 })
      .then((result) => {
        const musicBots = (result.bots || []).filter((bot) => bot.kind === "music");
        setBots(musicBots);
        setBotKey((current) => current || musicBots[0]?.key || "");
      })
      .catch(() => {});
  }, []);

  const load = useCallback(async ({ background = false, force = false } = {}) => {
    if (!botKey || !guildId) return;
    if (!background) setLoading(true);
    try {
      const result = await cachedFetch(`/api/guilds/${guildId}/leaderboard${query({ bot_key: botKey })}`, { ttl: 15_000, staleTtl: 30_000, force });
      setData(result.data);
      setError("");
    } catch (err) {
      if (!background) setError(err.message);
    } finally {
      if (!background) setLoading(false);
    }
  }, [botKey, guildId]);

  useEffect(() => { load(); }, [load]);
  useLiveRefresh(() => load({ background: true, force: true }), { enabled: Boolean(botKey && guildId), interval: 60_000 });

  return (
    <Page
      title="Guild Leaderboard"
      eyebrow="Leaderboard"
      lede="Top tracks and listeners for this guild, built from the fleet's music-intelligence data."
      actions={<button type="button" onClick={() => load({ force: true })}><RefreshCw size={16} />Refresh</button>}
    >
      {error ? <Notice tone="error">{error}</Notice> : null}
      <div className="toolbar">
        <label className="field"><span>Bot</span><select value={botKey} onChange={(event) => setBotKey(event.target.value)}>{bots.map((bot) => <option value={bot.key} key={bot.key}>{bot.display_name}</option>)}</select></label>
        <label className="field"><span>Guild</span><input value={guildId} onChange={(event) => setGuildId(event.target.value)} /></label>
      </div>
      <LoadingSection loading={loading} title="Building leaderboard" tip="Aggregating track and listener scores for this guild." count={2} minHeight={280}>
        <section className="dashboard-grid">
          <div className="panel wide">
            <SectionHead title="Top Tracks" count={data?.top_tracks?.length || 0} />
            {data?.top_tracks?.length ? <DataTable rows={data.top_tracks} /> : <EmptyState title="No track history yet" compact />}
          </div>
          <div className="panel wide">
            <SectionHead title="Top Listeners" count={data?.top_listeners?.length || 0} />
            {data?.top_listeners?.length ? <DataTable rows={data.top_listeners} /> : <EmptyState title="No listener history yet" compact />}
          </div>
        </section>
      </LoadingSection>
    </Page>
  );
}
