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
  profile_layout: new Set(["spotlight", "studio", "compact"]),
  directory_layout: new Set(["grid", "magazine", "stack"]),
  tab_style: new Set(["pills", "underline", "minimal"]),
  stream_card_style: new Set(["editorial", "compact", "cinematic"]),
  dashboard_density: new Set(["comfortable", "compact"]),
};

function choice(preferences, key, fallback) {
  const value = String(preferences?.[key] || fallback).trim().toLowerCase();
  return SAFE_CHOICES[key]?.has(value) ? value : fallback;
}

function clampNumber(value, fallback, min, max) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(max, Math.max(min, parsed));
}

export function payloadForAction(form) {
  if (form.action === "PLAY") {
    return {
      source_url: form.source_url,
      voice_channel_id: form.voice_channel_id,
      text_channel_id: form.text_channel_id || 0,
      loop_mode: "queue",
      shuffle_before_play: true,
      save_playlist: true,
    };
  }
  if (form.action === "SMART_RECOMMEND") {
    return {
      voice_channel_id: form.voice_channel_id,
      text_channel_id: form.text_channel_id || 0,
      loop_mode: "queue",
      shuffle_before_play: true,
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

export function panelClassName(preferences) {
  const values = {
    theme: choice(preferences, "theme_mode", "dark"),
    bg: choice(preferences, "background_mode", "default"),
    layout: choice(preferences, "layout_mode", "standard"),
    density: choice(preferences, "density", "comfortable"),
    shape: choice(preferences, "card_shape", "soft"),
    font: choice(preferences, "font_scale", "normal"),
    motion: choice(preferences, "motion", "standard"),
    tabs: choice(preferences, "tab_style", "pills"),
    stream: choice(preferences, "stream_card_style", "editorial"),
    dashboard: choice(preferences, "dashboard_density", "comfortable"),
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
    `panel-tabs-${values.tabs}`,
    `panel-stream-${values.stream}`,
    `panel-dashboard-${values.dashboard}`,
  ].join(" ");
}

export function profileLayoutClass(preferences) {
  return `profile-layout-${choice(preferences, "profile_layout", "spotlight")}`;
}

export function directoryLayoutClass(preferences) {
  return `user-grid-${choice(preferences, "directory_layout", "grid")}`;
}
