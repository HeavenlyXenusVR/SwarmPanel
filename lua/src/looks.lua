-- Server-owned appearance presets. New presets can be added/edited here
-- without a frontend redeploy (see /api/appearance/presets in routes.lua).
-- Extends AppearancePage.jsx's 3 hardcoded LOOK_PRESETS (Command Deck/
-- Signal Glass/Owner Lounge, left in place as always-available fallbacks)
-- rather than replacing them. Every field name/value below matches
-- profiles.lua's PANEL_*/PROFILE_* enums exactly -- these presets are just
-- pre-validated bundles of the same choices a user could set by hand.
local M = {}

M.PANEL_LOOKS = {
  {
    id = "daybreak_console", title = "Daybreak Console",
    note = "Light theme built for bright rooms, without losing the deck's density.",
    patch = {
      theme_mode = "light", accent_color = "#3b82f6", background_mode = "default",
      layout_mode = "standard", density = "comfortable", motion = "reduced",
    },
  },
  {
    id = "blackout_ops", title = "Blackout Ops",
    note = "High-density, low-noise incident-response look.",
    patch = {
      theme_mode = "dark", accent_color = "#94a3b8", accent_secondary = "#e2e8f0",
      stream_card_style = "compact", dashboard_density = "dense", tab_style = "minimal",
    },
  },
  {
    id = "neon_arcade", title = "Neon Arcade",
    note = "Loud, glowy, and built for showing the panel off.",
    patch = {
      theme_mode = "dark", accent_color = "#f472b6", accent_secondary = "#a855f7",
      background_mode = "aurora", stream_card_style = "cinematic", card_hover_effect = "glow",
      surface_blur = 28,
    },
  },
  {
    id = "terminal_green", title = "Terminal Green",
    note = "Retro CRT/server-room read: one accent, telemetry cards, ledger roster.",
    patch = {
      theme_mode = "dark", accent_color = "#22c55e", accent_secondary = "",
      stream_card_style = "telemetry", roster_layout = "ledger", panel_font_family = "mono",
    },
  },
}

M.PROFILE_LOOKS = {
  {
    id = "signal_card", title = "Signal Card",
    note = "Minimal, data-forward -- your bot stats do the talking.",
    patch = { profile_banner_mode = "signal", profile_card_style = "glass", profile_border_accent = "pulse" },
  },
  {
    id = "terminal_operator", title = "Terminal Operator",
    note = "Matches the Terminal Green panel look for admins/power users.",
    patch = { profile_card_style = "terminal", profile_header_style = "solid", profile_border_accent = "none" },
  },
  {
    id = "quiet_lurker", title = "Quiet Lurker",
    note = "A profile that exists, but doesn't broadcast.",
    patch = { profile_social_mode = "quiet", profile_banner_mode = "quiet", profile_border_accent = "none" },
  },
  {
    id = "glass_showcase", title = "Glass Showcase",
    note = "Translucency and depth for a 'look at my setup' profile.",
    patch = { profile_card_style = "glass", profile_header_style = "blur", profile_layout_mode = "split" },
  },
  {
    id = "neon_border", title = "Neon Border",
    note = "High-contrast flex look.",
    patch = { profile_border_accent = "neon", profile_header_style = "transparent" },
  },
  {
    id = "contrast_mode", title = "Contrast Mode",
    note = "Accessibility-first: safe contrast banner and outline card.",
    patch = { profile_banner_mode = "contrast", profile_card_style = "outline" },
  },
}

return M
