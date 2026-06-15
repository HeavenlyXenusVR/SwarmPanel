import { Lock, Sparkles } from "lucide-react";
import { number, titleCase } from "../utils/format.js";

export function Choice({ label, value, values, onChange }) {
  const selected = values.includes(value) ? value : values[0];
  return (
    <label className="field">
      <span>{label}</span>
      <select value={selected} onChange={(event) => onChange(event.target.value)}>
        {values.map((item) => <option key={item} value={item}>{titleCase(item)}</option>)}
      </select>
    </label>
  );
}

export function Page({ title, eyebrow, lede = "", actions, className = "", children }) {
  return (
    <div className={`page ${className}`.trim()}>
      <header className="page-head">
        <div>
          <p>{eyebrow}</p>
          <h1>{title}</h1>
          {lede ? <span className="page-lede">{lede}</span> : null}
        </div>
        {actions ? <div className="page-actions">{actions}</div> : null}
      </header>
      {children}
    </div>
  );
}

export function SectionHead({ title, count }) {
  return <div className="section-head"><h2>{title}</h2>{count !== undefined ? <span>{count}</span> : null}</div>;
}

export function MetricGrid({ children }) {
  return <section className="metric-grid">{children}</section>;
}

export function Metric({ icon: Icon, label, value }) {
  return <article className="metric"><Icon size={19} /><div><strong>{typeof value === "string" ? value : number(value)}</strong><span>{label}</span></div></article>;
}

export function Notice({ tone = "info", children }) {
  return <div className={`notice notice-${tone}`}>{children}</div>;
}

export function EmptyState({ title, compact = false }) {
  return <div className={`empty-state ${compact ? "compact" : ""}`}><Sparkles size={22} /><h2>{title}</h2></div>;
}

export function Denied({ message }) {
  return <Page title="Access Locked" eyebrow="Permissions"><div className="empty-state"><Lock size={28} /><h2>{message}</h2></div></Page>;
}

export function NotFound() {
  return <Page title="Not Found" eyebrow="404"><EmptyState title="That panel page is not available" /></Page>;
}

export function SkeletonGrid({ count = 6 }) {
  const tips = [
    "Live bot state refreshes in the background.",
    "Saved homes and feedback channels can prefill playback controls.",
    "Queue orders from the panel default to loop queue.",
  ];
  return (
    <div>
      <div className="loading-tip">{tips[count % tips.length]}</div>
      <div className="skeleton-grid">{Array.from({ length: count }, (_, index) => <div className="skeleton-card" key={`skel-${index}`} />)}</div>
    </div>
  );
}

export function SectionLoadingScreen({
  title = "Loading section",
  tip = "SwarmPanel is syncing the latest data for this view.",
  count = 3,
  compact = false,
}) {
  return (
    <div className={`section-loading-screen ${compact ? "compact" : ""}`}>
      <div className="section-loading-copy">
        <strong>{title}</strong>
        <p>{tip}</p>
      </div>
      <div className={`section-loading-grid ${compact ? "compact" : ""}`}>
        {Array.from({ length: count }, (_, index) => <div className="section-loading-card" key={`load-${index}`} />)}
      </div>
    </div>
  );
}

export function LoadingSection({
  loading = false,
  title,
  tip,
  count = 3,
  compact = false,
  className = "",
  minHeight = 220,
  children,
}) {
  return (
    <div
      className={`loading-section ${loading ? "is-loading" : "is-ready"} ${className}`.trim()}
      style={{ "--loading-min-height": `${Math.max(120, Number(minHeight) || 220)}px` }}
      aria-busy={loading ? "true" : "false"}
    >
      <div className="loading-section-content">{children}</div>
      <div className="loading-section-overlay" aria-hidden={loading ? "false" : "true"}>
        <SectionLoadingScreen title={title} tip={tip} count={count} compact={compact} />
      </div>
    </div>
  );
}

export function Segmented({ value, onChange, options }) {
  return (
    <div className="segmented" role="group">
      {options.map(([key, label]) => (
        <button
          className={value === key ? "active" : ""}
          type="button"
          aria-pressed={value === key}
          onClick={() => onChange(key)}
          key={key}
        >
          {label}
        </button>
      ))}
    </div>
  );
}
