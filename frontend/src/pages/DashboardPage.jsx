import { useCallback, useEffect } from "react";
import { useState } from "react";
import { Activity, Bot, ListMusic, MessageCircle, RefreshCw, Siren } from "lucide-react";
import { apiFetch, cachedFetch, prefetchFetch, query } from "../api.js";
import { useLiveRefresh } from "../hooks/useLiveRefresh.js";
import { BotCard, IntelligenceView, SessionTable } from "../components/swarm.jsx";
import { Metric, MetricGrid, Notice, Page, SectionHead, SkeletonGrid } from "../components/ui.jsx";
import { number } from "../utils/format.js";

function mergeRowsByKey(previous = [], next = [], key = "key") {
  if (!Array.isArray(next) || next.length === 0) return Array.isArray(previous) ? previous : [];
  const rows = new Map();
  (Array.isArray(previous) ? previous : []).forEach((row, index) => {
    const rowKey = String(row?.[key] || row?.id || index);
    rows.set(rowKey, row);
  });
  next.forEach((row, index) => {
    const rowKey = String(row?.[key] || row?.id || index);
    rows.set(rowKey, { ...(rows.get(rowKey) || {}), ...row });
  });
  return Array.from(rows.values());
}

function mergeDashboard(current, next) {
  if (!next) return current;
  if (!current) return next;
  return {
    ...current,
    ...next,
    bots: mergeRowsByKey(current.bots, next.bots, "key"),
    sessions: Array.isArray(next.sessions) ? next.sessions : current.sessions,
  };
}

function sessionsFromBots(bots) {
  return bots.flatMap((bot) => (bot.sessions || []).map((session) => ({
    ...session,
    bot_name: bot.display_name,
    bot_key: bot.key,
  })));
}

export default function DashboardPage({ ctx }) {
  const [state, setState] = useState({
    dashboard: null,
    bots: null,
    intelligence: null,
    telegram: null,
    loading: true,
    refreshing: false,
    error: "",
  });

  const load = useCallback(async ({ background = false } = {}) => {
    setState((current) => ({
      ...current,
      loading: !current.dashboard && !current.bots && !background,
      refreshing: Boolean(current.dashboard || current.bots) || background,
      error: background ? current.error : "",
    }));
    const guildId = ctx.session.guild_id || ctx.session.account_guild_id;
    try {
      const [dashboard, bots, intelligence, telegram] = await Promise.allSettled([
        apiFetch("/api/dashboard"),
        cachedFetch("/api/bots", { ttl: 30_000, staleTtl: 180_000, storage: "local" }),
        apiFetch(`/api/music-intelligence${query({ guild_id: guildId, limit: 10 })}`).catch((error) => ({ error: error.message })),
        ctx.isAdmin ? apiFetch("/api/telegram/status").catch((error) => ({ error: error.message })) : Promise.resolve(null),
      ]);
      setState((current) => ({
        dashboard: dashboard.status === "fulfilled" ? mergeDashboard(current.dashboard, dashboard.value) : current.dashboard,
        bots: bots.status === "fulfilled" ? bots.value : current.bots,
        intelligence: intelligence.status === "fulfilled" ? intelligence.value : current.intelligence,
        telegram: telegram.status === "fulfilled" ? telegram.value : current.telegram,
        loading: false,
        refreshing: false,
        error: dashboard.status === "rejected" ? dashboard.reason.message : "",
      }));
    } catch (error) {
      setState((current) => ({ ...current, loading: false, refreshing: false, error: error.message }));
    }
  }, [ctx.isAdmin, ctx.session.account_guild_id, ctx.session.guild_id]);

  useEffect(() => {
    load();
    prefetchFetch("/api/bots", { ttl: 60_000, staleTtl: 300_000, storage: "local" });
  }, [load]);

  useLiveRefresh(() => load({ background: true }), { interval: 10_000 });

  const dashboard = state.dashboard || {};
  const catalogBots = state.bots?.bots || [];
  const bots = dashboard.bots?.length ? dashboard.bots : catalogBots;
  const sessions = Array.isArray(dashboard.sessions) ? dashboard.sessions : sessionsFromBots(bots);
  const active = sessions.filter((session) => session.is_playing || session.session_state === "playing").length;
  const stale = bots.filter((bot) => String(bot.heartbeat_status || "").includes("stale") || bot.status === "offline").length;
  const backupQueued = sessions.reduce((sum, item) => sum + Number(item.backup_queue_count || 0), 0);
  const totalQueued = sessions.reduce((sum, item) => sum + Number(item.queue_count || 0), 0);
  const isInitialLoad = state.loading && !bots.length;
  const telegram = state.telegram?.telegram;
  const uniqueGuilds = new Set(sessions.map((session) => session.guild_id || session.guild_name).filter(Boolean)).size;
  const spotlight = sessions.find((session) => session.is_playing || session.session_state === "playing") || sessions[0] || null;
  const spotlightBot = spotlight ? bots.find((bot) => bot.key === spotlight.bot_key || bot.display_name === spotlight.bot_name) : null;
  const spotlightQueued = Number(spotlight?.queue_count || 0);
  const spotlightBackup = Number(spotlight?.backup_queue_count || 0);
  const spotlightRoutes = Math.max(Number(spotlightBot?.known_guild_count || 0), spotlight?.guild_id ? 1 : 0);
  const spotlightLiveSessions = Math.max(Number(spotlightBot?.active_playing_count || 0), spotlight && (spotlight.is_playing || spotlight.session_state === "playing") ? 1 : 0);
  const fleetBacklog = totalQueued + backupQueued;
  const queueLeaders = [...sessions]
    .sort((a, b) => (Number(b.queue_count || 0) + Number(b.backup_queue_count || 0)) - (Number(a.queue_count || 0) + Number(a.backup_queue_count || 0)))
    .slice(0, 4);
  const topQueueLoad = queueLeaders[0] ? Number(queueLeaders[0].queue_count || 0) + Number(queueLeaders[0].backup_queue_count || 0) : 0;
  const topQueueLabel = queueLeaders[0]?.channel_name || queueLeaders[0]?.guild_name || "No lane";
  const recoveryLabel = stale ? `${stale} nodes need attention` : "all nodes answering";

  return (
    <Page
      title="Swarm Command Deck"
      eyebrow="Dashboard"
      lede="Live fleet telemetry, queue pressure, and command-state visibility in one deck."
      actions={<button type="button" onClick={() => load()} disabled={state.refreshing}><RefreshCw size={16} />{state.refreshing ? "Updating" : "Refresh"}</button>}
      className="page-dashboard"
    >
      {state.error ? <Notice tone="error">{state.error}</Notice> : null}
      <MetricGrid>
        <Metric icon={Bot} label="Bots" value={bots.length || catalogBots.length || 0} />
        <Metric icon={Activity} label="Live Sessions" value={active} />
        <Metric icon={Siren} label="Stale Nodes" value={stale} />
        <Metric icon={ListMusic} label="Queued" value={sessions.reduce((sum, item) => sum + Number(item.queue_count || 0), 0)} />
        <Metric icon={ListMusic} label="Backup Queue" value={backupQueued} />
        {ctx.isAdmin && telegram ? <Metric icon={MessageCircle} label="Telegram" value={telegram.running ? 1 : 0} /> : null}
      </MetricGrid>
      {ctx.isAdmin && telegram ? (
        <Notice tone={telegram.running ? "info" : "error"}>
          Telegram bridge {telegram.running ? `connected as @${telegram.bot_username || "unknown"}` : (telegram.last_error || "is configured and still starting")}.
        </Notice>
      ) : null}
      {isInitialLoad ? <SkeletonGrid count={6} /> : (
        <section className={`dashboard-grid dashboard-density-${ctx.preferences.dashboard_density || "command"} stream-card-${ctx.preferences.stream_card_style || "telemetry"}`} aria-busy={state.refreshing ? "true" : "false"}>
          <div className="panel wide live-bots-panel">
            <SectionHead title="Live Bots" count={bots.length} />
            <div className="bot-grid">
              {bots.map((bot) => <BotCard bot={bot} key={bot.key} />)}
            </div>
          </div>
          <div className="panel dashboard-brief-panel">
            <SectionHead title="Fleet Pulse" count={active} />
            <article className="dashboard-spotlight">
              <div className="dashboard-spotlight-head">
                <span className="dashboard-eyebrow">{spotlight ? "Now steering" : "Standby"}</span>
                <span className={`dashboard-state-badge ${spotlight?.is_playing || spotlight?.session_state === "playing" ? "live" : "idle"}`}>
                  {spotlight?.session_state_label || (spotlight?.is_paused ? "Paused" : spotlight ? "Ready" : "Idle")}
                </span>
              </div>
              <strong>{spotlight?.title || "No live playback right now."}</strong>
              <p>{spotlight ? `${spotlight.bot_name || spotlight.bot_key || "Bot"} routing ${spotlight.channel_name || spotlight.guild_name || "the current voice lane"}` : "The deck will highlight the first active playback lane here once a bot is live."}</p>
              <div className="dashboard-spotlight-metrics">
                <article>
                  <span>Session Queue</span>
                  <strong>{number(spotlightQueued)}</strong>
                  <small>items in this lane</small>
                </article>
                <article>
                  <span>Backup Lane</span>
                  <strong>{number(spotlightBackup)}</strong>
                  <small>recovery items parked</small>
                </article>
                <article>
                  <span>Bot Reach</span>
                  <strong>{number(spotlightRoutes)}</strong>
                  <small>guild routes on this bot</small>
                </article>
                <article>
                  <span>Bot Live</span>
                  <strong>{number(spotlightLiveSessions)}</strong>
                  <small>active sessions on this bot</small>
                </article>
              </div>
            </article>
            <div className="dashboard-mini-metrics">
              <article>
                <span>Fleet Live</span>
                <strong>{number(active)}</strong>
                <small>{number(uniqueGuilds)} guild routes carrying audio</small>
              </article>
              <article>
                <span>Queue Pressure</span>
                <strong>{number(fleetBacklog)}</strong>
                <small>{topQueueLoad ? `${number(topQueueLoad)} heaviest on ${topQueueLabel}` : "queue pressure is calm"}</small>
              </article>
              <article>
                <span>Recovery Watch</span>
                <strong>{number(stale)}</strong>
                <small>{recoveryLabel}</small>
              </article>
              <article>
                <span>Bridge</span>
                <strong>{telegram?.running ? "Live" : "Idle"}</strong>
                <small>{ctx.isAdmin && telegram?.bot_username ? `@${telegram.bot_username}` : "status relay"}</small>
              </article>
            </div>
            <div className="dashboard-queue-leaders">
              <div className="section-head"><h2>Queue Pressure</h2></div>
              <div className="event-list compact-events">
                {queueLeaders.map((session) => (
                  <article className="event dashboard-queue-card" key={`${session.bot_name}-${session.guild_id}-${session.channel_name}`}>
                    <div>
                      <strong>{session.bot_name || session.bot_key || "Bot"}</strong>
                      <small>{session.channel_name || session.guild_name || "voice"}</small>
                    </div>
                    <p>{session.title || "No title available"}</p>
                    <div className="chip-row">
                      <span>{Number(session.queue_count || 0)} queued</span>
                      <span>{Number(session.backup_queue_count || 0)} backup</span>
                    </div>
                  </article>
                ))}
                {!queueLeaders.length ? <Notice tone="info">Queue pressure appears calm right now.</Notice> : null}
              </div>
            </div>
          </div>
          <div className="panel">
            <SectionHead title="Music Intelligence" />
            <IntelligenceView data={state.intelligence?.data} />
          </div>
          <div className="panel wide">
            <SectionHead title="Active Sessions" count={sessions.length} />
            <SessionTable sessions={sessions} />
          </div>
        </section>
      )}
    </Page>
  );
}
