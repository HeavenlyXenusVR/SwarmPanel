import { useCallback, useEffect, useState } from "react";
import { ListMusic, Play, Plus, RefreshCw, RotateCcw, Send, Trash2, WandSparkles } from "lucide-react";
import { apiFetch, cachedFetch, clearCache, query } from "../api.js";
import { useLiveRefresh } from "../hooks/useLiveRefresh.js";
import { useDashboardStream } from "../hooks/useDashboardStream.js";
import { CONTROL_ACTIONS } from "../config.js";
import { ChannelSelect, ControlState } from "../components/swarm.jsx";
import { EmptyState, LoadingSection, Page, SectionHead } from "../components/ui.jsx";
import { payloadForAction } from "../utils/control.js";
import { uniqueBy } from "../utils/format.js";

function SavedQueuesPanel({ ctx, botKey, guildId, voiceChannelId, currentQueue }) {
  const [queues, setQueues] = useState([]);
  const [loading, setLoading] = useState(true);
  const [name, setName] = useState("");
  const [saving, setSaving] = useState(false);
  const [loadingQueueId, setLoadingQueueId] = useState(null);
  const showToast = ctx.showToast;

  const load = useCallback(async ({ background = false, force = false } = {}) => {
    if (!botKey || !guildId) return;
    if (!background) setLoading(true);
    try {
      const result = await apiFetch(`/api/queues${query({ guild_id: guildId, bot_key: botKey })}`, { force });
      setQueues(result.queues || []);
    } catch (error) {
      if (!background) showToast(error.message, "error");
    } finally {
      if (!background) setLoading(false);
    }
  }, [botKey, guildId, showToast]);

  useEffect(() => { load(); }, [load]);
  useLiveRefresh(() => load({ background: true, force: true }), { enabled: Boolean(botKey && guildId), interval: 30_000 });

  async function saveCurrentQueue(event) {
    event.preventDefault();
    if (!currentQueue.length) {
      showToast("The live queue is empty — nothing to save.", "error");
      return;
    }
    setSaving(true);
    try {
      await apiFetch("/api/queues", {
        method: "POST",
        body: JSON.stringify({ guild_id: guildId, bot_key: botKey, name: name || "Saved Queue", items: currentQueue }),
      });
      setName("");
      showToast("Queue saved.", "success");
      await load({ force: true });
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      setSaving(false);
    }
  }

  async function loadQueue(savedQueue) {
    if (!voiceChannelId) {
      showToast("Select a voice channel before loading a saved queue.", "error");
      return;
    }
    setLoadingQueueId(savedQueue.id);
    try {
      for (const item of savedQueue.items || []) {
        await apiFetch("/api/bots/control", {
          method: "POST",
          body: JSON.stringify({
            bot_key: botKey,
            guild_id: guildId,
            action: "PLAY",
            payload: { source_url: item.video_url, voice_channel_id: voiceChannelId },
          }),
        });
      }
      clearCache();
      showToast(`Queued ${savedQueue.items?.length || 0} track(s) from "${savedQueue.name}".`, "success");
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      setLoadingQueueId(null);
    }
  }

  async function deleteQueue(savedQueue) {
    try {
      await apiFetch(`/api/queues/${savedQueue.id}/delete`, {
        method: "POST",
        body: JSON.stringify({ guild_id: guildId }),
      });
      showToast("Saved queue deleted.", "success");
      await load({ force: true });
    } catch (error) {
      showToast(error.message, "error");
    }
  }

  return (
    <div className="panel">
      <SectionHead title="Saved Queues" count={queues.length} />
      <form className="toolbar" onSubmit={saveCurrentQueue}>
        <input
          placeholder="Name this queue"
          value={name}
          onChange={(event) => setName(event.target.value)}
        />
        <button className="primary" type="submit" disabled={saving}><Plus size={16} />Save Current Queue</button>
      </form>
      {loading ? null : queues.length ? (
        <table className="data-table">
          <tbody>
            {queues.map((savedQueue) => (
              <tr key={savedQueue.id}>
                <td><ListMusic size={14} /> {savedQueue.name}</td>
                <td className="table-mono">{savedQueue.items?.length || 0} tracks</td>
                <td className="table-actions">
                  <button type="button" disabled={loadingQueueId === savedQueue.id} onClick={() => loadQueue(savedQueue)}>
                    <Play size={14} />{loadingQueueId === savedQueue.id ? "Loading" : "Load"}
                  </button>
                  <button type="button" className="danger" onClick={() => deleteQueue(savedQueue)}><Trash2 size={14} />Delete</button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      ) : <EmptyState title="No saved queues yet" compact />}
    </div>
  );
}

const DASHBOARD_CACHE_TTL = 4_000;
const DASHBOARD_STALE_TTL = 10_000;
const BOTS_CACHE_TTL = 5_000;
const CONTROL_STATE_INTERVAL = 4_000;
const CONTROLS_BASE_INTERVAL = 5_000;

const FILTER_OPTIONS = [
  ["none", "None"],
  ["nightcore", "Nightcore"],
  ["bassboost", "Bassboost"],
  ["vaporwave", "Vaporwave"],
  ["8d", "8D"],
  ["karaoke", "Karaoke"],
  ["tremolo", "Tremolo"],
  ["vibrato", "Vibrato"],
  ["lowpass", "Low Pass"],
  ["lofi", "Lo-fi"],
  ["electronic", "Electronic"],
  ["party", "Party"],
  ["radio", "Radio"],
  ["cinema", "Cinema"],
];

export default function ControlsPage({ ctx }) {
  const [catalog, setCatalog] = useState({ bots: [], loading: true });
  const [dashboard, setDashboard] = useState(null);
  const [inventory, setInventory] = useState(null);
  const [controlState, setControlState] = useState(null);
  const [matrix, setMatrix] = useState(null);
  const [inventoryLoading, setInventoryLoading] = useState(false);
  const [readinessLoading, setReadinessLoading] = useState(false);
  const [form, setForm] = useState({
    bot_key: "",
    guild_id: ctx.session.guild_id || ctx.session.account_guild_id || "",
    action: "PLAY",
    source_url: "",
    voice_channel_id: "",
    text_channel_id: "",
    loop_mode: "queue",
    filter_mode: "none",
  });
  const [busy, setBusy] = useState(false);

  const showToast = ctx.showToast;
  const loadBase = useCallback(async ({ background = false, force = false } = {}) => {
    if (!background) setCatalog((current) => ({ ...current, loading: true }));
    try {
      const [bots, dash] = await Promise.all([
        cachedFetch("/api/bots", { ttl: BOTS_CACHE_TTL, staleTtl: 15_000, force }),
        cachedFetch("/api/dashboard", { ttl: DASHBOARD_CACHE_TTL, staleTtl: DASHBOARD_STALE_TTL, force }),
      ]);
      const musicBots = (bots.bots || []).filter((bot) => bot.kind === "music");
      setCatalog({ bots: musicBots, loading: false });
      setDashboard(dash);
      setForm((current) => ({
        ...current,
        bot_key: current.bot_key || musicBots[0]?.key || "",
        guild_id: current.guild_id || dash.sessions?.[0]?.guild_id || "",
      }));
    } catch (error) {
      if (!background) showToast(error.message, "error");
    } finally {
      if (!background) setCatalog((current) => ({ ...current, loading: false }));
    }
  }, [showToast]);

  useEffect(() => {
    loadBase();
  }, [loadBase]);

  useEffect(() => {
    if (!form.bot_key) return;
    setInventoryLoading(true);
    apiFetch(`/api/bots/${form.bot_key}/inventory`)
      .then(setInventory)
      .catch((error) => setInventory({ error: error.message, guilds: [] }))
      .finally(() => setInventoryLoading(false));
  }, [form.bot_key]);

  const loadReadiness = useCallback(async () => {
    if (!form.bot_key || !form.guild_id) return;
    setReadinessLoading(true);
    const [state, controlMatrix] = await Promise.allSettled([
      apiFetch(`/api/bots/${form.bot_key}/control-state${query({ guild_id: form.guild_id })}`),
      apiFetch(`/api/guilds/${form.guild_id}/control-matrix`),
    ]);
    setControlState(state.status === "fulfilled" ? state.value : { error: state.reason.message });
    setMatrix(controlMatrix.status === "fulfilled" ? controlMatrix.value : { error: controlMatrix.reason.message, bots: [] });
    setReadinessLoading(false);
  }, [form.bot_key, form.guild_id]);

  useEffect(() => {
    loadReadiness();
  }, [loadReadiness]);

  useDashboardStream({
    enabled: Boolean(ctx.session.authenticated),
    onSnapshot(snapshot) {
      const musicBots = (snapshot?.bots || []).filter((bot) => bot.kind === "music");
      setDashboard(snapshot);
      setCatalog((current) => ({ bots: musicBots, loading: false, error: current.error }));
      setForm((current) => ({
        ...current,
        bot_key: current.bot_key || musicBots[0]?.key || "",
        guild_id: current.guild_id || snapshot?.sessions?.[0]?.guild_id || "",
      }));
    },
  });

  useLiveRefresh(() => loadReadiness().catch(() => {}), { enabled: Boolean(form.bot_key && form.guild_id), interval: CONTROL_STATE_INTERVAL });
  useLiveRefresh(() => loadBase({ background: true, force: true }), { interval: CONTROLS_BASE_INTERVAL });

  useEffect(() => {
    const session = controlState?.session;
    if (!session) return;
    setForm((current) => ({
      ...current,
      voice_channel_id: current.voice_channel_id || session.home_channel_id || session.channel_id || "",
      text_channel_id: current.text_channel_id || session.feedback_channel_id || "",
      loop_mode: session.loop_mode || current.loop_mode || "queue",
      filter_mode: session.filter_mode || current.filter_mode || "none",
    }));
  }, [controlState]);

  const guilds = inventory?.guilds || [];
  const selectedGuild = guilds.find((guild) => String(guild.id) === String(form.guild_id));
  const channels = selectedGuild?.channels || inventory?.channels || [];
  const voiceChannels = channels.filter((channel) => [2, 13].includes(Number(channel.type)));
  const textChannels = channels.filter((channel) => [0, 5, 10, 11, 12].includes(Number(channel.type)));
  const sessionGuilds = uniqueBy((dashboard?.sessions || []).map((session) => ({ id: session.guild_id, name: session.guild_name || `Guild ${session.guild_id}` })), "id");

  function update(key, value) {
    setForm((current) => ({
      ...current,
      [key]: value,
      ...(["bot_key", "guild_id"].includes(key) ? { voice_channel_id: "", text_channel_id: "" } : {}),
    }));
  }

  async function submit(event) {
    event.preventDefault();
    setBusy(true);
    try {
      const payload = payloadForAction(form);
      const data = await apiFetch("/api/bots/control", {
        method: "POST",
        body: JSON.stringify({ bot_key: form.bot_key, guild_id: form.guild_id, action: form.action, payload }),
      });
      clearCache();
      ctx.showToast(data.message || `${form.action} accepted.`, "success");
      loadReadiness().catch(() => {});
      loadBase({ background: true, force: true }).catch(() => {});
    } catch (error) {
      ctx.showToast(error.message, "error");
    } finally {
      setBusy(false);
    }
  }

  return (
    <Page title="Direct Playback Control" eyebrow="Controls" actions={<button type="button" onClick={() => loadBase({ force: true })}><RefreshCw size={16} />Refresh</button>}>
      <section className="control-layout">
        <LoadingSection
          loading={catalog.loading || inventoryLoading}
          title="Preparing control lane"
          tip="Bot inventory, guild routes, and channel choices are loading for this command path."
          count={3}
          minHeight={420}
        >
          <form className="panel form-panel" onSubmit={submit}>
            <label className="field"><span>Bot</span><select value={form.bot_key} onChange={(event) => update("bot_key", event.target.value)}>{catalog.bots.map((bot) => <option value={bot.key} key={bot.key}>{bot.display_name}</option>)}</select></label>
            <label className="field"><span>Guild</span><input value={form.guild_id} onChange={(event) => update("guild_id", event.target.value)} list="known-guilds" required /><datalist id="known-guilds">{sessionGuilds.map((guild) => <option key={guild.id} value={guild.id}>{guild.name}</option>)}</datalist></label>
            <label className="field"><span>Action</span><select value={form.action} onChange={(event) => update("action", event.target.value)}>{CONTROL_ACTIONS.filter((action) => ctx.isAdmin || action !== "RESTART").map((action) => <option key={action} value={action}>{action}</option>)}</select></label>
            {form.action === "PLAY" ? <label className="field"><span>Source URL or search</span><input value={form.source_url} onChange={(event) => update("source_url", event.target.value)} placeholder="https://youtube.com/... or search terms" /></label> : null}
            {["PLAY", "SET_HOME", "SMART_RECOMMEND"].includes(form.action) ? (
              <div className="two-col">
                <label className="field"><span>Voice</span><ChannelSelect value={form.voice_channel_id} channels={voiceChannels} onChange={(value) => update("voice_channel_id", value)} /></label>
                <label className="field"><span>Text</span><ChannelSelect value={form.text_channel_id} channels={textChannels} onChange={(value) => update("text_channel_id", value)} optional /></label>
              </div>
            ) : null}
            {form.action === "LOOP" ? <label className="field"><span>Loop</span><select value={form.loop_mode} onChange={(event) => update("loop_mode", event.target.value)}><option value="off">Off</option><option value="song">Song</option><option value="queue">Queue</option></select></label> : null}
            {form.action === "FILTER" ? <label className="field"><span>Filter</span><select value={form.filter_mode} onChange={(event) => update("filter_mode", event.target.value)}>{FILTER_OPTIONS.map(([value, label]) => <option value={value} key={value}>{label}</option>)}</select></label> : null}
            <div className="live-defaults">
              <strong>Live defaults</strong>
              <span>Voice: {controlState?.session?.home_channel_name || controlState?.session?.channel_name || form.voice_channel_id || "unknown"}</span>
              <span>Text: {controlState?.session?.feedback_channel_name || form.text_channel_id || "none"}</span>
              <span>Loop: {form.loop_mode || "queue"} / Filter: {form.filter_mode || "none"}</span>
            </div>
            <div className="actions-row">
              <button className="primary" type="submit" disabled={busy}><Send size={16} />{busy ? "Sending" : "Send Control"}</button>
              <button type="button" onClick={() => update("action", "SMART_RECOMMEND")}><WandSparkles size={16} />Smart Rec</button>
              <button type="button" onClick={() => update("action", "RESET_QUEUE")}><RotateCcw size={16} />Reset Queue</button>
            </div>
          </form>
        </LoadingSection>
        <LoadingSection
          loading={readinessLoading && !controlState && !matrix}
          title="Checking route readiness"
          tip="SwarmPanel is validating the selected guild lane, queue state, and recovery matrix."
          count={3}
          compact
          minHeight={340}
        >
          <aside className="panel">
            <SectionHead title="Readiness" />
            <ControlState state={controlState} />
            <SectionHead title="Guild Matrix" count={matrix?.bots?.length || 0} />
            <div className="mini-stack">{(matrix?.bots || []).map((bot) => <ControlState state={bot} compact key={bot.key} />)}</div>
          </aside>
        </LoadingSection>
        {form.bot_key && form.guild_id ? (
          <SavedQueuesPanel
            ctx={ctx}
            botKey={form.bot_key}
            guildId={form.guild_id}
            voiceChannelId={form.voice_channel_id}
            currentQueue={controlState?.session?.queue_preview || []}
          />
        ) : null}
      </section>
    </Page>
  );
}
