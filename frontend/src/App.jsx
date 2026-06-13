import React, { useCallback, useEffect, useMemo, useState } from "react";
import { Navigate, useLocation, useNavigate } from "react-router-dom";
import {
  apiFetch,
  cachedFetch,
  clearCache,
  isBackendUnreachable,
  prefetchFetch,
  query,
  readToken,
  subscribeBackendStatus,
  writeToken,
  writeUsername,
} from "./api.js";
import { Denied, NotFound, Page, SkeletonGrid } from "./components/ui.jsx";
import { Shell } from "./components/Shell.jsx";
import { DEFAULT_PREFERENCES } from "./config.js";
import { useLiveRefresh } from "./hooks/useLiveRefresh.js";
import { panelClassName, panelStyle } from "./utils/control.js";
import DashboardPage from "./pages/DashboardPage.jsx";
import ControlsPage from "./pages/ControlsPage.jsx";
import InvitesPage from "./pages/InvitesPage.jsx";
import UsersPage from "./pages/UsersPage.jsx";
import FriendsPage from "./pages/FriendsPage.jsx";
import MessagesPage from "./pages/MessagesPage.jsx";
import ProfilePage from "./pages/ProfilePage.jsx";
import AppearancePage from "./pages/AppearancePage.jsx";
import DiagnosticsPage from "./pages/DiagnosticsPage.jsx";
import AccountsPage from "./pages/AccountsPage.jsx";
import DatabasesPage from "./pages/DatabasesPage.jsx";
import GalleryAdminPage from "./pages/GalleryAdminPage.jsx";
import LumisoundAdminPage from "./pages/LumisoundAdminPage.jsx";
import IntelPage from "./pages/IntelPage.jsx";
import AuthPage from "./pages/AuthPage.jsx";

const BOOT_TIPS = [
  "Fleet Pulse now separates the current session lane from fleet-wide queue totals.",
  "Dashboard snapshots keep loading behind the glass while the command deck initializes.",
  "Saved homes, feedback channels, and queue defaults are prefetched during startup.",
  "Admin mode unlocks diagnostics, account tools, and gallery command routing.",
];
const BOOT_MIN_VISIBLE_MS = 700;
const BOOT_GUEST_MIN_VISIBLE_MS = 360;
const BOOT_MAX_BLOCKING_WAIT_MS = 1800;
const LIVE_DASHBOARD_CACHE_TTL = 4_000;
const LIVE_DASHBOARD_STALE_TTL = 10_000;
const LIVE_BOTS_CACHE_TTL = 5_000;
const LIVE_BOTS_STALE_TTL = 15_000;

function delay(ms) {
  return new Promise((resolve) => window.setTimeout(resolve, ms));
}

function App() {
  const navigate = useNavigate();
  const location = useLocation();
  const [token, setToken] = useState(() => readToken());
  const [session, setSession] = useState({ authenticated: false, loading: true });
  const [preferences, setPreferences] = useState(DEFAULT_PREFERENCES);
  const [toast, setToast] = useState(null);
  const [bootPhase, setBootPhase] = useState("Authorizing operator");
  const [bootTipIndex, setBootTipIndex] = useState(0);
  const [bootDismissed, setBootDismissed] = useState(false);
  const [bootLeaving, setBootLeaving] = useState(false);
  const [backendUnreachable, setBackendUnreachable] = useState(() => isBackendUnreachable());
  const isAdmin = Boolean(session.admin_mode);
  const isOwner = Boolean(session.site_owner);
  const canGallery = Boolean(session.image_gallery_owner);

  const showToast = useCallback((message, tone = "info") => {
    setToast({ message, tone, id: Date.now() });
  }, []);

  const loadSession = useCallback(async () => {
    try {
      const data = await apiFetch("/api/session", { timeoutMs: 6_000 });
      if (data.authenticated && data.token) {
        writeToken(data.token);
        writeUsername(data.username);
        setToken(data.token);
      }
      setSession({ ...data, loading: false });
    } catch (error) {
      // Only clear authentication on an explicit auth rejection (401/403).
      // Transient network failures, tunnel rotations, and backend restarts must NOT
      // log the user out — their session is still valid, the backend is just briefly
      // unreachable.  Keep the current session state and just unblock any loading spinner.
      if (error?.status === 401 || error?.status === 403) {
        setSession({ authenticated: false, loading: false });
      } else {
        setSession((prev) => (prev.loading ? { ...prev, loading: false } : prev));
      }
    }
  }, []);

  const loadPreferences = useCallback(async () => {
    if (!readToken()) return;
    try {
      const data = await cachedFetch("/api/users/preferences", { ttl: 30_000, staleTtl: 180_000, storage: "local" });
      setPreferences({ ...DEFAULT_PREFERENCES, ...(data.preferences || {}) });
    } catch (_error) {
      setPreferences(DEFAULT_PREFERENCES);
    }
  }, []);

  useEffect(() => {
    loadSession();
  }, [loadSession]);

  // Hard cap: if session hasn't resolved within 4s, unblock the UI anyway
  useEffect(() => {
    const cap = window.setTimeout(() => {
      setSession((prev) => (prev.loading ? { ...prev, loading: false } : prev));
    }, 4_000);
    return () => window.clearTimeout(cap);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    if (token) loadPreferences();
  }, [loadPreferences, token]);

  useEffect(() => subscribeBackendStatus(setBackendUnreachable), []);

  useLiveRefresh(loadSession, { interval: 20_000 });
  useLiveRefresh(loadPreferences, { enabled: Boolean(token), interval: 30_000 });

  useEffect(() => {
    if (!token) return;
    const guildId = session.guild_id || session.account_guild_id;
    prefetchFetch("/api/bots", { ttl: LIVE_BOTS_CACHE_TTL, staleTtl: LIVE_BOTS_STALE_TTL, storage: "local" });
    prefetchFetch("/api/dashboard", { ttl: LIVE_DASHBOARD_CACHE_TTL, staleTtl: LIVE_DASHBOARD_STALE_TTL });
    prefetchFetch("/api/users/me", { ttl: 30_000, staleTtl: 120_000 });
    prefetchFetch(`/api/music-intelligence${query({ guild_id: guildId, limit: 10 })}`, { ttl: 20_000, staleTtl: 120_000 });
  }, [session.account_guild_id, session.guild_id, token]);

  useEffect(() => {
    if (!toast) return undefined;
    const timer = window.setTimeout(() => setToast(null), 3600);
    return () => window.clearTimeout(timer);
  }, [toast]);

  useEffect(() => {
    if (bootDismissed) return undefined;
    const timer = window.setInterval(() => {
      setBootTipIndex((current) => (current + 1) % BOOT_TIPS.length);
    }, 3200);
    return () => window.clearInterval(timer);
  }, [bootDismissed]);

  useEffect(() => {
    if (bootDismissed || session.loading) {
      if (session.loading) setBootPhase("Authorizing operator");
      return undefined;
    }
    let cancelled = false;
    const startedAt = Date.now();
    const guildId = session.guild_id || session.account_guild_id;
    const finishBoot = async (minimumVisibleMs = BOOT_MIN_VISIBLE_MS) => {
      const remaining = Math.max(0, minimumVisibleMs - (Date.now() - startedAt));
      if (remaining) {
        await delay(remaining);
      }
      if (cancelled) return;
      setBootLeaving(true);
      window.setTimeout(() => {
        if (cancelled) return;
        setBootDismissed(true);
        setBootLeaving(false);
      }, 420);
    };

    const primeDeck = async () => {
      if (!session.authenticated || !token) {
        setBootPhase("Opening guest deck");
        await finishBoot(BOOT_GUEST_MIN_VISIBLE_MS);
        return;
      }
      const criticalWarmups = [
        cachedFetch("/api/users/preferences", { ttl: 30_000, staleTtl: 180_000, storage: "local" }),
        cachedFetch("/api/bots", { ttl: LIVE_BOTS_CACHE_TTL, staleTtl: LIVE_BOTS_STALE_TTL, storage: "local" }),
        cachedFetch("/api/dashboard", { ttl: LIVE_DASHBOARD_CACHE_TTL, staleTtl: LIVE_DASHBOARD_STALE_TTL }),
      ];
      prefetchFetch("/api/users/me", { ttl: 30_000, staleTtl: 120_000 });
      prefetchFetch(`/api/music-intelligence${query({ guild_id: guildId, limit: 10 })}`, { ttl: 20_000, staleTtl: 120_000 });
      if (isAdmin) prefetchFetch("/api/telegram/status", { ttl: 30_000, staleTtl: 120_000 });
      setBootPhase("Caching command deck");
      await Promise.race([
        Promise.allSettled(criticalWarmups),
        delay(BOOT_MAX_BLOCKING_WAIT_MS),
      ]);
      if (cancelled) return;
      setBootPhase("Streaming live telemetry");
      setBootPhase("Projecting command deck");
      await finishBoot();
    };

    primeDeck();
    return () => {
      cancelled = true;
    };
  }, [bootDismissed, isAdmin, session.account_guild_id, session.authenticated, session.guild_id, session.loading, token]);

  const loginWith = useCallback((payload) => {
    writeToken(payload.token);
    writeUsername(payload.username);
    clearCache();
    setToken(payload.token);
    setSession({
      authenticated: true,
      loading: false,
      username: payload.username,
      role: payload.role,
      guild_id: payload.guild_id,
      account_guild_id: payload.account_guild_id,
      site_owner: payload.site_owner,
      admin_mode: payload.admin_mode,
      image_gallery_owner: payload.image_gallery_owner,
      pages_public_url: payload.pages_public_url,
    });
    showToast(`Signed in as ${payload.username}.`, "success");
    setBootDismissed(false);
    setBootLeaving(false);
    setBootPhase("Syncing fleet telemetry");
    setBootTipIndex(0);
    navigate("/");
  }, [navigate, showToast]);

  const logout = useCallback(async () => {
    try {
      await apiFetch("/api/session/logout", { method: "POST" });
    } catch (_error) {
      // Token cleanup still happens locally.
    }
    writeToken("");
    writeUsername("");
    clearCache();
    setToken("");
    setSession({ authenticated: false, loading: false });
    navigate("/login");
  }, [navigate]);

  const switchAdminMode = useCallback(async (enabled) => {
    try {
      const data = await apiFetch("/api/session/admin-mode", {
        method: "POST",
        body: JSON.stringify({ enabled }),
      });
      writeToken(data.token);
      setToken(data.token);
      clearCache();
      setSession((current) => ({ ...current, ...data, authenticated: true, loading: false }));
      showToast(enabled ? "Admin mode enabled." : "Admin mode disabled.", "success");
    } catch (error) {
      showToast(error.message, "error");
    }
  }, [showToast]);

  const ctx = useMemo(() => ({
    token,
    session,
    preferences,
    setPreferences,
    loginWith,
    logout,
    loadSession,
    loadPreferences,
    switchAdminMode,
    showToast,
    isAdmin,
    isOwner,
    canGallery,
  }), [canGallery, isAdmin, isOwner, loadPreferences, loadSession, loginWith, logout, preferences, session, showToast, switchAdminMode, token]);

  const notifyPos = preferences?.notification_position || "br";
  const notifyClass = notifyPos === "br" ? "" : `panel-notify-${notifyPos}`;
  return (
    <div className={`${panelClassName(preferences)} ${notifyClass}`.trim()} style={panelStyle(preferences)}>
      <Shell ctx={ctx}>
        <RouteViewport ctx={ctx} pathname={location.pathname} />
      </Shell>
      {!bootDismissed ? (
        <SwarmBootOverlay
          authenticated={session.authenticated}
          leaving={bootLeaving}
          phase={bootPhase}
          tip={BOOT_TIPS[bootTipIndex]}
        />
      ) : null}
      {bootDismissed && backendUnreachable ? <SwarmReconnectOverlay /> : null}
      {toast ? <div role="status" aria-live="polite" aria-atomic="true" className={`toast toast-${toast.tone}`}>{toast.message}</div> : null}
    </div>
  );
}

function SwarmBootOverlay({ phase, tip, authenticated, leaving }) {
  return (
    <div
      aria-busy="true"
      aria-live="polite"
      className={`swarm-loading-screen ${leaving ? "is-leaving" : ""}`}
      role="status"
    >
      <div className="swarm-loading-backdrop" />
      <section className="swarm-loading-panel">
        <div className="swarm-loading-hero">
          <div className="swarm-loading-radar" aria-hidden="true">
            <span className="swarm-loading-ring ring-a" />
            <span className="swarm-loading-ring ring-b" />
            <span className="swarm-loading-ring ring-c" />
            <span className="swarm-loading-sweep" />
            <span className="swarm-loading-core" />
          </div>
          <div className="swarm-loading-copy">
            <span className="swarm-loading-kicker">SwarmPanel // Fleet Command</span>
            <strong>{phase}</strong>
            <p>
              {authenticated
                ? "The command deck is opening now. Slower telemetry can keep hydrating in the background after the shell appears."
                : "The panel shell is coming online and preparing a guest deck."}
            </p>
          </div>
        </div>
        <div className="swarm-loading-status-grid">
          <article>
            <span>Session Link</span>
            <strong>{authenticated ? "Authenticated" : "Guest Deck"}</strong>
            <small>{authenticated ? "Command identity verified." : "Browsing without admin access."}</small>
          </article>
          <article>
            <span>Telemetry</span>
            <strong>Progressive Load</strong>
            <small>Core cards unlock first, then live queue and fleet telemetry continue warming behind the shell.</small>
          </article>
          <article>
            <span>Tip Deck</span>
            <strong>Rotating</strong>
            <small>{tip}</small>
          </article>
        </div>
        <div className="swarm-loading-progress" aria-hidden="true">
          <span />
        </div>
      </section>
    </div>
  );
}

function SwarmReconnectOverlay() {
  return (
    <div aria-busy="true" aria-live="polite" className="swarm-loading-screen swarm-reconnect-overlay" role="status">
      <div className="swarm-loading-backdrop" />
      <section className="swarm-loading-panel">
        <div className="swarm-loading-hero">
          <div className="swarm-loading-radar" aria-hidden="true">
            <span className="swarm-loading-ring ring-a" />
            <span className="swarm-loading-ring ring-b" />
            <span className="swarm-loading-ring ring-c" />
            <span className="swarm-loading-sweep" />
            <span className="swarm-loading-core" />
          </div>
          <div className="swarm-loading-copy">
            <span className="swarm-loading-kicker">SwarmPanel // Fleet Command</span>
            <strong>Reconnecting to the live backend</strong>
            <p>SwarmPanel lost contact with the live backend. The tunnel may be briefly restarting — this screen will clear automatically once the connection is restored.</p>
          </div>
        </div>
        <div className="swarm-loading-status-grid">
          <article>
            <span>Session Link</span>
            <strong>Reconnecting</strong>
            <small>Waiting for the live backend to respond again.</small>
          </article>
          <article>
            <span>Telemetry</span>
            <strong>Paused</strong>
            <small>Dashboard and queue data will resume streaming once the link is restored.</small>
          </article>
          <article>
            <span>Status</span>
            <strong>Auto-Retry</strong>
            <small>No action needed — SwarmPanel keeps retrying in the background.</small>
          </article>
        </div>
        <div className="swarm-loading-progress" aria-hidden="true">
          <span />
        </div>
      </section>
    </div>
  );
}

class RouteErrorBoundary extends React.Component {
  constructor(props) {
    super(props);
    this.state = { error: null };
  }

  static getDerivedStateFromError(error) {
    return { error };
  }

  componentDidUpdate(prevProps) {
    if (prevProps.pathname !== this.props.pathname && this.state.error) {
      this.setState({ error: null });
    }
  }

  render() {
    if (this.state.error) {
      return (
        <Page title="Panel View Failed" eyebrow="Frontend Recovery" lede="This section hit a client-side render problem, but the rest of SwarmPanel is still online.">
          <div className="notice notice-error">
            {this.state.error?.message || "A route failed to render."}
          </div>
        </Page>
      );
    }
    return this.props.children;
  }
}

function Protected({ ctx, children, admin = false, gallery = false }) {
  const location = useLocation();
  if (ctx.session.loading) return <Page title="Loading" eyebrow="Session"><SkeletonGrid count={4} /></Page>;
  if (!ctx.session.authenticated) return <Navigate to="/login" replace />;
  if (admin && !ctx.isAdmin) return <Denied message="Admin mode is required." />;
  if (gallery && !ctx.canGallery) return <Denied message="Image Gallery owner access is required." />;
  return <RouteErrorBoundary pathname={location.pathname}>{children}</RouteErrorBoundary>;
}

export default App;

function normalizePathname(pathname) {
  const normalized = String(pathname || "").replace(/\/+$/, "");
  return normalized || "/";
}

function RouteViewport({ ctx, pathname }) {
  const currentPath = normalizePathname(pathname);

  if (currentPath === "/login") {
    return ctx.session.authenticated ? <Navigate to="/" replace /> : <AuthPage ctx={ctx} />;
  }
  if (currentPath === "/" || currentPath === "/dashboard") {
    return (
      <Protected ctx={ctx}>
        <DashboardPage ctx={ctx} />
      </Protected>
    );
  }
  if (currentPath === "/controls") {
    return (
      <Protected ctx={ctx}>
        <ControlsPage ctx={ctx} />
      </Protected>
    );
  }
  if (currentPath === "/invites") {
    return (
      <Protected ctx={ctx}>
        <InvitesPage ctx={ctx} />
      </Protected>
    );
  }
  if (currentPath === "/users") {
    return (
      <Protected ctx={ctx}>
        <UsersPage ctx={ctx} />
      </Protected>
    );
  }
  if (currentPath === "/friends") {
    return (
      <Protected ctx={ctx}>
        <FriendsPage ctx={ctx} />
      </Protected>
    );
  }
  if (currentPath === "/messages") {
    return (
      <Protected ctx={ctx}>
        <MessagesPage ctx={ctx} />
      </Protected>
    );
  }
  if (currentPath === "/profile" || /^\/users\/[^/]+$/.test(currentPath)) {
    return (
      <Protected ctx={ctx}>
        <ProfilePage ctx={ctx} />
      </Protected>
    );
  }
  if (currentPath === "/appearance") {
    return (
      <Protected ctx={ctx}>
        <AppearancePage ctx={ctx} />
      </Protected>
    );
  }
  if (currentPath === "/diagnostics") {
    return (
      <Protected ctx={ctx} admin>
        <DiagnosticsPage ctx={ctx} />
      </Protected>
    );
  }
  if (currentPath === "/accounts") {
    return (
      <Protected ctx={ctx} admin>
        <AccountsPage ctx={ctx} />
      </Protected>
    );
  }
  if (currentPath === "/databases") {
    return (
      <Protected ctx={ctx} admin>
        <DatabasesPage ctx={ctx} />
      </Protected>
    );
  }
  if (currentPath === "/gallery-admin") {
    return (
      <Protected ctx={ctx} gallery>
        <GalleryAdminPage ctx={ctx} />
      </Protected>
    );
  }
  if (currentPath === "/lumisound-admin") {
    return (
      <Protected ctx={ctx} admin>
        <LumisoundAdminPage ctx={ctx} />
      </Protected>
    );
  }
  if (currentPath === "/intel") {
    return (
      <Protected ctx={ctx} admin>
        <IntelPage ctx={ctx} />
      </Protected>
    );
  }
  return <NotFound />;
}
