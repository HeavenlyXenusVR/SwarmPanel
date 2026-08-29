-- Port of the profile-field/panel-preferences cleaning helpers from
-- app/routers/users.py (_clean_profile_updates/_clean_panel_preferences) and
-- app/validators.py's normalize_* helpers.
--
-- SIMPLIFICATION vs the Python original: app/validators.py defines ~20 large
-- enum sets for the Appearance page's look-and-feel knobs (PANEL_THEME_MODES,
-- PANEL_LAYOUT_MODES, PANEL_OPERATOR_LAYOUT_MODES, etc — see
-- PANEL_*/PROFILE_* constants there). Porting every one of those enums 1:1
-- was cut for time; _clean_panel_preferences below still applies real
-- defaults + type coercion (numbers clamped, booleans coerced) but does NOT
-- reject an unrecognized string choice the way the Python enum-based
-- _normalize_choice() does. Net effect: a client sending a bogus
-- theme/layout string gets it stored as-is instead of a 400 — cosmetic
-- surface only (nothing security- or data-integrity-sensitive), flagged in
-- the final report as follow-up work.
local cjson = require("cjson.safe")

local M = {}

-- Distinguishes "explicitly clear this column to SQL NULL" from "field not
-- present in the request" in clean_profile_updates's returned table. Plain
-- Lua nil can't do this: `updates.bio = nil` removes the key entirely, so
-- accounts.update_account_profile's `pairs(updates)` loop never sees it and
-- silently leaves the old value untouched -- a real bug found live (clearing
-- bio/display_name/etc via an empty string in the UI appeared to save but
-- didn't). accounts.lua converts this sentinel back to a real nil (bound as
-- SQL NULL) only when building the positional query args, where a nil in
-- the middle of the array is safe.
M.NULL = setmetatable({}, { __tostring = function() return "<clear>" end })

local PROFILE_SOCIAL_MODES = { open = true, friends = true, quiet = true }
local PROFILE_BANNER_MODES = { gradient = true, image = true, signal = true, quiet = true, contrast = true }
local PROFILE_CARD_STYLES = { solid = true, glass = true, outline = true, terminal = true }
local PROFILE_LAYOUT_MODES = { default = true, sidebar = true, stacked = true, split = true }
local PROFILE_HEADER_STYLES = { solid = true, glass = true, blur = true, transparent = true, gradient = true }
local PROFILE_BORDER_ACCENTS = { none = true, glow = true, pulse = true, neon = true, solid = true }

-- Port of app/validators.py's PANEL_* enum sets -- these were previously NOT
-- enforced here at all (see this file's original header comment), so a
-- client could POST any string for theme_mode/layout_mode/etc and have it
-- stored as-is. Closing that gap: every PANEL_* choice below now goes
-- through M.normalize_choice / M.normalize_panel_look_choice exactly like
-- the Python original.
local PANEL_THEME_MODES = { dark = true, light = true, system = true }
local PANEL_BACKGROUND_MODES = { default = true, midnight = true, aurora = true, ember = true, custom_color = true, custom_image = true }
local PANEL_LAYOUT_MODES = { standard = true, focused = true, wide = true }
local PANEL_DENSITY_MODES = { comfortable = true, compact = true }
local PANEL_SHAPE_MODES = { soft = true, crisp = true }
local PANEL_FONT_MODES = { normal = true, large = true, dense = true }
local PANEL_MOTION_MODES = { standard = true, reduced = true }
local PANEL_OPERATOR_LAYOUT_MODES = { command = true, console = true, compact = true }
local PANEL_ROSTER_LAYOUT_MODES = { cards = true, signals = true, ledger = true }
local PANEL_TAB_STYLE_MODES = { rail = true, underline = true, minimal = true }
local PANEL_STREAM_CARD_MODES = { telemetry = true, compact = true, cinematic = true }
local PANEL_DASHBOARD_DENSITY_MODES = { command = true, dense = true }
-- BUGFIX: these three enums never matched what /appearance's <select>
-- actually offers (pages_identity.lua) or what app.css actually implements
-- (.panel-nav-compact/-hidden, .panel-radius-sharp/-soft,
-- .panel-fontfamily-serif) -- they were left at an older/aspirational set
-- of values. normalize_choice() hard-errors (400) on anything not in the
-- allowed set with no fallback, and since the whole preferences form saves
-- as one request, picking any of the UI's now-invalid options (Sidebar:
-- Compact/Hidden, Corner radius: Sharp/Soft, Panel font: Serif) broke
-- saving EVERY OTHER appearance setting too, until that one field was
-- manually reset back to a value the backend happened to accept.
local PANEL_SIDEBAR_STYLES = { full = true, compact = true, hidden = true }
local PANEL_FONT_FAMILIES = { system = true, serif = true, mono = true, rounded = true }
local PANEL_CARD_HOVER_EFFECTS = { lift = true, glow = true, border = true, none = true }
local PANEL_NOTIFICATION_POSITIONS = { br = true, bl = true, tr = true, tc = true }
local PANEL_BOT_CARD_DETAILS = { full = true, compact = true, minimal = true }
local PANEL_RADIUS_MODES = { sharp = true, medium = true, soft = true }

-- Port of app/validators.py's PANEL_LOOK_ALIASES: a handful of preset/legacy
-- names get remapped onto the current canonical choice before validation,
-- so older stored preferences (or preset payloads using the friendlier
-- names) don't hard-fail.
local PANEL_LOOK_ALIASES = {
  operator_layout = { spotlight = "command", studio = "console" },
  roster_layout = { grid = "cards", magazine = "signals", stack = "ledger" },
  tab_style = { pills = "rail" },
  stream_card_style = { editorial = "telemetry" },
  dashboard_density = { comfortable = "command", compact = "dense" },
}

local function trim(s) return tostring(s or ""):match("^%s*(.-)%s*$") end

local function normalize_optional_text(value, field_name, max_length)
  if value == nil then return nil end
  local text = trim(value)
  if text == "" then return nil end
  if #text > max_length then error(field_name .. " must be " .. max_length .. " characters or fewer", 0) end
  return text
end
M.normalize_optional_text = normalize_optional_text

local function normalize_public_url(value, field_name, max_length)
  local url = normalize_optional_text(value, field_name, max_length or 600)
  if not url then return nil end
  local scheme, netloc = url:match("^(https?)://([^/]+)")
  if not scheme or not netloc then error(field_name .. " must be a public http or https URL", 0) end
  return url
end
M.normalize_public_url = normalize_public_url

local DISCORD_INVITE_HOSTS = { ["discord.gg"] = true, ["discord.com"] = true, ["www.discord.com"] = true }

local function normalize_server_invite_url(value)
  local url = normalize_optional_text(value, "Server invite URL", 600)
  if not url then return nil end
  if url:match("^discord%.gg/") then url = "https://" .. url end
  local scheme, host, path = url:match("^(https?)://([^/]+)(.*)$")
  local parts = {}
  if path then for p in path:gmatch("[^/]+") do parts[#parts + 1] = p end end
  local valid = scheme == "https" and host and DISCORD_INVITE_HOSTS[host:lower()]
    and (host:lower():match("discord%.gg$") or (#parts >= 2 and parts[1] == "invite"))
  if not valid then error("Server invite URL must be a Discord invite link", 0) end
  return url
end
M.normalize_server_invite_url = normalize_server_invite_url

local function normalize_profile_accent(value)
  local accent = normalize_optional_text(value, "Theme accent", 20)
  if not accent then return nil end
  if not accent:match("^#%x%x%x%x%x%x$") and not accent:match("^#%x%x%x$") then
    error("Theme accent must be a hex color like #89b4fa", 0)
  end
  return accent:lower()
end
M.normalize_profile_accent = normalize_profile_accent

local function normalize_choice(value, field_name, allowed, default)
  local choice = trim(value ~= nil and value or default):lower()
  if choice == "" then choice = default end
  if not allowed[choice] then
    local names = {}
    for k in pairs(allowed) do names[#names + 1] = k end
    table.sort(names)
    error(field_name .. " must be one of: " .. table.concat(names, ", "), 0)
  end
  return choice
end
M.normalize_choice = normalize_choice

-- Port of app/validators.py's _normalize_panel_look_choice(): same as
-- normalize_choice, but first remaps through PANEL_LOOK_ALIASES[key] so a
-- legacy/preset-friendly name resolves to the canonical choice before the
-- allowed-set check.
local function normalize_panel_look_choice(value, field_name, key, allowed, default)
  local choice = trim(value ~= nil and value or default):lower()
  if choice == "" then choice = default end
  local aliases = PANEL_LOOK_ALIASES[key]
  if aliases and aliases[choice] then choice = aliases[choice] end
  if not allowed[choice] then
    local names = {}
    for k in pairs(allowed) do names[#names + 1] = k end
    table.sort(names)
    error(field_name .. " must be one of: " .. table.concat(names, ", "), 0)
  end
  return choice
end
M.normalize_panel_look_choice = normalize_panel_look_choice

-- payload: decoded JSON body table (from req.json). Returns a table of
-- column -> normalized value, matching ACCOUNT_PROFILE_FIELDS column names,
-- ready for accounts.update_account_profile(). Only keys actually present in
-- payload are included (exclude_unset semantics).
function M.clean_profile_updates(payload, bot_index)
  local updates = {}
  if payload.display_name ~= nil then updates.display_name = normalize_optional_text(payload.display_name, "Display name", 80) or M.NULL end
  if payload.avatar_url ~= nil then updates.avatar_url = normalize_public_url(payload.avatar_url, "Avatar URL") or M.NULL end
  if payload.bio ~= nil then updates.bio = normalize_optional_text(payload.bio, "Bio", 280) or M.NULL end
  if payload.profile_headline ~= nil then updates.profile_headline = normalize_optional_text(payload.profile_headline, "Profile headline", 140) or M.NULL end
  if payload.profile_tags ~= nil then
    local clean_tags, seen = {}, {}
    for _, raw_tag in ipairs(payload.profile_tags or {}) do
      local tag = tostring(raw_tag or ""):gsub("[^A-Za-z0-9_.%-]+", ""):sub(1, 32)
      local lower = tag:lower()
      if tag ~= "" and not seen[lower] then
        seen[lower] = true
        clean_tags[#clean_tags + 1] = tag
        if #clean_tags >= 12 then break end
      end
    end
    updates.profile_tags = cjson.encode(clean_tags)
  end
  if payload.profile_links ~= nil then
    local clean_links = {}
    for _, raw_link in ipairs(payload.profile_links or {}) do
      raw_link = raw_link or {}
      local label = normalize_optional_text(raw_link.label, "Link label", 32)
      local url = normalize_public_url(raw_link.url, "Profile link", 600)
      if label and url then
        clean_links[#clean_links + 1] = { label = label, url = url }
        if #clean_links >= 5 then break end
      end
    end
    updates.profile_links = cjson.encode(clean_links)
  end
  if payload.profile_banner_url ~= nil then updates.profile_banner_url = normalize_public_url(payload.profile_banner_url, "Profile banner URL") or M.NULL end
  if payload.profile_banner_mode ~= nil then updates.profile_banner_mode = normalize_choice(payload.profile_banner_mode, "Profile banner", PROFILE_BANNER_MODES, "gradient") end
  if payload.profile_card_style ~= nil then updates.profile_card_style = normalize_choice(payload.profile_card_style, "Profile card style", PROFILE_CARD_STYLES, "solid") end
  if payload.profile_social_mode ~= nil then updates.profile_social_mode = normalize_choice(payload.profile_social_mode, "Profile social mode", PROFILE_SOCIAL_MODES, "open") end
  if payload.favorite_bot ~= nil then
    local favorite = normalize_optional_text(payload.favorite_bot, "Favorite bot", 50)
    if favorite and bot_index and not bot_index[favorite] then error("Favorite bot must be one of the known swarm bots", 0) end
    updates.favorite_bot = favorite or M.NULL
  end
  if payload.theme_accent ~= nil then updates.theme_accent = normalize_profile_accent(payload.theme_accent) or M.NULL end
  if payload.public_profile ~= nil then updates.public_profile = payload.public_profile and true or false end
  if payload.server_invite_url ~= nil then updates.server_invite_url = normalize_server_invite_url(payload.server_invite_url) or M.NULL end
  if payload.server_name ~= nil then updates.server_name = normalize_optional_text(payload.server_name, "Server name", 120) or M.NULL end
  if payload.server_icon_url ~= nil then updates.server_icon_url = normalize_public_url(payload.server_icon_url, "Server icon URL") or M.NULL end
  if payload.profile_quote ~= nil then updates.profile_quote = normalize_optional_text(payload.profile_quote, "Profile quote", 160) or M.NULL end
  if payload.profile_layout_mode ~= nil then updates.profile_layout_mode = normalize_choice(payload.profile_layout_mode, "Profile layout", PROFILE_LAYOUT_MODES, "default") end
  if payload.profile_header_style ~= nil then updates.profile_header_style = normalize_choice(payload.profile_header_style, "Profile header style", PROFILE_HEADER_STYLES, "solid") end
  if payload.profile_border_accent ~= nil then updates.profile_border_accent = normalize_choice(payload.profile_border_accent, "Profile border accent", PROFILE_BORDER_ACCENTS, "none") end
  return updates
end

local PANEL_PREFERENCE_DEFAULTS = {
  theme_mode = "dark", accent_color = "#89b4fa", background_mode = "default", background_color = "#0b0e18",
  background_image_url = cjson.null, profile_backdrop_image_url = cjson.null, profile_backdrop_strength = 0.18,
  layout_mode = "standard", density = "comfortable", card_shape = "soft", font_scale = "normal", motion = "standard",
  operator_layout = "command", roster_layout = "cards", tab_style = "rail", surface_opacity = 0.92, surface_blur = 18,
  stream_card_style = "telemetry", dashboard_density = "command",
}

-- Merges `raw` (a decoded JSON request body, exclude-unset semantics assumed
-- already applied by the caller passing only keys it wants to change) onto
-- `base` (previously-stored preferences or the defaults above), validating
-- every PANEL_* enum choice against the sets above (previously accepted as-
-- is -- see this file's original header comment) plus clamping/coercion for
-- the numeric and boolean fields, mirroring app/routers/users.py's
-- _clean_panel_preferences field-by-field.
function M.clean_panel_preferences(raw, base)
  raw = raw or {}
  local prefs = {}
  for k, v in pairs(base or PANEL_PREFERENCE_DEFAULTS) do prefs[k] = v end

  if raw.theme_mode ~= nil then prefs.theme_mode = normalize_choice(raw.theme_mode, "Theme mode", PANEL_THEME_MODES, "dark") end
  if raw.accent_color ~= nil then prefs.accent_color = normalize_profile_accent(raw.accent_color) or "#89b4fa" end
  if raw.background_mode ~= nil then prefs.background_mode = normalize_choice(raw.background_mode, "Background mode", PANEL_BACKGROUND_MODES, "default") end
  if raw.background_color ~= nil then prefs.background_color = normalize_profile_accent(raw.background_color) or "#0b0e18" end
  if raw.background_image_url ~= nil then prefs.background_image_url = M.normalize_public_url(raw.background_image_url, "Background image URL") end
  if raw.profile_backdrop_image_url ~= nil then prefs.profile_backdrop_image_url = M.normalize_public_url(raw.profile_backdrop_image_url, "Profile backdrop image URL") end
  if raw.profile_backdrop_strength ~= nil then
    local n = tonumber(raw.profile_backdrop_strength)
    if not n then error("Profile backdrop strength must be a number between 0.0 and 0.55", 0) end
    prefs.profile_backdrop_strength = math.max(0.0, math.min(n, 0.55))
  end
  if raw.layout_mode ~= nil then prefs.layout_mode = normalize_choice(raw.layout_mode, "Layout mode", PANEL_LAYOUT_MODES, "standard") end
  if raw.density ~= nil then prefs.density = normalize_choice(raw.density, "Density", PANEL_DENSITY_MODES, "comfortable") end
  if raw.card_shape ~= nil then prefs.card_shape = normalize_choice(raw.card_shape, "Card shape", PANEL_SHAPE_MODES, "soft") end
  if raw.font_scale ~= nil then prefs.font_scale = normalize_choice(raw.font_scale, "Font scale", PANEL_FONT_MODES, "normal") end
  if raw.motion ~= nil then prefs.motion = normalize_choice(raw.motion, "Motion", PANEL_MOTION_MODES, "standard") end
  if raw.operator_layout ~= nil or raw.profile_layout ~= nil then
    prefs.operator_layout = normalize_panel_look_choice(
      raw.operator_layout ~= nil and raw.operator_layout or raw.profile_layout,
      "Operator layout", "operator_layout", PANEL_OPERATOR_LAYOUT_MODES, "command"
    )
  end
  if raw.roster_layout ~= nil or raw.directory_layout ~= nil then
    prefs.roster_layout = normalize_panel_look_choice(
      raw.roster_layout ~= nil and raw.roster_layout or raw.directory_layout,
      "Roster layout", "roster_layout", PANEL_ROSTER_LAYOUT_MODES, "cards"
    )
  end
  if raw.tab_style ~= nil then prefs.tab_style = normalize_panel_look_choice(raw.tab_style, "Tab style", "tab_style", PANEL_TAB_STYLE_MODES, "rail") end
  if raw.surface_opacity ~= nil then
    local n = tonumber(raw.surface_opacity)
    if not n then error("Surface opacity must be a number between 0.35 and 1.0", 0) end
    prefs.surface_opacity = math.max(0.35, math.min(n, 1.0))
  end
  if raw.surface_blur ~= nil then
    local n = tonumber(raw.surface_blur)
    if not n then error("Surface blur must be an integer between 0 and 36", 0) end
    prefs.surface_blur = math.max(0, math.min(math.floor(n), 36))
  end
  if raw.stream_card_style ~= nil then
    prefs.stream_card_style = normalize_panel_look_choice(raw.stream_card_style, "Bot card style", "stream_card_style", PANEL_STREAM_CARD_MODES, "telemetry")
  end
  if raw.dashboard_density ~= nil then
    prefs.dashboard_density = normalize_panel_look_choice(raw.dashboard_density, "Dashboard density", "dashboard_density", PANEL_DASHBOARD_DENSITY_MODES, "command")
  end
  if raw.sidebar_style ~= nil then prefs.sidebar_style = normalize_choice(raw.sidebar_style, "Sidebar style", PANEL_SIDEBAR_STYLES, "full") end
  if raw.panel_font_family ~= nil then prefs.panel_font_family = normalize_choice(raw.panel_font_family, "Panel font", PANEL_FONT_FAMILIES, "system") end
  if raw.card_hover_effect ~= nil then prefs.card_hover_effect = normalize_choice(raw.card_hover_effect, "Card hover", PANEL_CARD_HOVER_EFFECTS, "lift") end
  if raw.notification_position ~= nil then prefs.notification_position = normalize_choice(raw.notification_position, "Notification position", PANEL_NOTIFICATION_POSITIONS, "br") end
  if raw.bot_card_detail ~= nil then prefs.bot_card_detail = normalize_choice(raw.bot_card_detail, "Bot card detail", PANEL_BOT_CARD_DETAILS, "full") end
  if raw.panel_radius ~= nil then prefs.panel_radius = normalize_choice(raw.panel_radius, "Panel radius", PANEL_RADIUS_MODES, "medium") end
  if raw.accent_secondary ~= nil then prefs.accent_secondary = normalize_profile_accent(raw.accent_secondary) end
  for _, key in ipairs({ "show_bot_uptime", "show_queue_pressure", "compact_sidebar" }) do
    if raw[key] ~= nil then prefs[key] = raw[key] and true or false end
  end
  return prefs
end

function M.default_panel_preferences()
  local prefs = {}
  for k, v in pairs(PANEL_PREFERENCE_DEFAULTS) do prefs[k] = v end
  return prefs
end

return M
