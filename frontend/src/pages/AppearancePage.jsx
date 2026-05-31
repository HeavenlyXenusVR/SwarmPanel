import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import {
  Activity,
  Bot,
  BrushCleaning,
  Check,
  Database,
  Eye,
  HeartPulse,
  Image as ImageIcon,
  Play,
  RotateCcw,
  Save,
  Sparkles,
  SlidersHorizontal,
} from "lucide-react";
import { apiFetch, clearCache } from "../api.js";
import { DEFAULT_PREFERENCES } from "../config.js";
import { Choice, Notice, Page, Segmented } from "../components/ui.jsx";
import { panelClassName, panelStyle, profileSurfaceStyle } from "../utils/control.js";

const LOOK_PRESETS = [
  {
    id: "command",
    title: "Command Deck",
    note: "Balanced fleet telemetry with the default deck footprint.",
    patch: {
      theme_mode: "dark",
      accent_color: "#89b4fa",
      background_mode: "default",
      layout_mode: "standard",
      density: "comfortable",
      stream_card_style: "telemetry",
      dashboard_density: "command",
      motion: "standard",
    },
  },
  {
    id: "signal",
    title: "Signal Glass",
    note: "Aurora glow, tighter surfaces, and a cleaner roster read.",
    patch: {
      theme_mode: "dark",
      accent_color: "#7ee787",
      background_mode: "aurora",
      layout_mode: "focused",
      density: "compact",
      stream_card_style: "compact",
      dashboard_density: "dense",
      tab_style: "underline",
      surface_opacity: 0.86,
      surface_blur: 24,
    },
  },
  {
    id: "owner",
    title: "Owner Lounge",
    note: "Warmer accenting for profile and admin-heavy panel sessions.",
    patch: {
      theme_mode: "dark",
      accent_color: "#ffd166",
      background_mode: "ember",
      layout_mode: "wide",
      density: "comfortable",
      stream_card_style: "cinematic",
      roster_layout: "signals",
      operator_layout: "console",
      surface_opacity: 0.94,
      surface_blur: 18,
    },
  },
];

const PREVIEW_MODES = [
  ["live", "Live"],
  ["queues", "Queues"],
  ["medic", "Medic"],
  ["owner", "Owner"],
];

function clampHex(value, fallback = "#89b4fa") {
  const text = String(value || "").trim();
  return /^#[0-9a-fA-F]{6}$/.test(text) ? text : fallback;
}

function formatPercent(value) {
  return `${Math.round(Number(value || 0) * 100)}%`;
}

function previewModeCopy(mode, draft) {
  if (mode === "queues") {
    return {
      kicker: "Queue Watch",
      headline: "Queue pressure and fallback lanes",
      copy: `${draft.roster_layout} roster surfaces with ${draft.dashboard_density} queue density and ${draft.layout_mode} deck spacing.`,
      cards: [
        { icon: Play, title: "Queue Lane", body: "console operator / 14 queued", chips: ["14 queued", "4 backup", "loop queue"] },
        { icon: Bot, title: "Fallback Bot", body: "Aria watching recovery lane", chips: ["aria", "recovery", "stable"] },
        { icon: Activity, title: "Spillover", body: `${draft.density} density / ${draft.tab_style} tabs`, chips: ["pressure 63%", "signals", "warm"] },
      ],
      profileLabel: "Profile spotlight stays ambient while queue cards carry the higher contrast load.",
    };
  }
  if (mode === "medic") {
    return {
      kicker: "Medic Channel",
      headline: "Recovery, diagnostics, and operator calm",
      copy: `${draft.motion} motion and ${draft.surface_blur}px blur tuned for slower diagnostic reading during incidents.`,
      cards: [
        { icon: HeartPulse, title: "Medic", body: "stable / session cleanup ready", chips: ["recovery", "stable", "db linked"] },
        { icon: Database, title: "DB", body: "writes healthy / cache warm", chips: ["mysql", "cache", "green"] },
        { icon: Activity, title: "Logs", body: `${draft.font_scale} type rhythm / ${formatPercent(draft.surface_opacity)} surface`, chips: ["tailing", "alerts", "clean"] },
      ],
      profileLabel: "Profiles keep their own backdrop, but the deck stays optimized for admin triage.",
    };
  }
  if (mode === "owner") {
    return {
      kicker: "Owner View",
      headline: "Identity, profile surfaces, and public presence",
      copy: `${draft.theme_mode} theme with ${draft.card_shape} cards and ${draft.operator_layout} operator voice for owner-facing sessions.`,
      cards: [
        { icon: Sparkles, title: "Identity", body: "public card / links / social stats", chips: ["owner", "public", "accent live"] },
        { icon: Bot, title: "Fleet Skin", body: `${draft.stream_card_style} card language`, chips: [draft.stream_card_style, draft.layout_mode, draft.tab_style] },
        { icon: ImageIcon, title: "Backdrop", body: draft.profile_backdrop_image_url ? "profile backdrop supplied" : "backdrop disabled", chips: [formatPercent(draft.profile_backdrop_strength), "profile", "ambient"] },
      ],
      profileLabel: "This preview tracks the profile surface below, so owner identity styling stays in sync.",
    };
  }
  return {
    kicker: "Live Deck",
    headline: draft.stream_card_style === "cinematic" ? "Cinematic fleet command" : draft.stream_card_style === "compact" ? "Compact fleet command" : "Telemetry fleet command",
    copy: `${draft.layout_mode} layout, ${draft.density} density, and ${draft.dashboard_density} dashboard spacing across the operator deck.`,
    cards: [
      { icon: Bot, title: "Telemetry Fleet", body: "12 bots / Lavalink online / Aria watching recovery", chips: ["fleet", "live", "healthy"] },
      { icon: Play, title: "Queue Health", body: `${draft.operator_layout} operator / ${draft.roster_layout} roster`, chips: [draft.theme_mode, draft.layout_mode, formatPercent(draft.surface_opacity)] },
      { icon: Activity, title: "Panel Feel", body: `${draft.motion} motion / ${draft.font_scale} type`, chips: [draft.card_shape, draft.tab_style, `${draft.surface_blur}px blur`] },
    ],
    profileLabel: "Public profile surfaces stay independent, but the deck tone and accent system remain shared.",
  };
}

export default function AppearancePage({ ctx }) {
  const [draft, setDraft] = useState(() => ({ ...DEFAULT_PREFERENCES, ...(ctx.preferences || {}) }));
  const [previewMode, setPreviewMode] = useState("live");
  const [saving, setSaving] = useState(false);
  const savedPreferences = { ...DEFAULT_PREFERENCES, ...(ctx.preferences || {}) };
  const hasChanges = JSON.stringify(draft) !== JSON.stringify(savedPreferences);
  const previewCopy = previewModeCopy(previewMode, draft);
  const previewClassName = panelClassName(draft).replace("app-shell", "appearance-preview-shell");
  const [primaryCard, secondaryCard, tertiaryCard] = previewCopy.cards;
  const PrimaryIcon = primaryCard.icon;
  const SecondaryIcon = secondaryCard.icon;
  const TertiaryIcon = tertiaryCard.icon;

  const ctxPreferences = ctx.preferences;
  useEffect(() => {
    setDraft({ ...DEFAULT_PREFERENCES, ...(ctxPreferences || {}) });
  }, [ctxPreferences]);

  function update(key, value) {
    setDraft((current) => ({ ...current, [key]: value }));
  }

  function applyPatch(patch) {
    setDraft((current) => ({ ...current, ...patch }));
  }

  function revertDraft() {
    setDraft(savedPreferences);
  }

  function loadDefaults() {
    setDraft(DEFAULT_PREFERENCES);
  }

  function clearBackgroundImage() {
    setDraft((current) => ({
      ...current,
      background_image_url: "",
      background_mode: current.background_mode === "custom_image" ? "default" : current.background_mode,
    }));
  }

  function clearProfileBackdrop() {
    update("profile_backdrop_image_url", "");
  }

  async function save(event) {
    event.preventDefault();
    setSaving(true);
    try {
      const data = await apiFetch("/api/users/preferences", { method: "POST", body: JSON.stringify(draft) });
      const nextPreferences = { ...DEFAULT_PREFERENCES, ...(data.preferences || draft) };
      ctx.setPreferences(nextPreferences);
      setDraft(nextPreferences);
      clearCache("/api/users/preferences");
      ctx.showToast("Appearance saved.", "success");
    } catch (error) {
      ctx.showToast(error.message, "error");
    } finally {
      setSaving(false);
    }
  }

  return (
    <Page
      title="Panel Look"
      eyebrow="Appearance"
      lede="Shape the deck, density, motion, and visual language of the control room."
      className="page-appearance"
    >
      <section className="settings-grid appearance-layout">
        <form className="panel form-panel appearance-form" onSubmit={save}>
          <div className="appearance-header-row">
            <div className="section-head"><h2><SlidersHorizontal size={18} /> Theme</h2></div>
            <div className="appearance-status-row">
              <span className={`appearance-draft-pill ${hasChanges ? "dirty" : "clean"}`}>
                {hasChanges ? "Unsaved changes" : "Saved look"}
              </span>
              <span className="appearance-value-pill">{draft.layout_mode}</span>
              <span className="appearance-value-pill">{draft.stream_card_style}</span>
            </div>
          </div>
          <Notice tone="info">
            Changes in this room stay local until you press Save. Revert returns to your saved panel look, while Defaults loads a clean baseline you can still tweak before saving.
          </Notice>
          <div className="appearance-cluster">
            <div className="appearance-cluster-head"><h3>Quick Presets</h3><p>Start from a fully wired look recipe, then fine-tune the controls below.</p></div>
            <div className="appearance-preset-grid">
              {LOOK_PRESETS.map((preset) => (
                <button className="appearance-preset-card" key={preset.id} onClick={() => applyPatch(preset.patch)} type="button">
                  <strong>{preset.title}</strong>
                  <span>{preset.note}</span>
                </button>
              ))}
            </div>
          </div>
          <div className="appearance-cluster">
            <div className="appearance-cluster-head"><h3>Foundation</h3><p>Theme mode, accent energy, and backdrop source.</p></div>
            <div className="three-col">
              <Choice label="Theme" value={draft.theme_mode} values={["dark", "light", "system"]} onChange={(value) => update("theme_mode", value)} />
              <label className="field">
                <span>Accent</span>
                <div className="appearance-color-row">
                  <input className="appearance-color-swatch" type="color" value={clampHex(draft.accent_color, "#89b4fa")} onChange={(event) => update("accent_color", event.target.value)} />
                  <input value={draft.accent_color || "#89b4fa"} onChange={(event) => update("accent_color", event.target.value)} placeholder="#89b4fa" />
                </div>
              </label>
              <Choice label="Background" value={draft.background_mode} values={["default", "midnight", "aurora", "ember", "custom_color", "custom_image"]} onChange={(value) => update("background_mode", value)} />
            </div>
            <div className="two-col">
              <label className="field">
                <span>Background Color</span>
                <div className="appearance-color-row">
                  <input className="appearance-color-swatch" type="color" value={clampHex(draft.background_color, "#0b0e18")} onChange={(event) => setDraft((current) => ({ ...current, background_color: event.target.value, background_mode: "custom_color" }))} />
                  <input value={draft.background_color || "#0b0e18"} onChange={(event) => setDraft((current) => ({ ...current, background_color: event.target.value, background_mode: "custom_color" }))} placeholder="#0b0e18" />
                </div>
              </label>
              <label className="field">
                <span>Background Image URL</span>
                <div className="field-inline">
                  <input value={draft.background_image_url || ""} onChange={(event) => setDraft((current) => ({ ...current, background_image_url: event.target.value, background_mode: event.target.value ? "custom_image" : current.background_mode }))} placeholder="https://..." />
                  <button className="field-inline-action" onClick={clearBackgroundImage} type="button">Clear</button>
                </div>
              </label>
            </div>
          </div>
          <div className="appearance-cluster">
            <div className="appearance-cluster-head"><h3>Profile Atmosphere</h3><p>Give public profiles their own ambient backdrop without changing the rest of the control room.</p></div>
            <div className="two-col">
              <label className="field">
                <span>Profile Backdrop URL</span>
                <div className="field-inline">
                  <input value={draft.profile_backdrop_image_url || ""} onChange={(event) => update("profile_backdrop_image_url", event.target.value)} placeholder="https://..." />
                  <button className="field-inline-action" onClick={clearProfileBackdrop} type="button">Clear</button>
                </div>
              </label>
              <label className="field field-range">
                <span>Backdrop Strength <strong>{formatPercent(draft.profile_backdrop_strength ?? 0.18)}</strong></span>
                <input type="range" min="0" max="0.55" step="0.01" value={draft.profile_backdrop_strength ?? 0.18} onChange={(event) => update("profile_backdrop_strength", Number(event.target.value))} />
              </label>
            </div>
          </div>
          <div className="appearance-cluster">
            <div className="appearance-cluster-head"><h3>Structure</h3><p>Control how much space the deck uses and how crowded the command surfaces feel.</p></div>
            <div className="three-col">
              <Choice label="Layout" value={draft.layout_mode} values={["standard", "focused", "wide"]} onChange={(value) => update("layout_mode", value)} />
              <Choice label="Density" value={draft.density} values={["comfortable", "compact"]} onChange={(value) => update("density", value)} />
              <Choice label="Cards" value={draft.card_shape} values={["soft", "crisp"]} onChange={(value) => update("card_shape", value)} />
              <Choice label="Font" value={draft.font_scale} values={["normal", "large", "dense"]} onChange={(value) => update("font_scale", value)} />
              <Choice label="Motion" value={draft.motion} values={["standard", "reduced"]} onChange={(value) => update("motion", value)} />
              <Choice label="Tabs" value={draft.tab_style} values={["rail", "underline", "minimal"]} onChange={(value) => update("tab_style", value)} />
            </div>
          </div>
          <div className="appearance-cluster">
            <div className="appearance-cluster-head"><h3>Command Language</h3><p>Decide how the operator deck, roster, and live bot cards should read at a glance.</p></div>
            <div className="three-col">
              <Choice label="Operator" value={draft.operator_layout} values={["command", "console", "compact"]} onChange={(value) => update("operator_layout", value)} />
              <Choice label="Roster" value={draft.roster_layout} values={["cards", "signals", "ledger"]} onChange={(value) => update("roster_layout", value)} />
              <Choice label="Bot Cards" value={draft.stream_card_style} values={["telemetry", "compact", "cinematic"]} onChange={(value) => update("stream_card_style", value)} />
              <Choice label="Bot Detail" value={draft.bot_card_detail ?? "full"} values={["full", "compact", "minimal"]} onChange={(value) => update("bot_card_detail", value)} />
              <Choice label="Dashboard" value={draft.dashboard_density} values={["command", "dense"]} onChange={(value) => update("dashboard_density", value)} />
              <label className="field field-range"><span>Opacity <strong>{formatPercent(draft.surface_opacity ?? 0.92)}</strong></span><input type="range" min="0.35" max="1" step="0.01" value={draft.surface_opacity ?? 0.92} onChange={(event) => update("surface_opacity", Number(event.target.value))} /></label>
              <label className="field field-range"><span>Blur <strong>{draft.surface_blur ?? 18}px</strong></span><input type="range" min="0" max="36" step="1" value={draft.surface_blur ?? 18} onChange={(event) => update("surface_blur", Number(event.target.value))} /></label>
            </div>
          </div>
          <div className="appearance-cluster">
            <div className="appearance-cluster-head"><h3>Navigation &amp; Sidebar</h3><p>Shape the navigation rail — how much space it takes, whether labels show, and how collapsed it gets.</p></div>
            <div className="three-col">
              <Choice label="Sidebar Style" value={draft.sidebar_style ?? "full"} values={["full", "icons", "minimal"]} onChange={(value) => update("sidebar_style", value)} />
              <label className="field check-row"><input type="checkbox" checked={Boolean(draft.compact_sidebar)} onChange={(event) => update("compact_sidebar", event.target.checked)} /><span>Compact Sidebar</span></label>
              <Choice label="Notification Spot" value={draft.notification_position ?? "br"} values={["br", "bl", "tr", "tc"]} onChange={(value) => update("notification_position", value)} />
            </div>
          </div>
          <div className="appearance-cluster">
            <div className="appearance-cluster-head"><h3>Typography &amp; Interaction</h3><p>Fine-tune how text is set and how cards respond to hover — from sharp engineering font to soft rounded strokes.</p></div>
            <div className="three-col">
              <Choice label="Panel Font" value={draft.panel_font_family ?? "system"} values={["system", "mono", "rounded"]} onChange={(value) => update("panel_font_family", value)} />
              <Choice label="Card Hover" value={draft.card_hover_effect ?? "lift"} values={["lift", "glow", "border", "none"]} onChange={(value) => update("card_hover_effect", value)} />
              <Choice label="Corner Radius" value={draft.panel_radius ?? "medium"} values={["none", "small", "medium", "large", "pill"]} onChange={(value) => update("panel_radius", value)} />
            </div>
          </div>
          <div className="appearance-cluster">
            <div className="appearance-cluster-head"><h3>Accent &amp; Glow</h3><p>Add a secondary accent for gradient fills and dual-tone glow effects across cards and borders.</p></div>
            <div className="two-col">
              <label className="field">
                <span>Secondary Accent</span>
                <div className="appearance-color-row">
                  <input className="appearance-color-swatch" type="color" value={clampHex(draft.accent_secondary, "#7c3aed")} onChange={(event) => update("accent_secondary", event.target.value)} />
                  <input value={draft.accent_secondary || ""} onChange={(event) => update("accent_secondary", event.target.value)} placeholder="Leave blank to disable" />
                  {draft.accent_secondary ? <button className="field-inline-action" type="button" onClick={() => update("accent_secondary", "")}>Clear</button> : null}
                </div>
              </label>
              <div className="appearance-cluster-toggles">
                <label className="field check-row"><input type="checkbox" checked={draft.show_bot_uptime !== false} onChange={(event) => update("show_bot_uptime", event.target.checked)} /><span>Show bot uptime on cards</span></label>
                <label className="field check-row"><input type="checkbox" checked={draft.show_queue_pressure !== false} onChange={(event) => update("show_queue_pressure", event.target.checked)} /><span>Show queue pressure metrics</span></label>
              </div>
            </div>
          </div>
          <div className="appearance-form-actions">
            <div className="actions-row">
              <button className="primary" disabled={saving || !hasChanges} type="submit"><Save size={16} />{saving ? "Saving..." : "Save"}</button>
              <button disabled={!hasChanges || saving} onClick={revertDraft} type="button"><RotateCcw size={16} />Revert</button>
              <button disabled={saving} onClick={loadDefaults} type="button"><BrushCleaning size={16} />Defaults</button>
            </div>
            <p className="muted">Save writes this look to your account. Revert restores the currently saved panel settings. Defaults loads the stock SwarmPanel baseline into the draft.</p>
          </div>
        </form>
        <aside className={`${previewClassName} panel appearance-preview`} style={panelStyle(draft)}>
          <div className="preview-topline"><span /> <strong>SwarmPanel</strong></div>
          <div className="appearance-preview-hero">
            <div>
              <span className="appearance-profile-kicker">{previewCopy.kicker}</span>
              <h3>{previewCopy.headline}</h3>
              <p className="appearance-preview-note">{previewCopy.copy}</p>
            </div>
            <div className="appearance-preview-meta">
              <span className="appearance-value-pill"><Eye size={14} /> live draft</span>
              <span className="appearance-value-pill"><Check size={14} /> {hasChanges ? "preview only" : "saved"}</span>
            </div>
          </div>
          <Segmented options={PREVIEW_MODES} onChange={setPreviewMode} value={previewMode} />
          <div className="appearance-preview-shell-panel">
            <div className="appearance-preview-shell-topbar">
              <span>SwarmPanel</span>
              <div className="chip-row">
                <span>{draft.theme_mode}</span>
                <span>{draft.layout_mode}</span>
                <span>{draft.density}</span>
              </div>
            </div>
            <div className="command-preview-grid">
              <article className="preview-card command-preview-primary">
                <div><PrimaryIcon size={18} /><strong>{primaryCard.title}</strong></div>
                <p>{primaryCard.body}</p>
                <div className="preview-meter"><span style={{ width: previewMode === "queues" ? "63%" : previewMode === "medic" ? "48%" : previewMode === "owner" ? "72%" : draft.dashboard_density === "dense" ? "62%" : "82%" }} /></div>
                <div className="chip-row">{primaryCard.chips.map((chip) => <span key={chip}>{chip}</span>)}</div>
              </article>
              <article className="preview-card">
                <div><SecondaryIcon size={18} /><strong>{secondaryCard.title}</strong></div>
                <p>{secondaryCard.body}</p>
                <div className="chip-row">{secondaryCard.chips.map((chip) => <span key={chip}>{chip}</span>)}</div>
              </article>
              <article className="preview-card">
                <div><TertiaryIcon size={18} /><strong>{tertiaryCard.title}</strong></div>
                <p>{tertiaryCard.body}</p>
                <div className="chip-row">{tertiaryCard.chips.map((chip) => <span key={chip}>{chip}</span>)}</div>
              </article>
              <article className="preview-card mini">
                <HeartPulse size={18} /><strong>Medic</strong><span>{draft.motion === "reduced" ? "calm" : "stable"}</span>
              </article>
              <article className="preview-card mini">
                <Database size={18} /><strong>DB</strong><span>{draft.surface_blur > 20 ? "buffered" : "writing"}</span>
              </article>
              <article className="preview-card mini">
                <Activity size={18} /><strong>Logs</strong><span>{draft.font_scale === "dense" ? "dense" : "live"}</span>
              </article>
            </div>
          </div>
          <section className="appearance-profile-preview" style={profileSurfaceStyle({ ...draft, accent_color: draft.accent_color || "#89b4fa" }, draft.accent_color || "#89b4fa")}>
            <span className="appearance-profile-kicker">Public Profile Surface</span>
            <article className="appearance-profile-hero">
              <div className="appearance-profile-avatar">HX</div>
              <div className="appearance-profile-copy">
                <strong>HeavenlyXenusVR</strong>
                <p>{previewCopy.profileLabel}</p>
              </div>
            </article>
            <div className="appearance-profile-stats">
              <span className="appearance-mini-stat">Followers 24</span>
              <span className="appearance-mini-stat">Friends 12</span>
              <span className="appearance-mini-stat">Plays 31k</span>
            </div>
          </section>
          <div className="appearance-preview-actions">
            <Link className="button-link" to="/profile">Open Profile Styling</Link>
            <p className="muted">Use the Profile page for banner style, card style, public links, social visibility, and profile-specific accent choices.</p>
          </div>
        </aside>
      </section>
    </Page>
  );
}
