import { useEffect, useState } from "react";
import { Activity, Bot, Database, HeartPulse, Play, RotateCcw, Save, SlidersHorizontal } from "lucide-react";
import { apiFetch, clearCache } from "../api.js";
import { DEFAULT_PREFERENCES } from "../config.js";
import { Choice, Page } from "../components/ui.jsx";
import { panelStyle } from "../utils/control.js";

export default function AppearancePage({ ctx }) {
  const [draft, setDraft] = useState(ctx.preferences);
  useEffect(() => setDraft(ctx.preferences), [ctx.preferences]);
  function update(key, value) {
    setDraft((current) => ({ ...current, [key]: value }));
  }
  function reset() {
    setDraft(DEFAULT_PREFERENCES);
    ctx.setPreferences(DEFAULT_PREFERENCES);
  }
  async function save(event) {
    event.preventDefault();
    try {
      const data = await apiFetch("/api/users/preferences", { method: "POST", body: JSON.stringify(draft) });
      ctx.setPreferences({ ...DEFAULT_PREFERENCES, ...(data.preferences || draft) });
      clearCache("/api/users/preferences");
      ctx.showToast("Appearance saved.", "success");
    } catch (error) {
      ctx.showToast(error.message, "error");
    }
  }
  return (
    <Page title="Panel Look" eyebrow="Appearance">
      <section className="settings-grid appearance-layout">
        <form className="panel form-panel appearance-form" onSubmit={save}>
          <div className="section-head"><h2><SlidersHorizontal size={18} /> Theme</h2></div>
          <div className="three-col">
            <Choice label="Theme" value={draft.theme_mode} values={["dark", "light", "system"]} onChange={(value) => update("theme_mode", value)} />
            <label className="field color-field"><span>Accent</span><input type="color" value={draft.accent_color || "#89b4fa"} onChange={(event) => update("accent_color", event.target.value)} /></label>
            <Choice label="Background" value={draft.background_mode} values={["default", "midnight", "aurora", "ember", "custom_color", "custom_image"]} onChange={(value) => update("background_mode", value)} />
          </div>
          <div className="two-col">
            <label className="field color-field"><span>Background Color</span><input type="color" value={draft.background_color || "#0b0e18"} onChange={(event) => setDraft((current) => ({ ...current, background_color: event.target.value, background_mode: "custom_color" }))} /></label>
            <label className="field"><span>Background Image URL</span><input value={draft.background_image_url || ""} onChange={(event) => setDraft((current) => ({ ...current, background_image_url: event.target.value, background_mode: event.target.value ? "custom_image" : current.background_mode }))} /></label>
          </div>
          <div className="three-col">
            <Choice label="Layout" value={draft.layout_mode} values={["standard", "focused", "wide"]} onChange={(value) => update("layout_mode", value)} />
            <Choice label="Density" value={draft.density} values={["comfortable", "compact"]} onChange={(value) => update("density", value)} />
            <Choice label="Cards" value={draft.card_shape} values={["soft", "crisp"]} onChange={(value) => update("card_shape", value)} />
            <Choice label="Font" value={draft.font_scale} values={["normal", "large", "dense"]} onChange={(value) => update("font_scale", value)} />
            <Choice label="Motion" value={draft.motion} values={["standard", "reduced"]} onChange={(value) => update("motion", value)} />
            <Choice label="Tabs" value={draft.tab_style} values={["rail", "underline", "minimal"]} onChange={(value) => update("tab_style", value)} />
          </div>
          <div className="three-col">
            <Choice label="Operator" value={draft.operator_layout} values={["command", "console", "compact"]} onChange={(value) => update("operator_layout", value)} />
            <Choice label="Roster" value={draft.roster_layout} values={["cards", "signals", "ledger"]} onChange={(value) => update("roster_layout", value)} />
            <Choice label="Bot Cards" value={draft.stream_card_style} values={["telemetry", "compact", "cinematic"]} onChange={(value) => update("stream_card_style", value)} />
            <Choice label="Dashboard" value={draft.dashboard_density} values={["command", "dense"]} onChange={(value) => update("dashboard_density", value)} />
            <label className="field"><span>Opacity</span><input type="range" min="0.35" max="1" step="0.01" value={draft.surface_opacity ?? 0.92} onChange={(event) => update("surface_opacity", Number(event.target.value))} /></label>
            <label className="field"><span>Blur</span><input type="range" min="0" max="36" step="1" value={draft.surface_blur ?? 18} onChange={(event) => update("surface_blur", Number(event.target.value))} /></label>
          </div>
          <div className="actions-row">
            <button className="primary" type="submit"><Save size={16} />Save</button>
            <button type="button" onClick={reset}><RotateCcw size={16} />Reset</button>
          </div>
        </form>
        <aside className={`panel appearance-preview panel-shape-${draft.card_shape || "soft"} panel-density-${draft.density || "comfortable"} panel-tabs-${draft.tab_style || "rail"}`} style={panelStyle(draft)}>
          <div className="preview-topline"><span /> <strong>SwarmPanel</strong></div>
          <div className="preview-tabs"><span>Live</span><span>Queues</span><span>Medic</span><span>Owner</span></div>
          <div className="command-preview-grid">
            <article className="preview-card command-preview-primary">
              <div><Bot size={18} /><strong>{draft.stream_card_style === "cinematic" ? "Cinematic Fleet" : draft.stream_card_style === "compact" ? "Compact Fleet" : "Telemetry Fleet"}</strong></div>
              <p>12 bots / Lavalink online / Aria watching recovery</p>
              <div className="preview-meter"><span style={{ width: draft.dashboard_density === "dense" ? "62%" : "82%" }} /></div>
            </article>
            <article className="preview-card">
              <div><Play size={18} /><strong>Queue Health</strong></div>
              <p>{draft.operator_layout || "command"} operator / {draft.roster_layout || "cards"} roster</p>
              <div className="chip-row"><span>{draft.theme_mode || "dark"}</span><span>{draft.layout_mode || "standard"}</span><span>{Math.round((draft.surface_opacity ?? 0.92) * 100)}%</span></div>
            </article>
            <article className="preview-card mini">
              <HeartPulse size={18} /><strong>Medic</strong><span>stable</span>
            </article>
            <article className="preview-card mini">
              <Database size={18} /><strong>DB</strong><span>writing</span>
            </article>
            <article className="preview-card mini">
              <Activity size={18} /><strong>Logs</strong><span>live</span>
            </article>
          </div>
        </aside>
      </section>
    </Page>
  );
}
