import { memo, useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { Heart, MessageCircle, Music2, PlugZap, UserPlus } from "lucide-react";
import { apiFetch, clearCache } from "../api.js";
import { EmptyState, Notice } from "./ui.jsx";
import { formatCell, formatDurationSeconds, formatTime, initials, number, pick, titleCase, unique } from "../utils/format.js";

const COLUMN_LABELS = {
  account_id: "Account",
  backup_queue_count: "Backup",
  bot_display: "Bot",
  bot_key: "Bot Key",
  bot_name: "Bot",
  channel_id: "Channel ID",
  channel_name: "Channel",
  created_at: "Created",
  display_name: "Display Name",
  favorite_bot: "Favorite Bot",
  filter_mode: "Filter",
  friend_count: "Friends",
  guild_id: "Guild ID",
  guild_name: "Guild",
  heartbeat_status: "Heartbeat",
  is_paused: "Paused",
  is_playing: "Live",
  last_checkpoint_at: "Checkpoint",
  loop_mode: "Loop",
  queue_count: "Queued",
  thumbnail_url: "Artwork",
  updated_at: "Updated",
  user_id: "User ID",
  username: "Handle",
};

function MediaImage({ src, className, alt = "", fallback }) {
  const [failed, setFailed] = useState(false);
  if (!src || failed) return fallback;
  return (
    <img
      className={className}
      src={src}
      alt={alt}
      loading="lazy"
      decoding="async"
      onError={() => setFailed(true)}
    />
  );
}

export function IdentityAvatar({ src, label, online = false, className = "avatar", showPresence = true }) {
  const avatarClassName = className.includes("avatar-presence") ? className : `${className} avatar-presence`;
  return (
    <div className={avatarClassName}>
      <MediaImage
        className="avatar-image"
        src={src}
        alt=""
        fallback={<span className="avatar-fallback">{initials(label)}</span>}
      />
      {showPresence ? <span className={`presence-dot avatar-dot ${online ? "online" : "inactive"}`} aria-hidden="true" /> : null}
    </div>
  );
}

function playbackBadge(session, bot) {
  if (session?.is_playing || session?.session_state === "playing") return { label: "Live", tone: "live" };
  if (session?.is_paused || session?.session_state === "paused") return { label: "Paused", tone: "soft" };
  if (String(bot?.heartbeat_status || bot?.status || "").toLowerCase().includes("stale") || String(bot?.status || "").toLowerCase() === "offline") {
    return { label: "Stale", tone: "danger" };
  }
  return { label: "Idle", tone: "off" };
}

function safeBoolean(value) {
  if (typeof value === "boolean") return value;
  if (typeof value === "number") return value > 0;
  const normalized = String(value || "").trim().toLowerCase();
  if (!normalized) return false;
  return ["1", "true", "yes", "playing", "online", "active", "enabled"].includes(normalized);
}

function labelForColumn(column) {
  return COLUMN_LABELS[column] || titleCase(column);
}

function cellTone(value) {
  const normalized = String(value || "").trim().toLowerCase();
  if (!normalized || normalized === "none" || normalized === "idle" || normalized === "inactive" || normalized === "offline") return "off";
  if (normalized.includes("error") || normalized.includes("failed") || normalized.includes("stale")) return "danger";
  if (normalized.includes("online") || normalized.includes("playing") || normalized.includes("active") || normalized === "live") return "live";
  return "soft";
}

function isNumericColumn(column, value) {
  if (typeof value === "number") return true;
  if (typeof value !== "string" || !/^-?\d+(\.\d+)?$/.test(value.trim())) return false;
  return /count|plays|skips|likes|dislikes|followers|friends|guilds|queued|backup|finishes|position|seconds|duration|score|health/i.test(column);
}

function renderTableCell(column, value) {
  if (value === null || value === undefined || value === "") return <span className="muted">-</span>;
  if (Array.isArray(value)) {
    return (
      <div className="chip-row table-chip-row">
        {value.slice(0, 4).map((item, index) => <span key={`${column}-${index}`}>{formatCell(item)}</span>)}
        {value.length > 4 ? <span>+{value.length - 4}</span> : null}
      </div>
    );
  }
  if (typeof value === "object") {
    return <pre className="table-code">{JSON.stringify(value, null, 2)}</pre>;
  }
  if (typeof value === "boolean" || column.startsWith("is_")) {
    const active = safeBoolean(value);
    const label = column === "is_playing" ? (active ? "Live" : "Idle") : column === "is_paused" ? (active ? "Paused" : "No") : (active ? "Yes" : "No");
    return <span className={`data-pill data-pill-${active ? "live" : "off"}`}>{label}</span>;
  }
  if (column.endsWith("_at") || column.includes("timestamp")) {
    return <time className="table-mono">{formatTime(value)}</time>;
  }
  if (typeof value === "string" && (column.endsWith("_id") || column === "schema")) {
    return <code className="table-mono">{value}</code>;
  }
  if (typeof value === "string" && /(status|mode)/i.test(column)) {
    return <span className={`data-pill data-pill-${cellTone(value)}`}>{titleCase(value)}</span>;
  }
  if (isNumericColumn(column, value)) {
    return <span className="table-number">{number(value)}</span>;
  }
  if (typeof value === "string" && /(title|display_name|guild_name|channel_name|bot_name|headline|message|description)/i.test(column)) {
    return <div className="table-rich"><strong>{value}</strong></div>;
  }
  return <span>{formatCell(value)}</span>;
}

function cellClassName(column) {
  if (column.endsWith("_id") || column === "schema") return "table-cell-mono";
  if (/title|description|message/i.test(column)) return "table-cell-wide";
  if (/count|plays|skips|likes|dislikes|followers|friends|queued|backup/i.test(column)) return "table-cell-number";
  return "";
}

export function PresencePill({ user, compact = false }) {
  const online = Boolean(user?.is_online);
  return (
    <span className={`presence-pill ${online ? "online" : "inactive"} ${compact ? "compact" : ""}`}>
      <span className="presence-dot" aria-hidden="true" />
      {online ? "Online" : "Inactive"}
    </span>
  );
}

function bestSession(bot) {
  const sessions = Array.isArray(bot?.sessions) ? bot.sessions : [];
  return sessions.find((session) => session.is_playing) || sessions[0] || null;
}

function sessionIsPlaying(session) {
  return Boolean(session?.is_playing || session?.session_state === "playing");
}

function sessionIsPaused(session) {
  return Boolean(session?.is_paused || session?.session_state === "paused");
}

function sessionDurationSeconds(session) {
  return Math.max(0, Math.floor(Number(session?.duration_seconds) || 0));
}

function sessionObservedAtMs(session) {
  const raw = session?.position_observed_at || session?.updated_at || "";
  const parsed = Date.parse(raw);
  return Number.isFinite(parsed) ? parsed : 0;
}

function livePlaybackPositionSeconds(session, nowMs = Date.now()) {
  const basePosition = Math.max(0, Math.floor(Number(session?.position_seconds) || 0));
  const duration = sessionDurationSeconds(session);
  const isActive = sessionIsPlaying(session);
  const observedAtMs = sessionObservedAtMs(session);
  let position = basePosition;
  if (isActive && observedAtMs > 0) {
    position += Math.max(0, Math.floor((nowMs - observedAtMs) / 1000));
  }
  if (duration > 0) position = Math.min(position, duration);
  return position;
}

function playbackProgressPercent(session, positionSeconds) {
  const duration = sessionDurationSeconds(session);
  if (!duration) return 0;
  return Math.max(0, Math.min(100, (positionSeconds / duration) * 100));
}

function playbackSnapshot(session, nowMs = Date.now()) {
  const positionSeconds = livePlaybackPositionSeconds(session, nowMs);
  const durationSeconds = sessionDurationSeconds(session);
  const progressPercent = playbackProgressPercent(session, positionSeconds);
  const isPlaying = sessionIsPlaying(session);
  const isPaused = sessionIsPaused(session);
  return {
    positionSeconds,
    durationSeconds,
    progressPercent,
    playbackBarWidth: durationSeconds
      ? `${progressPercent}%`
      : isPlaying
        ? "100%"
        : positionSeconds > 0
          ? "100%"
          : "0%",
    playbackLabel: durationSeconds
      ? `${formatDurationSeconds(positionSeconds)} / ${formatDurationSeconds(durationSeconds)}`
      : formatDurationSeconds(positionSeconds),
    playbackMeta: isPaused
      ? "paused"
      : isPlaying
        ? "advancing live"
        : session
          ? "last reported position"
          : "awaiting playback",
  };
}

export function PlaybackCounter({ session, className = "", compact = false }) {
  const [playbackNowMs, setPlaybackNowMs] = useState(() => Date.now());
  const { playbackBarWidth, playbackLabel, playbackMeta } = playbackSnapshot(session, playbackNowMs);
  const live = sessionIsPlaying(session);

  useEffect(() => {
    if (!live) return undefined;
    const timer = window.setInterval(() => setPlaybackNowMs(Date.now()), 1_000);
    return () => window.clearInterval(timer);
  }, [live, session?.position_observed_at, session?.updated_at]);

  useEffect(() => {
    setPlaybackNowMs(Date.now());
  }, [session?.position_seconds, session?.position_observed_at, session?.updated_at, session?.duration_seconds, session?.title]);

  if (!session) return null;
  return (
    <div className={`bot-playback ${compact ? "compact" : ""} ${className}`.trim()}>
      <div className="bot-playback-head">
        <strong>{playbackLabel}</strong>
        <small>{playbackMeta}</small>
      </div>
      <div className="bot-playback-bar" aria-hidden="true">
        <span style={{ width: playbackBarWidth }} />
      </div>
    </div>
  );
}

export function BotCard({ bot }) {
  const sessions = Array.isArray(bot?.sessions) ? bot.sessions : [];
  const session = bestSession(bot);
  const accent = bot.accent || "#89b4fa";
  const thumbnail = session?.thumbnail || session?.thumbnail_url || "";
  const badge = playbackBadge(session, bot);

  return (
    <article className="bot-card" style={{ "--card-accent": accent }}>
      <div className="bot-head">
        <span className="bot-dot" />
        <div className="bot-head-copy">
          <h3>{bot.display_name || bot.name || bot.key}</h3>
          <small>{bot.heartbeat_status || bot.status || "telemetry ready"}</small>
        </div>
        <span className={`data-pill data-pill-${badge.tone}`}>{badge.label}</span>
      </div>
      <div className="bot-now">
        <MediaImage
          className="bot-thumb"
          src={thumbnail}
          alt=""
          fallback={<div className="bot-thumb bot-thumb-empty"><Music2 size={22} /></div>}
        />
        <div className="bot-now-copy">
          <strong>{session?.title || bot.db_error || bot.schema || "Waiting for live playback."}</strong>
          <small>{session?.guild_name || session?.channel_name || "Live state will fill in automatically."}</small>
          {session?.playback_source ? (
            <span style={{
              display: "inline-block", marginTop: 4, padding: "1px 8px", borderRadius: 10,
              fontSize: 11, fontWeight: 700, letterSpacing: 0.3,
              background: session.playback_source === "local" ? "#13351f" : "#332617",
              color: session.playback_source === "local" ? "#5bd97e" : "#e8b366",
            }}>
              {session.playback_source === "local" ? "● LOCAL CACHE" : "● STREAMING"}
            </span>
          ) : null}
        </div>
      </div>
      {session ? <PlaybackCounter session={session} /> : null}
      {session ? <BotSeekBar session={session} botKey={bot.key} /> : null}
      <div className="chip-row">
        <span>{bot.active_playing_count || sessions.filter((session) => session.is_playing).length} live</span>
        <span>{bot.known_guild_count || bot.guild_count || 0} guilds</span>
        <span>{bot.queue_depth || sessions.reduce((sum, session) => sum + Number(session.queue_count || 0), 0)} queued</span>
        <span>{bot.backup_queue_depth || sessions.reduce((sum, session) => sum + Number(session.backup_queue_count || 0), 0)} backup</span>
        <span>{Number(bot.audio_cache?.files || 0).toLocaleString()} cached{bot.local_playing_count ? ` · ${bot.local_playing_count} local` : ""}</span>
      </div>
    </article>
  );
}

function BotSeekBar({ session, botKey }) {
  const [seeking, setSeeking] = useState(false);
  const [seekPos, setSeekPos] = useState(null);  // null = not seeking, 0-1 = fraction
  const barRef = useRef(null);

  const duration = Math.max(0, Number(session?.duration_seconds) || 0);
  const isPlaying = Boolean(session?.is_playing || session?.session_state === "playing");

  // Live-advancing position while playing — declared unconditionally so hook count
  // stays stable even when `duration` is 0 and we bail out below (React error #310).
  const [liveMs, setLiveMs] = useState(() => Date.now());
  useEffect(() => {
    if (!duration || !isPlaying || seeking) return undefined;
    const t = setInterval(() => setLiveMs(Date.now()), 1000);
    return () => clearInterval(t);
  }, [duration, isPlaying, seeking]);

  function getFraction(event) {
    const bar = barRef.current;
    if (!bar) return 0;
    const rect = bar.getBoundingClientRect();
    return Math.min(1, Math.max(0, (event.clientX - rect.left) / rect.width));
  }

  // Also declared unconditionally (same reasoning as above, React error #300): this used to sit
  // after the `if (!duration) return null` bailout below, so a render where duration dropped to 0
  // called one fewer hook than the previous render.
  useEffect(() => {
    if (!seeking) return;
    function onMove(e) { setSeekPos(getFraction(e)); }
    async function onUp(e) {
      const fraction = getFraction(e);
      setSeeking(false);
      setSeekPos(null);
      const targetSeconds = Math.round(fraction * duration);
      try {
        await apiFetch("/api/bots/control", {
          method: "POST",
          body: JSON.stringify({
            bot_key: botKey,
            action: "SEEK",
            guild_id: session.guild_id,
            payload: { position_seconds: targetSeconds },
          }),
        });
      } catch (_err) {
        // Seek failed silently — position display will self-correct on next poll
      }
    }
    document.addEventListener("mousemove", onMove);
    document.addEventListener("mouseup", onUp);
    return () => {
      document.removeEventListener("mousemove", onMove);
      document.removeEventListener("mouseup", onUp);
    };
  }, [seeking, botKey, session?.guild_id, duration]);

  if (!duration) return null;

  const positionSeconds = Math.max(0, Math.min(Number(session?.position_seconds) || 0, duration));
  const observedAt = session?.position_observed_at || session?.updated_at;
  const observedAtMs = observedAt ? (Date.parse(observedAt) || 0) : 0;
  const livePosition = isPlaying && observedAtMs > 0
    ? Math.min(positionSeconds + Math.floor((liveMs - observedAtMs) / 1000), duration)
    : positionSeconds;

  const displayFraction = seeking && seekPos !== null ? seekPos : (duration > 0 ? livePosition / duration : 0);

  function onMouseDown(event) {
    event.preventDefault();
    setSeeking(true);
    setSeekPos(getFraction(event));
  }
  function onMouseMove(event) {
    if (!seeking) return;
    setSeekPos(getFraction(event));
  }

  const pct = Math.round(displayFraction * 100);
  const currentSecs = Math.round(displayFraction * duration);

  return (
    <div className="bot-seek-bar" title={seeking ? `Seek to ${formatDurationSeconds(currentSecs)}` : `Position: ${formatDurationSeconds(currentSecs)} / ${formatDurationSeconds(duration)}`}>
      <div
        ref={barRef}
        className={`bot-seek-track${seeking ? " bot-seek-seeking" : ""}`}
        onMouseDown={onMouseDown}
        onMouseMove={onMouseMove}
        role="slider"
        aria-label="Seek track position"
        aria-valuemin={0}
        aria-valuemax={duration}
        aria-valuenow={currentSecs}
        tabIndex={0}
      >
        <div className="bot-seek-fill" style={{ width: `${pct}%` }} />
        <div className="bot-seek-thumb" style={{ left: `${pct}%` }} />
      </div>
      <div className="bot-seek-times">
        <span>{formatDurationSeconds(currentSecs)}</span>
        <span>{formatDurationSeconds(duration)}</span>
      </div>
    </div>
  );
}

export function SessionTable({ sessions }) {
  const safeSessions = Array.isArray(sessions) ? sessions : [];
  if (!safeSessions.length) return <EmptyState title="No active sessions" />;
  return <DataTable rows={safeSessions.map((session) => pick(session, ["bot_name", "guild_name", "guild_id", "channel_name", "title", "is_playing", "queue_count", "backup_queue_count", "filter_mode", "loop_mode"]))} />;
}

export function IntelligenceView({ data }) {
  if (!data) return <EmptyState title="No intelligence snapshot" />;
  if (Array.isArray(data)) return <DataTable rows={data} />;
  const rows = [data?.recommendations, data?.guilds, data?.bots, data?.rows].find(Array.isArray) || [];
  return rows.length ? <DataTable rows={rows} /> : <JsonPanel data={data} />;
}

export function ControlState({ state, compact = false }) {
  if (!state) return <EmptyState title="No state loaded" compact />;
  if (state.error) return <Notice tone="error">{state.error}</Notice>;
  const session = state.session || {};
  const backupPreview = Array.isArray(session.backup_queue_preview) ? session.backup_queue_preview : [];
  return (
    <article className={`control-state ${compact ? "compact" : ""}`}>
      <div><strong>{state.display_name || state.key}</strong><small>{state.discord?.status || state.db?.status || "unknown"}</small></div>
      <p>{session.title || session.session_state_label || state.discord?.message || "Idle"}</p>
      {session.title || Number(session.position_seconds || 0) > 0 ? <PlaybackCounter session={session} compact /> : null}
      <div className="chip-row">
        <span>{session.guild_name || state.guild_id}</span>
        <span>{session.channel_name || "No channel"}</span>
        <span>{session.queue_count || 0} queued</span>
        <span>{session.backup_queue_count || 0} backup</span>
        {session.playback_source ? <span>{session.playback_source === "local" ? "▣ local cache" : "▶ streaming"}</span> : null}
      </div>
      {!compact && backupPreview.length ? (
        <div className="backup-preview">
          {backupPreview.map((track, index) => (
            <span key={`${track.video_url || track.title || "track"}-${index}`}>{track.title || track.video_url || "Untitled backup track"}</span>
          ))}
        </div>
      ) : null}
    </article>
  );
}

export function InviteCard({ bot }) {
  const accent = bot.accent || "#89b4fa";
  const identityLabel = bot.identity_name || bot.display_name || bot.name || bot.key;
  const statusTone = bot.token_configured ? (bot.connected_to_session_guild ? "live" : "soft") : "danger";
  const statusLabel = bot.token_configured
    ? (bot.connected_to_session_guild ? "Ready Here" : "Ready")
    : "Token Missing";
  return (
    <article className="invite-card" style={{ "--card-accent": accent }}>
      <div className="bot-head invite-card-head">
        <IdentityAvatar src={bot.icon_url} label={identityLabel} className="avatar invite-avatar" showPresence={false} />
        <div className="bot-head-copy invite-card-copy">
          <h3>{bot.display_name}</h3>
          <small>{bot.identity_name || (bot.token_configured ? "Discord application ready" : "Discord token missing")}</small>
        </div>
        <span className={`data-pill data-pill-${statusTone}`}>{statusLabel}</span>
      </div>
      <p>{bot.capability_summary}</p>
      <div className="chip-row">{(bot.permissions || []).slice(0, 6).map((permission) => <span key={permission}>{permission}</span>)}</div>
      {bot.invite_url ? <a className="button-link primary" href={bot.invite_url} target="_blank" rel="noreferrer"><PlugZap size={16} />Invite</a> : <button disabled>Invite unavailable</button>}
    </article>
  );
}

export function UserCard({ user, ctx, onChanged }) {
  const imageUrl = user.avatar_url || user.server_icon_url || "";
  const accountId = user.id || user.account_id || user.user_id;
  const profilePath = accountId ? `/users/${accountId}` : "/users";
  const displayName = user.display_name || user.username || "Unknown operator";
  const guildLabel = user.server_name || user.profile_headline || (user.guild_id ? `Guild ${user.guild_id}` : "Swarm directory");
  const favoriteBot = user.favorite_bot ? titleCase(user.favorite_bot) : "No favorite";
  async function follow() {
    try {
      await apiFetch(`/api/users/${user.id}/follow`, { method: "POST", body: JSON.stringify({ following: !user.followed_by_me }) });
      clearCache("/api/users");
      onChanged?.();
    } catch (error) {
      ctx?.showToast(error.message, "error");
    }
  }
  async function friend() {
    try {
      await apiFetch(`/api/users/${user.id}/friend-request`, { method: "POST" });
      onChanged?.();
    } catch (error) {
      ctx?.showToast(error.message, "error");
    }
  }
  return (
    <article className="user-card">
      <div className="user-card-main">
        <Link className="avatar-link" to={profilePath}>
          <IdentityAvatar src={imageUrl} label={displayName} online={user.is_online} className="avatar avatar-lg avatar-presence" />
        </Link>
        <div className="user-card-copy">
          <div className="user-card-head">
            <Link to={profilePath}><h3>{displayName}</h3></Link>
            <PresencePill user={user} compact />
          </div>
          <p className="user-card-handle">@{user.username || "operator"}</p>
          <p className="user-card-guild">{guildLabel}</p>
          <div className="chip-row user-card-tags">
            <span>{favoriteBot}</span>
            {user.server_name ? <span>{user.server_name}</span> : null}
          </div>
        </div>
      </div>
      <div className="user-card-stats">
        <article>
          <strong>{number(user.follower_count || 0)}</strong>
          <span>Followers</span>
        </article>
        <article>
          <strong>{number(user.friend_count || 0)}</strong>
          <span>Friends</span>
        </article>
        <article>
          <strong>{favoriteBot}</strong>
          <span>Favorite Bot</span>
        </article>
      </div>
      {ctx ? (
        <div className="inline-controls user-card-actions">
          <Link className="button-link" to={profilePath}>Open</Link>
          <button type="button" onClick={follow}><Heart size={16} />{user.followed_by_me ? "Unfollow" : "Follow"}</button>
          <button type="button" onClick={friend} disabled={["friends", "pending_out", "self"].includes(user.friend_status)}><UserPlus size={16} />{user.friend_status === "friends" ? "Friends" : user.friend_status === "pending_out" ? "Pending" : "Friend"}</button>
          <Link className="button-link" to="/messages" state={{ user }}><MessageCircle size={16} />Message</Link>
        </div>
      ) : null}
    </article>
  );
}

export function EventList({ events }) {
  if (!events.length) return <EmptyState title="No events yet" />;
  return (
    <div className="event-list">
      {events.map((event, index) => (
        <article className={`event event-${event.level || "info"}`} key={`${event.timestamp}-${index}`}>
          <div><strong>{event.title || event.type}</strong><small>{event.source} / {formatTime(event.timestamp)}</small></div>
          <p>{event.description || event.message || ""}</p>
        </article>
      ))}
    </div>
  );
}

const THREAD_CHANNEL_TYPES = new Set([10, 11, 12]);

export function ChannelSelect({ value, channels, onChange, optional = false }) {
  return (
    <select value={value} onChange={(event) => onChange(event.target.value)}>
      <option value="">{optional ? "None" : "Choose channel"}</option>
      {channels.map((channel) => (
        <option value={channel.id} key={channel.id}>
          {(channel.name || channel.id) + (THREAD_CHANNEL_TYPES.has(Number(channel.type)) ? " (thread)" : "")}
        </option>
      ))}
    </select>
  );
}

export function DataTable({ rows = [], actions }) {
  if (!rows?.length) return <EmptyState title="No rows" compact />;
  const columns = unique(rows.flatMap((row) => Object.keys(row))).filter((column) => !String(column).toLowerCase().includes("password_hash")).slice(0, 9);
  return (
    <div className="table-wrap">
      <table className="data-table">
        <thead><tr>{columns.map((column) => <th className={cellClassName(column)} key={column}>{labelForColumn(column)}</th>)}{actions ? <th>Actions</th> : null}</tr></thead>
        <tbody>
          {rows.map((row, index) => (
            <tr key={row.id ?? `${index}-${JSON.stringify(row).slice(0, 20)}`}>
              {columns.map((column) => <td className={cellClassName(column)} key={column}>{renderTableCell(column, row[column])}</td>)}
              {actions ? <td>{actions(row)}</td> : null}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

const TREND_CHART_WIDTH = 560;
const TREND_CHART_HEIGHT = 160;
const TREND_CHART_PAD = { top: 12, right: 14, bottom: 22, left: 14 };

export function TrendChart({ points = [], label = "", color = "var(--accent)", valueKey = "metric_value", timeKey = "captured_at" }) {
  const [hoverIndex, setHoverIndex] = useState(null);
  const svgRef = useRef(null);
  const safePoints = Array.isArray(points) ? points.filter((point) => point && point[timeKey]) : [];

  if (!safePoints.length) {
    return (
      <div className="trend-chart trend-chart-empty">
        <EmptyState title={`No ${label || "metric"} history yet`} compact />
      </div>
    );
  }

  const values = safePoints.map((point) => Number(point[valueKey]) || 0);
  const times = safePoints.map((point) => new Date(point[timeKey]).getTime());
  const minValue = Math.min(0, ...values);
  const maxValue = Math.max(1, ...values);
  const minTime = Math.min(...times);
  const maxTime = Math.max(...times);
  const innerWidth = TREND_CHART_WIDTH - TREND_CHART_PAD.left - TREND_CHART_PAD.right;
  const innerHeight = TREND_CHART_HEIGHT - TREND_CHART_PAD.top - TREND_CHART_PAD.bottom;

  const xForIndex = (index) => {
    const span = maxTime - minTime || 1;
    return TREND_CHART_PAD.left + ((times[index] - minTime) / span) * innerWidth;
  };
  const yForValue = (value) => {
    const span = maxValue - minValue || 1;
    return TREND_CHART_PAD.top + innerHeight - ((value - minValue) / span) * innerHeight;
  };

  const linePath = safePoints.map((_point, index) => `${index === 0 ? "M" : "L"}${xForIndex(index).toFixed(2)},${yForValue(values[index]).toFixed(2)}`).join(" ");
  const areaPath = `${linePath} L${xForIndex(safePoints.length - 1).toFixed(2)},${(TREND_CHART_PAD.top + innerHeight).toFixed(2)} L${xForIndex(0).toFixed(2)},${(TREND_CHART_PAD.top + innerHeight).toFixed(2)} Z`;

  const latest = values[values.length - 1];
  const gradientId = `trend-gradient-${label.replace(/[^a-z0-9]/gi, "") || "metric"}`;

  function handleMove(event) {
    const svg = svgRef.current;
    if (!svg || !safePoints.length) return;
    const rect = svg.getBoundingClientRect();
    const relativeX = ((event.clientX - rect.left) / rect.width) * TREND_CHART_WIDTH;
    let nearest = 0;
    let nearestDistance = Infinity;
    for (let index = 0; index < safePoints.length; index += 1) {
      const distance = Math.abs(xForIndex(index) - relativeX);
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearest = index;
      }
    }
    setHoverIndex(nearest);
  }

  const hovered = hoverIndex !== null ? safePoints[hoverIndex] : null;

  return (
    <div className="trend-chart">
      <div className="trend-chart-head">
        <span>{label}</span>
        <strong>{number(latest)}</strong>
      </div>
      <svg
        ref={svgRef}
        viewBox={`0 0 ${TREND_CHART_WIDTH} ${TREND_CHART_HEIGHT}`}
        className="trend-chart-svg"
        role="img"
        aria-label={`${label} trend over time, latest value ${latest}`}
        onMouseMove={handleMove}
        onMouseLeave={() => setHoverIndex(null)}
      >
        <defs>
          <linearGradient id={gradientId} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor={color} stopOpacity="0.28" />
            <stop offset="100%" stopColor={color} stopOpacity="0" />
          </linearGradient>
        </defs>
        <line
          x1={TREND_CHART_PAD.left}
          x2={TREND_CHART_WIDTH - TREND_CHART_PAD.right}
          y1={TREND_CHART_PAD.top + innerHeight}
          y2={TREND_CHART_PAD.top + innerHeight}
          className="trend-chart-axis"
        />
        <path d={areaPath} fill={`url(#${gradientId})`} stroke="none" />
        <path d={linePath} fill="none" stroke={color} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
        {hovered ? (
          <g>
            <line
              x1={xForIndex(hoverIndex)}
              x2={xForIndex(hoverIndex)}
              y1={TREND_CHART_PAD.top}
              y2={TREND_CHART_PAD.top + innerHeight}
              className="trend-chart-crosshair"
            />
            <circle cx={xForIndex(hoverIndex)} cy={yForValue(values[hoverIndex])} r="4" fill={color} stroke="var(--panel)" strokeWidth="1.5" />
          </g>
        ) : null}
      </svg>
      {hovered ? (
        <div className="trend-chart-tooltip">
          <strong>{number(Number(hovered[valueKey]) || 0)}</strong>
          <span>{formatTime(hovered[timeKey])}</span>
        </div>
      ) : (
        <div className="trend-chart-tooltip trend-chart-tooltip-muted">
          <span>Hover the chart for a point-in-time reading.</span>
        </div>
      )}
    </div>
  );
}

export function JsonPanel({ data }) {
  if (!data) return <EmptyState title="No data loaded" compact />;
  return <pre className="json-panel">{JSON.stringify(data, null, 2)}</pre>;
}


export const MemoBotCard = memo(BotCard);
export const MemoUserCard = memo(UserCard);
export const MemoDataTable = memo(DataTable);
