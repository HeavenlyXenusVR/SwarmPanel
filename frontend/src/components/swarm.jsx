import { memo, useEffect, useState } from "react";
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
  const isActive = Boolean(session?.is_playing || session?.session_state === "playing");
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

export function BotCard({ bot }) {
  const sessions = Array.isArray(bot?.sessions) ? bot.sessions : [];
  const session = bestSession(bot);
  const accent = bot.accent || "#89b4fa";
  const thumbnail = session?.thumbnail || session?.thumbnail_url || "";
  const badge = playbackBadge(session, bot);
  const [playbackNowMs, setPlaybackNowMs] = useState(() => Date.now());
  const livePositionSeconds = livePlaybackPositionSeconds(session, playbackNowMs);
  const durationSeconds = sessionDurationSeconds(session);
  const progressPercent = playbackProgressPercent(session, livePositionSeconds);
  const playbackBarWidth = durationSeconds
    ? `${progressPercent}%`
    : (session?.is_playing || session?.session_state === "playing")
      ? "100%"
      : livePositionSeconds > 0
        ? "100%"
        : "0%";
  const playbackLabel = durationSeconds
    ? `${formatDurationSeconds(livePositionSeconds)} / ${formatDurationSeconds(durationSeconds)}`
    : formatDurationSeconds(livePositionSeconds);
  const playbackMeta = session?.is_paused
    ? "paused"
    : (session?.is_playing || session?.session_state === "playing")
      ? "advancing live"
      : session
        ? "last reported position"
        : "awaiting playback";

  useEffect(() => {
    if (!(session?.is_playing || session?.session_state === "playing")) return undefined;
    const timer = window.setInterval(() => setPlaybackNowMs(Date.now()), 1_000);
    return () => window.clearInterval(timer);
  }, [session?.is_playing, session?.session_state, session?.position_observed_at, session?.updated_at]);

  useEffect(() => {
    setPlaybackNowMs(Date.now());
  }, [session?.position_seconds, session?.position_observed_at, session?.updated_at, session?.duration_seconds, session?.title]);

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
        </div>
      </div>
      {session ? (
        <div className="bot-playback">
          <div className="bot-playback-head">
            <strong>{playbackLabel}</strong>
            <small>{playbackMeta}</small>
          </div>
          <div className="bot-playback-bar" aria-hidden="true">
            <span style={{ width: playbackBarWidth }} />
          </div>
        </div>
      ) : null}
      <div className="chip-row">
        <span>{bot.active_playing_count || sessions.filter((session) => session.is_playing).length} live</span>
        <span>{bot.known_guild_count || bot.guild_count || 0} guilds</span>
        <span>{bot.queue_depth || sessions.reduce((sum, session) => sum + Number(session.queue_count || 0), 0)} queued</span>
        <span>{bot.backup_queue_depth || sessions.reduce((sum, session) => sum + Number(session.backup_queue_count || 0), 0)} backup</span>
      </div>
    </article>
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
      <div className="chip-row">
        <span>{session.guild_name || state.guild_id}</span>
        <span>{session.channel_name || "No channel"}</span>
        <span>{session.queue_count || 0} queued</span>
        <span>{session.backup_queue_count || 0} backup</span>
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

export function ChannelSelect({ value, channels, onChange, optional = false }) {
  return (
    <select value={value} onChange={(event) => onChange(event.target.value)}>
      <option value="">{optional ? "None" : "Choose channel"}</option>
      {channels.map((channel) => <option value={channel.id} key={channel.id}>{channel.name || channel.id}</option>)}
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

export function JsonPanel({ data }) {
  if (!data) return <EmptyState title="No data loaded" compact />;
  return <pre className="json-panel">{JSON.stringify(data, null, 2)}</pre>;
}


export const MemoBotCard = memo(BotCard);
export const MemoUserCard = memo(UserCard);
export const MemoDataTable = memo(DataTable);
