-- Settings loader: mirrors app/config.py + app/bots.py.
--
-- Precedence (matches the Python app's load_dotenv(..., override=False) calls):
--   1. real process environment (os.getenv)
--   2. SwarmPanel/.env
--   3. Music/.env  (shared bot-swarm env; only fills in what's still missing)
--
-- DB-schema finding, corrected 2026-08-01: the Phase 1 audit's conclusion
-- above (STRIFE/LOCKHART share the `discord_music` database) is now WRONG
-- and was actively causing "bots don't listen to the panel" for these two.
-- Both bots' own Postgres connections (Music/.env's STRIFE_DB_HOST/
-- STRIFE_DB_NAME etc.) target their own dedicated `discord_music_strife` /
-- `discord_music_lockhart` databases -- confirmed live via `docker exec
-- music_bot_strife env` and the bot's own startup log ("Postgres schema
-- verified/created (discord_music_strife)"). The shared `discord_music`
-- database now only holds a stale row from 2026-07-25, predating whatever
-- migration moved these two bots onto their own databases; the Phase-1
-- audit just ran before that migration and is now out of date.
-- SwarmPanel/.env's STRIFE_DB_NAME/LOCKHART_DB_NAME are fixed to
-- discord_music_strife/discord_music_lockhart accordingly. If this ever
-- flips back, verify with a fresh row-count/updated_at check before trusting
-- either audit blindly -- don't just take the comment's word for it.

local function read_dotenv_file(path, out)
  local f = io.open(path, "r")
  if not f then return end
  for line in f:lines() do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" and not trimmed:match("^#") then
      local key, val = trimmed:match("^([%w_]+)%s*=%s*(.*)$")
      if key then
        -- strip matching surrounding quotes
        val = val:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
        if out[key] == nil then out[key] = val end
      end
    end
  end
  f:close()
end

local M = {}

function M.env(name, default)
  local v = os.getenv(name)
  if v ~= nil and v ~= "" then return v end
  if M._dotenv[name] ~= nil and M._dotenv[name] ~= "" then return M._dotenv[name] end
  return default or ""
end

function M.env_bool(name, default)
  local raw = M.env(name, nil)
  if raw == nil or raw == "" then return default end
  raw = raw:lower()
  return raw == "1" or raw == "true" or raw == "yes" or raw == "on"
end

function M.env_csv(name)
  local raw = M.env(name, "")
  local out = {}
  for item in raw:gmatch("[^,]+") do
    item = item:match("^%s*(.-)%s*$"):gsub("/+$", "")
    if item ~= "" then out[#out + 1] = item end
  end
  return out
end

function M.env_int_set(name)
  local raw = M.env(name, "")
  local out = {}
  for item in raw:gmatch("[^,]+") do
    item = item:match("^%s*(.-)%s*$")
    local n = tonumber(item)
    if n then out[tostring(math.floor(n))] = true end
  end
  return out
end

-- Per-bot DB name override, mirrors bots.py's _music_schema(): {KEY}_DB_NAME env var,
-- falling back to discord_music_<key>.
local function music_schema(bot_key, fallback)
  local v = M.env(bot_key:upper() .. "_DB_NAME", "")
  if v ~= "" then return v end
  return fallback
end

local MUSIC_BOT_KEYS = {
  "gws", "harmonic", "maestro", "melodic", "nexus", "rhythm", "symphony",
  "tunestream", "alucard", "sapphire", "strife", "lockhart", "glitch",
}

local BOT_DISPLAY_NAMES = {
  gws = "GWS", harmonic = "Harmonic", maestro = "Maestro", melodic = "Melodic",
  nexus = "Nexus", rhythm = "Rhythm", symphony = "Symphony", tunestream = "Tunestream",
  alucard = "Alucard", sapphire = "Sapphire", strife = "Strife", lockhart = "Lockhart",
  glitch = "Glitch", aria = "Aria",
}

local BOT_ACCENTS = {
  gws = "#cba6f7", harmonic = "#89b4fa", maestro = "#a6e3a1", melodic = "#fab387",
  nexus = "#f38ba8", rhythm = "#94e2d5", symphony = "#f9e2af", tunestream = "#b4befe",
  alucard = "#e06c75", sapphire = "#4fc3f7", strife = "#ff6b6b", lockhart = "#f9a8d4",
  glitch = "#00ff9f", aria = "#cba6f7",
}

function M.load()
  M._dotenv = {}
  -- lua/ is a sibling of app/ under SwarmPanel/, so parents are the same as the
  -- Python app's Path(__file__).resolve().parents[1] / parents[2].
  local script_dir = (arg and arg[0] or "main.lua"):match("(.*/)") or "./"
  local panel_root = script_dir .. ".."
  read_dotenv_file(panel_root .. "/.env", M._dotenv)
  read_dotenv_file(panel_root .. "/../Music/.env", M._dotenv)

  M.music_bots = {}
  for _, key in ipairs(MUSIC_BOT_KEYS) do
    M.music_bots[#M.music_bots + 1] = {
      key = key,
      display_name = BOT_DISPLAY_NAMES[key],
      kind = "music",
      token_env = key:upper() .. "_DISCORD_TOKEN",
      db_schema = music_schema(key, "discord_music_" .. key),
      table_prefix = key,
    }
  end
  M.aria_bot = {
    key = "aria", display_name = "Aria", kind = "orchestrator",
    token_env = "ARIA_DISCORD_TOKEN",
  }
  M.all_bots = {}
  for _, b in ipairs(M.music_bots) do M.all_bots[#M.all_bots + 1] = b end
  M.all_bots[#M.all_bots + 1] = M.aria_bot
  M.bot_index = {}
  for _, b in ipairs(M.all_bots) do M.bot_index[b.key] = b end
  M.bot_accents = BOT_ACCENTS

  M.bot_tokens = {}
  for _, b in ipairs(M.all_bots) do
    M.bot_tokens[b.key] = M.env(b.token_env, "")
  end

  M.settings = {
    db_host = M.env("PANEL_DB_HOST", M.env("DB_HOST", "127.0.0.1")),
    -- NOTE: the Python app defaults to MariaDB's port 3306. This Lua backend
    -- talks to Postgres, so the sane default here is 5432. PANEL_DB_PORT in
    -- the current .env is still "3306" (MariaDB) — the orchestrator needs to
    -- add/override PANEL_DB_PG_PORT=5432 (or repoint PANEL_DB_PORT once the
    -- Python backend is retired) — see deployment notes in the final report.
    db_port = tonumber(M.env("PANEL_DB_PG_PORT", "5432")),
    db_user = M.env("PANEL_DB_USER", M.env("DB_USER", "botuser")),
    db_password = M.env("PANEL_DB_PASSWORD", M.env("DB_PASSWORD", "bot_logins")),
    db_default_schema = M.env("PANEL_DB_DEFAULT_SCHEMA", "discord_music_gws"),
    admin_username = M.env("PANEL_ADMIN_USERNAME", "admin"),
    admin_password = M.env("PANEL_ADMIN_PASSWORD", ""),
    session_secret = M.env("PANEL_SESSION_SECRET", ""),
    cors_allowed_origins = M.env_csv("PANEL_CORS_ALLOWED_ORIGINS"),
    cors_allow_origin_regex = M.env("PANEL_CORS_ALLOW_ORIGIN_REGEX", ""),
    api_token_ttl_seconds = tonumber(M.env("PANEL_API_TOKEN_TTL_SECONDS", "43200")),
    pages_public_url = M.env("PANEL_PAGES_PUBLIC_URL", ""),
    site_owner_email = M.env("SWARM_PANEL_SITE_OWNER_EMAIL", M.env("IMAGE_GALLERY_OWNER_EMAIL", "")):lower(),
    owner_email_requires_verification = M.env_bool("SWARM_PANEL_OWNER_EMAIL_REQUIRES_VERIFICATION", true),
    api_max_rows = tonumber(M.env("PANEL_API_MAX_ROWS", "200")),
    bot_control_source_max_chars = tonumber(M.env("PANEL_BOT_CONTROL_SOURCE_MAX_CHARS", "500")),
    -- NOT set in .env, so this fixed default is what's actually active on
    -- both backends today. Found (and fixed here) while porting the
    -- database-truncate confirmation gate: the default is a real, active
    -- security control (owner-confirmation phrase for TRUNCATE), not a
    -- placeholder — omitting it here would have silently disabled that gate
    -- in this rewrite while the Python original still enforced it.
    destructive_confirmation_phrase = M.env("PANEL_DESTRUCTIVE_CONFIRMATION_PHRASE", "I understand this permanently deletes SwarmPanel data"),
    scheduled_exports_enabled = M.env_bool("PANEL_SCHEDULED_EXPORTS_ENABLED", false),
    scheduled_exports_dir = M.env("PANEL_SCHEDULED_EXPORTS_DIR", panel_root .. "/.runtime/exports"),
    port = tonumber(M.env("PORT", "8003")),
    -- Exposed so notify.lua can locate ../Image Gallery/live-config.json the
    -- same way app/verification.py's _image_gallery_verification_url()
    -- does (BASE_DIR.parents[1] / "Image Gallery" / "live-config.json").
    panel_root = panel_root,

    -- Mirrors app/config.py's smtp_*/email_verification_ttl_seconds fields
    -- exactly, including the PANEL_SMTP_* -> SMTP_* fallback order and the
    -- smtp_from_email -> smtp_username fallback. Used by notify.lua for the
    -- Image Gallery email-verification-resend flow (the one live SMTP call
    -- site in the whole app; SwarmPanel account verification itself is 100%
    -- Discord-webhook-based — see notify.lua's header comment).
    smtp_host = M.env("PANEL_SMTP_HOST", M.env("SMTP_HOST", "")),
    smtp_port = tonumber(M.env("PANEL_SMTP_PORT", M.env("SMTP_PORT", "587"))),
    smtp_username = M.env("PANEL_SMTP_USERNAME", M.env("SMTP_USERNAME", "")),
    smtp_password = M.env("PANEL_SMTP_PASSWORD", M.env("SMTP_PASSWORD", "")),
    smtp_from_email = (function()
      local v = M.env("PANEL_SMTP_FROM_EMAIL", M.env("SMTP_FROM_EMAIL", ""))
      if v ~= "" then return v end
      return M.env("PANEL_SMTP_USERNAME", M.env("SMTP_USERNAME", ""))
    end)(),
    smtp_use_tls = M.env_bool("PANEL_SMTP_USE_TLS", M.env_bool("SMTP_USE_TLS", true)),
    email_verification_ttl_seconds = math.max(300, tonumber(M.env("PANEL_EMAIL_VERIFICATION_TTL_SECONDS", "86400")) or 86400),
  }

  if M.settings.session_secret == "" then
    error("PANEL_SESSION_SECRET is required")
  end
  return M.settings
end

return M
