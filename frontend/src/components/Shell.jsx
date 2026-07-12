import { useEffect, useMemo, useState } from "react";
import { Link, NavLink, useLocation } from "react-router-dom";
import {
  Database,
  HeartPulse,
  Image as ImageIcon,
  LayoutDashboard,
  ListChecks,
  LogIn,
  LogOut,
  Menu,
  MessageCircle,
  Music,
  Palette,
  Play,
  PlugZap,
  Shield,
  Siren,
  Sparkles,
  UserRound,
  Users,
} from "lucide-react";

export function Shell({ ctx, children }) {
  const location = useLocation();
  const [mobileNavOpen, setMobileNavOpen] = useState(false);
  const authenticated = ctx.session.authenticated;
  const username = ctx.session.username || "Operator";
  const navItems = useMemo(() => {
    const items = [
      { to: "/", icon: LayoutDashboard, label: "Dashboard", mobileLabel: "Deck" },
      { to: "/controls", icon: Play, label: "Controls", mobileLabel: "Play" },
      { to: "/invites", icon: PlugZap, label: "Invites", mobileLabel: "Invites" },
      { to: "/users", icon: Users, label: "Users", mobileLabel: "Users" },
      { to: "/friends", icon: UserRound, label: "Friends", mobileLabel: "Friends" },
      { to: "/messages", icon: MessageCircle, label: "Messages", mobileLabel: "Inbox" },
      { to: "/profile", icon: UserRound, label: "Profile", mobileLabel: "Me" },
      { to: "/appearance", icon: Palette, label: "Look", mobileLabel: "Look" },
    ];
    if (ctx.isAdmin) items.push({ to: "/diagnostics", icon: HeartPulse, label: "Diagnostics", mobileLabel: "Health" });
    if (ctx.isAdmin) items.push({ to: "/accounts", icon: Shield, label: "Accounts", mobileLabel: "Accounts" });
    if (ctx.isAdmin) items.push({ to: "/databases", icon: Database, label: "Data", mobileLabel: "Data" });
    if (ctx.canGallery) items.push({ to: "/gallery-admin", icon: ImageIcon, label: "Gallery", mobileLabel: "Gallery" });
    if (ctx.isAdmin) items.push({ to: "/lumisound-admin", icon: Music, label: "Lumisound", mobileLabel: "Music" });
    if (ctx.isAdmin) items.push({ to: "/intel", icon: Siren, label: "Intel", mobileLabel: "Intel" });
    if (ctx.isAdmin) items.push({ to: "/audit-log", icon: ListChecks, label: "Audit Log", mobileLabel: "Audit" });
    return items;
  }, [ctx.canGallery, ctx.isAdmin]);
  const mobilePrimaryItems = navItems.filter((item) => ["/", "/controls", "/users", "/messages", "/profile"].includes(item.to));
  const mobileSecondaryItems = navItems.filter((item) => !mobilePrimaryItems.some((primary) => primary.to === item.to));
  const isMoreActive = mobileSecondaryItems.some((item) => isActivePath(location.pathname, item.to));

  useEffect(() => {
    setMobileNavOpen(false);
  }, [location.pathname]);

  useEffect(() => {
    if (!mobileNavOpen) return undefined;
    const previousOverflow = document.body.style.overflow;
    const onKeyDown = (event) => {
      if (event.key === "Escape") setMobileNavOpen(false);
    };
    document.body.style.overflow = "hidden";
    window.addEventListener("keydown", onKeyDown);
    return () => {
      document.body.style.overflow = previousOverflow;
      window.removeEventListener("keydown", onKeyDown);
    };
  }, [mobileNavOpen]);

  return (
    <>
      <header className="topbar">
        <Link className="brand" to="/">
          <span className="brand-mark"><Sparkles size={18} /></span>
          <span className="brand-copy">
            <strong>SwarmPanel</strong>
            <small>Fleet Command</small>
          </span>
        </Link>
        {authenticated ? (
          <nav className="nav nav-desktop" aria-label="Main">
            {navItems.map((item) => <NavItem key={item.to} to={item.to} icon={item.icon} label={item.label} />)}
          </nav>
        ) : <div />}
        <div className="session-bar">
          {authenticated ? (
            <>
              <span className={`mode-pill ${ctx.isAdmin ? "admin" : ""}`}>{ctx.isAdmin ? "Admin" : "User"}</span>
              {ctx.isOwner ? (
                <button
                  aria-label="Admin"
                  className={`mode-toggle ${ctx.isAdmin ? "active" : ""}`}
                  type="button"
                  onClick={() => ctx.switchAdminMode(!ctx.isAdmin)}
                >
                  {ctx.isAdmin ? "Admin On" : "Admin Off"}
                </button>
              ) : null}
              <Link className="profile-link" to="/profile">
                <span className="profile-link-badge">{username.slice(0, 1).toUpperCase()}</span>
                <span>{username}</span>
              </Link>
              <button className="icon-button" type="button" aria-label="Logout" onClick={ctx.logout} title="Logout"><LogOut size={18} /></button>
            </>
          ) : location.pathname !== "/login" ? (
            <Link className="button-link primary" to="/login"><LogIn size={16} />Login</Link>
          ) : null}
        </div>
      </header>
      {authenticated ? (
        <>
          <nav className="nav nav-mobile" aria-label="Mobile Main">
            {mobilePrimaryItems.map((item) => <NavItem key={item.to} to={item.to} icon={item.icon} label={item.mobileLabel || item.label} />)}
            <button
              aria-expanded={mobileNavOpen}
              aria-label="More navigation"
              className={`nav-item mobile-nav-launcher ${mobileNavOpen || isMoreActive ? "active" : ""}`}
              type="button"
              onClick={() => setMobileNavOpen((current) => !current)}
            >
              <Menu size={17} />
              <span>More</span>
            </button>
          </nav>
          <div
            aria-hidden={!mobileNavOpen}
            className={`mobile-nav-backdrop ${mobileNavOpen ? "open" : ""}`}
            onClick={() => setMobileNavOpen(false)}
          />
          <aside
            aria-hidden={!mobileNavOpen}
            className={`mobile-nav-sheet ${mobileNavOpen ? "open" : ""}`}
          >
            <div className="mobile-nav-sheet-head">
              <div>
                <strong>Command Access</strong>
                <p>Jump to the rest of the panel without fighting a crowded dock.</p>
              </div>
              <button type="button" onClick={() => setMobileNavOpen(false)}>Close</button>
            </div>
            <div className="mobile-session-chip">
              <span className={`mode-pill ${ctx.isAdmin ? "admin" : ""}`}>{ctx.isAdmin ? "Admin" : "User"}</span>
              <span>{username}</span>
            </div>
            <nav className="mobile-nav-list" aria-label="More Navigation">
              {mobileSecondaryItems.map((item) => <NavItem key={item.to} to={item.to} icon={item.icon} label={item.label} />)}
            </nav>
          </aside>
        </>
      ) : null}
      <main className="stage">{children}</main>
      <footer className="site-footer">
        <span>SwarmPanel // HeavenlyXenusVR</span>
        <a href="https://discord.com/users/1304564041863266347" target="_blank" rel="noreferrer">Discord</a>
      </footer>
    </>
  );
}

function NavItem({ to, icon: Icon, label }) {
  return (
    <NavLink className={({ isActive }) => `nav-item ${isActive ? "active" : ""}`} to={to} end={to === "/"}>
      <Icon size={17} />
      <span>{label}</span>
    </NavLink>
  );
}

function isActivePath(pathname, to) {
  if (to === "/") return pathname === "/";
  return pathname === to || pathname.startsWith(`${to}/`);
}
