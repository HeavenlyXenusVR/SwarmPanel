import { safeHex } from "./format.js";

const BACKGROUND_PRESETS = {
  default: "#0d1117",
  midnight: "#090b12",
  aurora: "#101821",
  ember: "#17100d",
};

const SAFE_CHOICES = {
  theme_mode: new Set(["dark", "light", "system"]),
  background_mode: new Set(["default", "midnight", "aurora", "ember", "custom_color", "custom_image"]),
  layout_mode: new Set(["standard", "focused", "wide"]),
  density: new Set(["comfortable", "compact"]),
  card_shape: new Set(["soft", "crisp"]),
  font_scale: new Set(["normal", "large", "dense"]),
  motion: new Set(["standard", "reduced"]),
  operator_layout: new Set(["command", "console", "compact"]),
  roster_layout: new Set(["cards", "signals", "ledger"]),
  tab_style: new Set(["rail", "underline", "minimal"]),
  stream_card_style: new Set(["telemetry", "compact", "cinematic"]),
  dashboard_density: new Set(["command", "dense"]),
};

const CHOICE_ALIASES = {
  operator_layout: { spotlight: "command", studio: "console" },
  roster_layout: { grid: "cards", magazine: "signals", stack: "ledger" },
  tab_style: { pills: "rail" },
  stream_card_style: { editorial: "telemetry" },
  dashboard_density: { comfortable: "command", compact: "dense" },
};

function choice(preferences, key, fallback, legacyKey = "") {
  const raw = preferences?.[key] ?? (legacyKey ? preferences?.[legacyKey] : undefined) ?? fallback;
  const value = String(raw).trim().toLowerCase();
  const aliased = CHOICE_ALIASES[key]?.[value] || value;
  if (SAFE_CHOICES[key]?.has(aliased)) return aliased;
  return SAFE_CHOICES[key]?.has(value) ? value : fallback;
}

function clampNumber(value, fallback, min, max) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(max, Math.max(min, parsed));
}

function safeImage(value) {
  const text = String(value || "").trim();
  if (!/^https?:\/\//i.test(text)) return "none";
  return `url("${text.replace(/["\\]/g, "\\$&")}")`;
}

export function payloadForAction(form) {
  if (form.action === "PLAY") {
    return {
      source_url: form.source_url,
      voice_channel_id: form.voice_channel_id,
      text_channel_id: form.text_channel_id || 0,
    };
  }
  if (form.action === "SMART_RECOMMEND") {
    return {
      voice_channel_id: form.voice_channel_id,
      text_channel_id: form.text_channel_id || 0,
    };
  }
  if (form.action === "SET_HOME") {
    return { voice_channel_id: form.voice_channel_id };
  }
  if (form.action === "LOOP") return { loop_mode: form.loop_mode };
  if (form.action === "FILTER") return { filter_mode: form.filter_mode };
  return {};
}

export function panelStyle(preferences) {
  const mode = choice(preferences, "background_mode", "default");
  const accent = safeHex(preferences?.accent_color, "#89b4fa");
  const background = safeHex(preferences?.background_color, "#0b0e18");
  const imageUrl = String(preferences?.background_image_url || "").trim();
  const useImage = mode === "custom_image" && /^https?:\/\//i.test(imageUrl);
  const baseBackground = mode === "custom_color" ? background : BACKGROUND_PRESETS[mode] || BACKGROUND_PRESETS.default;
  return {
    "--accent": accent,
    "--bg": baseBackground,
    "--panel-bg-image": useImage ? `url("${imageUrl.replace(/["\\]/g, "\\$&")}")` : "none",
    "--surface-opacity": clampNumber(preferences?.surface_opacity, 0.92, 0.35, 1),
    "--surface-blur": `${clampNumber(preferences?.surface_blur, 18, 0, 36)}px`,
  };
}

export function profileSurfaceStyle(preferences, fallbackAccent = "#89b4fa") {
  return {
    "--accent": safeHex(preferences?.accent_color, fallbackAccent),
    "--profile-backdrop": safeImage(preferences?.profile_backdrop_image_url),
    "--profile-backdrop-strength": `${Math.round(clampNumber(preferences?.profile_backdrop_strength, 0.18, 0, 0.55) * 100)}%`,
  };
}

export function panelClassName(preferences) {
  const values = {
    theme: choice(preferences, "theme_mode", "dark"),
    bg: choice(preferences, "background_mode", "default"),
    layout: choice(preferences, "layout_mode", "standard"),
    density: choice(preferences, "density", "comfortable"),
    shape: choice(preferences, "card_shape", "soft"),
    font: choice(preferences, "font_scale", "normal"),
    motion: choice(preferences, "motion", "standard"),
    operator: choice(preferences, "operator_layout", "command", "profile_layout"),
    roster: choice(preferences, "roster_layout", "cards", "directory_layout"),
    tabs: choice(preferences, "tab_style", "rail"),
    stream: choice(preferences, "stream_card_style", "telemetry"),
    dashboard: choice(preferences, "dashboard_density", "command"),
  };
  return [
    "app-shell",
    `panel-theme-${values.theme}`,
    `panel-bg-${values.bg}`,
    `panel-layout-${values.layout}`,
    `panel-density-${values.density}`,
    `panel-shape-${values.shape}`,
    `panel-font-${values.font}`,
    `panel-motion-${values.motion}`,
    `panel-operator-${values.operator}`,
    `panel-roster-${values.roster}`,
    `panel-tabs-${values.tabs}`,
    `panel-stream-${values.stream}`,
    `panel-dashboard-${values.dashboard}`,
  ].join(" ");
}

export function profileLayoutClass(preferences) {
  return `operator-layout-${choice(preferences, "operator_layout", "command", "profile_layout")}`;
}

export function directoryLayoutClass(preferences) {
  return `roster-layout-${choice(preferences, "roster_layout", "cards", "directory_layout")}`;
}
