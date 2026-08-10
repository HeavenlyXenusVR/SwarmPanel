-- accountlogins.users access: login, profile fetch, guild lookup, presence,
-- profile updates, and admin CRUD.
-- Mirrors app/db/accounts.py's authenticate_account_login / get_account_profile /
-- get_account_guild_id_for_username / touch_account_seen / update_account_profile /
-- update_account_panel_preferences / search_account_profiles / get_account_admin* /
-- update_account_admin / set_account_panel_role / delete_account_admin /
-- set_account_webhook_verified_admin / reset_account_password_admin /
-- register_account_login / get_music_activity_summary_for_guilds.
local db = require("db")
local auth = require("auth")
local cjson = require("cjson.safe")

local M = {}
local SCHEMA = "accountlogins"
local TABLE = "users"

-- Discord DM verification columns, added self-healing (same
-- ADD COLUMN IF NOT EXISTS-on-first-use pattern control.lua's
-- ensure_overrides_table already established) rather than a one-shot
-- migration script, since this module has no startup migration hook of its
-- own to run one from. Cheap metadata-only ALTERs, safe to repeat on every
-- call; pcall'd so a permissions hiccup degrades to "column doesn't exist
-- yet" (caller sees the DB error) rather than taking down the request.
local discord_columns_ensured = false
local function ensure_discord_dm_columns()
  if discord_columns_ensured then return end
  pcall(db.execute, SCHEMA, "ALTER TABLE " .. TABLE .. " ADD COLUMN IF NOT EXISTS discord_user_id VARCHAR(32)")
  pcall(db.execute, SCHEMA, "ALTER TABLE " .. TABLE .. " ADD COLUMN IF NOT EXISTS discord_username VARCHAR(120)")
  pcall(db.execute, SCHEMA, "ALTER TABLE " .. TABLE .. " ADD COLUMN IF NOT EXISTS discord_dm_verified_at TIMESTAMP")
  pcall(db.execute, SCHEMA, "ALTER TABLE " .. TABLE .. " ADD COLUMN IF NOT EXISTS discord_dm_verification_code_hash CHAR(64)")
  pcall(db.execute, SCHEMA, "ALTER TABLE " .. TABLE .. " ADD COLUMN IF NOT EXISTS discord_dm_verification_sent_at TIMESTAMP")
  discord_columns_ensured = true
end

local USERNAME_PATTERN = "^[%w_.-]+$"
local EMAIL_PATTERN = "^[^@%s]+@[^@%s]+%.[^@%s]+$"

local function normalize_username(value)
  local username = tostring(value or ""):match("^%s*(.-)%s*$")
  if #username < 2 or #username > 80 or not username:match(USERNAME_PATTERN) then
    return nil, "Username must be 2-80 characters using letters, numbers, dots, dashes, or underscores."
  end
  return username
end
M.normalize_username = normalize_username

-- Returns normalized_email_or_nil, err. A nil/blank input normalizes to nil
-- (no error) — mirrors helpers.py's _normalize_email().
local function normalize_email(value)
  local email = tostring(value or ""):match("^%s*(.-)%s*$"):lower()
  if email == "" then return nil end
  if #email > 255 or not email:match(EMAIL_PATTERN) then
    return nil, "Enter a valid email address."
  end
  return email
end
M.normalize_email = normalize_email

local function normalize_password(value, field_name)
  local password = tostring(value or "")
  if #password < 8 then
    return nil, (field_name or "Password") .. " must be at least 8 characters."
  end
  return password
end
M.normalize_password = normalize_password

-- Returns account table (username, guild_id, email, email_verified, has_password,
-- used_legacy_login, panel_role) or nil on failure.
function M.authenticate_account_login(username, password)
  local uname, err = normalize_username(username)
  if not uname then return nil, err end
  local secret = tostring(password or "")
  if secret == "" then return nil end

  local row = db.fetchone(
    SCHEMA,
    "SELECT username, guild_id, email, email_verified_at, password_hash, panel_role "
      .. "FROM " .. TABLE .. " WHERE username = %s LIMIT 1",
    uname
  )
  if not row then return nil end

  local password_hash = row.password_hash
  local password_ok = password_hash and auth.verify_password_hash(secret, password_hash) or false
  local legacy_ok = false
  if not password_ok and not password_hash then
    legacy_ok = auth.constant_time_eq(tostring(row.guild_id or ""), secret:match("^%s*(.-)%s*$"))
  end
  if not password_ok and not legacy_ok then return nil end

  db.execute(
    SCHEMA,
    "UPDATE " .. TABLE .. " SET last_login_at = CURRENT_TIMESTAMP, last_seen_at = CURRENT_TIMESTAMP "
      .. "WHERE username = %s AND guild_id = %s",
    uname, row.guild_id
  )

  return {
    username = row.username,
    guild_id = tostring(row.guild_id),
    email = row.email,
    email_verified = row.email_verified_at ~= nil,
    has_password = password_hash ~= nil,
    used_legacy_login = legacy_ok,
    panel_role = row.panel_role or "member",
  }
end

function M.get_account_guild_id_for_username(username)
  local uname = normalize_username(username)
  if not uname then return nil end
  local row = db.fetchone(SCHEMA, "SELECT guild_id FROM " .. TABLE .. " WHERE username = %s LIMIT 1", uname)
  if not row or row.guild_id == nil then return nil end
  return tostring(row.guild_id)
end

function M.touch_account_seen(username, guild_id, min_interval_seconds)
  local uname = normalize_username(username)
  if not uname then return end
  min_interval_seconds = min_interval_seconds or 30
  if min_interval_seconds > 0 then
    db.execute(
      SCHEMA,
      "UPDATE " .. TABLE .. " SET last_seen_at = CURRENT_TIMESTAMP WHERE username = %s AND guild_id = %s "
        .. "AND (last_seen_at IS NULL OR last_seen_at < NOW() - (%s || ' seconds')::interval)",
      uname, guild_id, tostring(min_interval_seconds)
    )
  else
    db.execute(
      SCHEMA,
      "UPDATE " .. TABLE .. " SET last_seen_at = CURRENT_TIMESTAMP WHERE username = %s AND guild_id = %s",
      uname, guild_id
    )
  end
end

local PROFILE_COLUMNS = table.concat({
  "id", "username", "guild_id", "email", "email_verified_at",
  "verification_webhook_url", "verification_webhook_channel_id", "verification_webhook_name",
  "webhook_verified_at", "webhook_verification_sent_at",
  "discord_user_id", "discord_username", "discord_dm_verified_at", "discord_dm_verification_sent_at",
  "password_hash", "display_name", "avatar_url", "bio",
  "profile_headline", "profile_tags", "profile_links", "profile_banner_url", "profile_banner_mode", "profile_card_style", "profile_social_mode",
  "favorite_bot", "theme_accent",
  "public_profile", "server_invite_url", "server_name", "server_icon_url",
  "panel_preferences", "profile_quote", "profile_layout_mode", "profile_header_style", "profile_border_accent",
  "panel_role", "created_at", "last_login_at", "last_seen_at", "updated_at",
}, ", ")

local function is_recently_seen(value, window_seconds)
  window_seconds = window_seconds or 180
  if not value then return false end
  -- pgmoon returns timestamp columns as "YYYY-MM-DD HH:MM:SS" text; compare
  -- via a follow-up DB round trip would be overkill, so parse loosely here.
  local y, mo, d, h, mi, s = tostring(value):match("(%d+)-(%d+)-(%d+)[ T](%d+):(%d+):(%d+)")
  if not y then return false end
  local seen_epoch = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s })
  -- os.time() above treats the broken-down time as LOCAL time; Postgres
  -- returned it as UTC. Adjust by the local UTC offset so "recently seen"
  -- comparisons stay correct regardless of container TZ.
  local utc_now = os.time(os.date("!*t"))
  local local_now = os.time(os.date("*t"))
  local tz_offset = local_now - utc_now
  seen_epoch = seen_epoch + tz_offset
  return (os.time() - seen_epoch) <= window_seconds
end
M.is_recently_seen = is_recently_seen

local function serialize_profile(row)
  if not row then return nil end
  local profile = {}
  for k, v in pairs(row) do profile[k] = v end
  if profile.guild_id ~= nil then profile.guild_id = tostring(profile.guild_id) end
  profile.display_name = profile.display_name or profile.username
  profile.public_profile = db.tobool(profile.public_profile)
  profile.webhook_verified = profile.webhook_verified_at ~= nil
  profile.discord_dm_verified = profile.discord_dm_verified_at ~= nil
  profile.verification_verified = (profile.webhook_verified_at ~= nil) or (profile.email_verified_at ~= nil) or (profile.discord_dm_verified_at ~= nil)
  profile.verification_pending = ((profile.verification_webhook_url ~= nil and profile.verification_webhook_url ~= "")
    or (profile.discord_user_id ~= nil and profile.discord_user_id ~= "")) and not profile.verification_verified
  profile.verification_webhook_configured = profile.verification_webhook_url ~= nil and profile.verification_webhook_url ~= ""
  profile.email_verified = profile.verification_verified
  profile.has_password = profile.password_hash ~= nil
  profile.is_online = is_recently_seen(profile.last_seen_at)
  profile.password_hash = nil
  local cjson = require("cjson.safe")
  for _, key in ipairs({ "panel_preferences", "profile_tags", "profile_links" }) do
    local v = profile[key]
    if type(v) == "string" then
      local decoded = cjson.decode(v)
      profile[key] = (type(decoded) == "table") and decoded or {}
    elseif type(v) ~= "table" then
      profile[key] = {}
    end
  end
  return profile
end
M.serialize_profile = serialize_profile

function M.get_account_profile(username, guild_id)
  local uname = normalize_username(username)
  if not uname then return nil end
  local row = db.fetchone(
    SCHEMA,
    "SELECT " .. PROFILE_COLUMNS .. " FROM " .. TABLE .. " WHERE username = %s AND guild_id = %s LIMIT 1",
    uname, guild_id
  )
  return serialize_profile(row)
end

-- Loads and cleans an account's saved panel_preferences (theme/accent/layout
-- etc.), for threading into html.layout()'s `preferences` option so the
-- rendered page shell actually reflects what the user saved on /appearance,
-- instead of every page always rendering html.DEFAULT_PREFERENCES. Returns
-- profiles.default_panel_preferences() (unsaved) if there's no scoped guild
-- or no stored row, mirroring GET /api/users/preferences' fallback.
function M.get_panel_preferences(username, guild_id)
  local profiles = require("profiles")
  local defaults = profiles.default_panel_preferences()
  local uname = normalize_username(username)
  if not uname or not guild_id or guild_id == "" then return defaults end
  local profile = M.get_account_profile(uname, guild_id)
  if not profile then return defaults end
  local stored = (type(profile.panel_preferences) == "table") and profile.panel_preferences or nil
  local ok, prefs = pcall(profiles.clean_panel_preferences, stored, defaults)
  if not ok then return defaults end
  return prefs
end

-- Every column update_account_profile/update_account_admin is allowed to
-- touch. Mirrors helpers.py's ACCOUNT_PROFILE_FIELDS (derived from
-- ACCOUNT_PROFILE_COLUMNS) — the actual field-level shape/enum validation
-- happens one layer up in profiles.lua's clean_profile_updates(), this is
-- just the SQL-injection-proofing whitelist (column name -> true).
local ACCOUNT_PROFILE_FIELDS = {}
for _, name in ipairs({
  "email", "email_verified_at", "email_verification_token_hash", "email_verification_code_hash",
  "email_verification_sent_at", "verification_webhook_url", "verification_webhook_channel_id",
  "verification_webhook_name", "webhook_verified_at", "webhook_verification_code_hash",
  "webhook_verification_sent_at", "display_name", "avatar_url", "bio", "profile_headline",
  "profile_tags", "profile_links", "profile_banner_url", "profile_banner_mode", "profile_card_style",
  "profile_social_mode", "favorite_bot", "theme_accent", "public_profile", "server_invite_url",
  "server_name", "server_icon_url", "panel_preferences", "profile_quote", "profile_layout_mode",
  "profile_header_style", "profile_border_accent", "last_seen_at", "panel_role",
}) do
  ACCOUNT_PROFILE_FIELDS[name] = true
end

function M.get_account_by_id(account_id)
  -- Was missing profile_quote/profile_layout_mode/profile_header_style/
  -- profile_border_accent (present in PROFILE_COLUMNS, used by
  -- get_account_profile/search_account_profiles) -- since this is what
  -- feeds GET /api/users/:id/profile via social.get_public_account_profile,
  -- every public profile view silently dropped its quote and three of its
  -- six visual-style pickers regardless of what was saved.
  local row = db.fetchone(
    SCHEMA,
    "SELECT " .. PROFILE_COLUMNS:gsub("password_hash, ", "") .. " FROM " .. TABLE .. " WHERE id = %s LIMIT 1",
    tostring(account_id)
  )
  return serialize_profile(row)
end

-- updates: a plain table of column -> new value (values already normalized
-- by the caller — see profiles.lua). Unknown keys are silently dropped, same
-- as update_account_profile.py.
function M.update_account_profile(username, guild_id, updates)
  local uname = normalize_username(username)
  if not uname then return nil end
  local profiles = require("profiles")
  local assignments, values, n = {}, {}, 0
  for key, value in pairs(updates or {}) do
    if ACCOUNT_PROFILE_FIELDS[key] and key ~= "updated_at" then
      assignments[#assignments + 1] = key .. " = %s"
      n = n + 1
      -- profiles.NULL means "explicitly clear to SQL NULL" -- convert back
      -- to a real nil here (not earlier: a nil table value is indistinguishable
      -- from an absent key, which is exactly the bug this sentinel exists to
      -- avoid). A nil here is safe: it's a positional vararg element, not a
      -- table-key assignment, so it survives into db.execute/pg.lua's NULL
      -- binding. NOTE: can't write this as `x and nil or value` -- that Lua
      -- idiom breaks whenever the "true" branch is nil/false, since `or`
      -- then falls through to the second operand; needs a real if/else.
      if value == profiles.NULL then
        values[n] = nil
      else
        values[n] = value
      end
    end
  end
  if #assignments > 0 then
    n = n + 1
    values[n] = uname
    n = n + 1
    values[n] = guild_id
    db.execute(
      SCHEMA,
      "UPDATE " .. TABLE .. " SET " .. table.concat(assignments, ", ") .. " WHERE username = %s AND guild_id = %s",
      unpack(values, 1, n)
    )
  end
  return M.get_account_profile(uname, guild_id)
end

function M.update_account_panel_preferences(username, guild_id, preferences)
  local uname = normalize_username(username)
  if not uname then return nil end
  db.execute(
    SCHEMA,
    "UPDATE " .. TABLE .. " SET panel_preferences = %s WHERE username = %s AND guild_id = %s",
    cjson.encode(preferences or {}), uname, guild_id
  )
  return M.get_account_profile(uname, guild_id)
end

function M.search_account_profiles(query, limit, viewer_account_id, guild_id)
  local q = tostring(query or ""):match("^%s*(.-)%s*$")
  local safe_limit = math.max(1, math.min(50, tonumber(limit) or 24))
  local like = "%" .. q .. "%"
  local viewer_id = tostring(viewer_account_id or 0)
  local guild_clause = ""
  local params = { viewer_id }
  if guild_id ~= nil and tostring(guild_id) ~= "" then
    guild_clause = "AND guild_id = %s"
    params[#params + 1] = tostring(guild_id)
  end
  local base_params = { q, like, like, like, like, safe_limit }
  for _, p in ipairs(base_params) do params[#params + 1] = p end
  local sql = string.format(
    [[SELECT id, username, guild_id, email, email_verified_at,
             verification_webhook_url, verification_webhook_channel_id, verification_webhook_name,
             webhook_verified_at, webhook_verification_sent_at,
             display_name, avatar_url, bio,
             profile_headline, profile_tags, profile_links, profile_banner_url, profile_banner_mode, profile_card_style, profile_social_mode,
             favorite_bot, theme_accent,
             public_profile, server_invite_url, server_name, server_icon_url,
             profile_quote, profile_layout_mode, profile_header_style, profile_border_accent,
             created_at, last_login_at, last_seen_at, updated_at,
             EXISTS(
               SELECT 1 FROM account_follows mine
               WHERE mine.follower_account_id = %%s AND mine.followed_account_id = u.id
             ) AS followed_by_me
      FROM %s u
      WHERE public_profile = TRUE
        %s
        AND (
          %%s = ''
          OR username ILIKE %%s
          OR COALESCE(display_name, '') ILIKE %%s
          OR COALESCE(server_name, '') ILIKE %%s
          OR COALESCE(favorite_bot, '') ILIKE %%s
        )
      ORDER BY COALESCE(updated_at, created_at) DESC, username ASC
      LIMIT %%s]],
    TABLE, guild_clause
  )
  local rows = db.fetchall(SCHEMA, sql, unpack(params))
  local profiles = {}
  for _, row in ipairs(rows) do profiles[#profiles + 1] = serialize_profile(row) end

  -- Social snapshot + activity enrichment (deferred require: social.lua
  -- requires this module at load time, so this module cannot require it back
  -- at load time too without a cycle — calling it lazily here is safe since
  -- by the time any handler runs, every module is already loaded).
  local social = require("social")
  for _, profile in ipairs(profiles) do
    local snap = social.get_account_social_snapshot(tonumber(profile.id), tonumber(viewer_id))
    for k, v in pairs(snap) do profile[k] = v end
  end
  local guild_ids = {}
  for _, profile in ipairs(profiles) do guild_ids[#guild_ids + 1] = profile.guild_id end
  local dashboard = require("dashboard")
  local summaries = dashboard.get_music_activity_summary_for_guilds(require("config").music_bots, guild_ids)
  for _, profile in ipairs(profiles) do
    profile.activity = summaries[profile.guild_id] or dashboard.empty_music_activity_summary()
  end
  return profiles
end

function M.get_account_admin(account_id)
  local row = db.fetchone(
    SCHEMA,
    [[SELECT id, username, guild_id, email, email_verified_at, email_verification_sent_at,
             verification_webhook_url, verification_webhook_channel_id, verification_webhook_name,
             webhook_verified_at, webhook_verification_sent_at,
             password_hash,
             display_name, avatar_url, bio, profile_headline, profile_tags, profile_links, profile_banner_url, profile_banner_mode,
             profile_card_style, profile_social_mode, favorite_bot, theme_accent, public_profile,
             server_invite_url, server_name, server_icon_url, panel_preferences,
             profile_quote, profile_layout_mode, profile_header_style, profile_border_accent,
             panel_role, created_at, last_login_at, last_seen_at, updated_at
      FROM ]] .. TABLE .. [[ WHERE id = %s LIMIT 1]],
    tostring(account_id)
  )
  return serialize_profile(row)
end

function M.get_account_admin_data(query, limit)
  local q = tostring(query or ""):match("^%s*(.-)%s*$")
  local safe_limit = math.max(1, math.min(200, tonumber(limit) or 100))
  local like = "%" .. q .. "%"
  local summary = db.fetchone(
    SCHEMA,
    [[SELECT
        COUNT(*) AS total_accounts,
        SUM(CASE WHEN email IS NOT NULL THEN 1 ELSE 0 END) AS accounts_with_email,
        SUM(CASE WHEN webhook_verified_at IS NOT NULL OR email_verified_at IS NOT NULL THEN 1 ELSE 0 END) AS verified_emails,
        SUM(CASE WHEN verification_webhook_url IS NOT NULL AND verification_webhook_url != '' AND webhook_verified_at IS NULL AND email_verified_at IS NULL THEN 1 ELSE 0 END) AS pending_emails,
        SUM(CASE WHEN public_profile = TRUE THEN 1 ELSE 0 END) AS public_profiles,
        SUM(CASE WHEN password_hash IS NOT NULL AND password_hash != '' THEN 1 ELSE 0 END) AS passwords_set
      FROM ]] .. TABLE
  ) or {}
  local rows = db.fetchall(
    SCHEMA,
    [[SELECT id, username, guild_id, email, email_verified_at, email_verification_sent_at,
             verification_webhook_url, verification_webhook_channel_id, verification_webhook_name,
             webhook_verified_at, webhook_verification_sent_at,
             password_hash,
             display_name, favorite_bot, public_profile, server_name, panel_role,
             created_at, last_login_at, last_seen_at, updated_at
      FROM ]] .. TABLE .. [[
      WHERE (
        %s = ''
        OR username ILIKE %s
        OR CAST(guild_id AS TEXT) ILIKE %s
        OR COALESCE(email, '') ILIKE %s
        OR COALESCE(display_name, '') ILIKE %s
        OR COALESCE(server_name, '') ILIKE %s
      )
      ORDER BY COALESCE(updated_at, created_at) DESC, username ASC
      LIMIT %s]],
    q, like, like, like, like, like, safe_limit
  )
  local users = {}
  for _, row in ipairs(rows) do users[#users + 1] = serialize_profile(row) end
  return {
    summary = {
      total_accounts = db.toint(summary.total_accounts, 0),
      accounts_with_email = db.toint(summary.accounts_with_email, 0),
      verified_emails = db.toint(summary.verified_emails, 0),
      pending_emails = db.toint(summary.pending_emails, 0),
      public_profiles = db.toint(summary.public_profiles, 0),
      passwords_set = db.toint(summary.passwords_set, 0),
    },
    users = users,
    query = q,
    limit = safe_limit,
  }
end

local ADMIN_UPDATE_ALLOWED = { username = true, guild_id = true, email = true, display_name = true, public_profile = true, server_name = true }

-- Returns (account, err). On uniqueness conflicts err is a user-facing string
-- (mirrors update_account_admin.py's ValueError messages); account is nil.
function M.update_account_admin(account_id, updates)
  local safe_id = tostring(account_id)
  local unknown = {}
  for key in pairs(updates or {}) do
    if not ADMIN_UPDATE_ALLOWED[key] then unknown[#unknown + 1] = key end
  end
  if #unknown > 0 then
    table.sort(unknown)
    return nil, "Unsupported account fields: " .. table.concat(unknown, ", ")
  end

  local current = db.fetchone(SCHEMA, "SELECT id, username, guild_id, email FROM " .. TABLE .. " WHERE id = %s LIMIT 1", safe_id)
  if not current then return nil, "SwarmPanel account not found." end

  local cleaned = {}
  local reset_email_verification = false
  if updates.username ~= nil then
    local uname, err = normalize_username(updates.username)
    if not uname then return nil, err end
    cleaned.username = uname
  end
  if updates.guild_id ~= nil then
    cleaned.guild_id = tostring(updates.guild_id)
  end
  local profiles = require("profiles")
  if updates.email ~= nil then
    local email, err = normalize_email(updates.email)
    if err then return nil, err end
    cleaned.email = email or profiles.NULL
    reset_email_verification = true
  end
  if updates.display_name ~= nil then
    local dn = tostring(updates.display_name or ""):match("^%s*(.-)%s*$")
    cleaned.display_name = (dn ~= "" and dn:sub(1, 80)) or profiles.NULL
  end
  if updates.public_profile ~= nil then
    cleaned.public_profile = updates.public_profile and true or false
  end
  if updates.server_name ~= nil then
    local sn = tostring(updates.server_name or ""):match("^%s*(.-)%s*$")
    cleaned.server_name = (sn ~= "" and sn:sub(1, 120)) or profiles.NULL
  end

  -- cleaned.email may be profiles.NULL (explicit clear) -- resolve to a real
  -- nil for every comparison/query below; only the `cleaned` table itself
  -- keeps the sentinel, so update_account_admin's own assignment loop further
  -- down can still tell "clear" apart from "not touched".
  local next_email = current.email
  if updates.email ~= nil then
    if cleaned.email == profiles.NULL then
      next_email = nil
    else
      next_email = cleaned.email
    end
  end

  if reset_email_verification and (current.email or nil) == next_email then
    reset_email_verification = false -- email unchanged, don't clobber verification state
  end

  local next_username = cleaned.username or current.username
  local next_guild_id = cleaned.guild_id or tostring(current.guild_id)

  local conflict = db.fetchone(
    SCHEMA,
    [[SELECT id, username, guild_id, email FROM ]] .. TABLE .. [[
      WHERE id != %s AND (username = %s OR guild_id = %s OR (%s IS NOT NULL AND email = %s))
      LIMIT 1]],
    safe_id, next_username, next_guild_id, next_email, next_email
  )
  if conflict then
    if conflict.username == next_username then return nil, "That username is already registered." end
    if next_email and conflict.email == next_email then return nil, "That email is already registered." end
    return nil, "That guild ID is already registered to another account."
  end

  local assignments, values, n = {}, {}, 0
  for key, value in pairs(cleaned) do
    assignments[#assignments + 1] = key .. " = %s"
    n = n + 1
    -- see update_account_profile's comment: `x and nil or value` is broken
    -- Lua here, needs a real if/else.
    if value == profiles.NULL then
      values[n] = nil
    else
      values[n] = value
    end
  end
  if reset_email_verification then
    for _, col in ipairs({ "email_verified_at", "email_verification_token_hash", "email_verification_code_hash", "email_verification_sent_at" }) do
      assignments[#assignments + 1] = col .. " = NULL"
    end
  end
  if #assignments > 0 then
    n = n + 1
    values[n] = safe_id
    db.execute(SCHEMA, "UPDATE " .. TABLE .. " SET " .. table.concat(assignments, ", ") .. " WHERE id = %s", unpack(values, 1, n))
  end

  if cleaned.guild_id and cleaned.guild_id ~= tostring(current.guild_id) then
    db.execute(SCHEMA, "DELETE FROM guild_locks WHERE guild_id = %s", tostring(current.guild_id))
    db.execute(SCHEMA, "INSERT INTO guild_locks (guild_id, username, created_at) VALUES (%s, %s, CURRENT_TIMESTAMP)", next_guild_id, next_username)
  elseif cleaned.username and cleaned.username ~= current.username then
    db.execute(SCHEMA, "UPDATE guild_locks SET username = %s WHERE guild_id = %s", next_username, next_guild_id)
  end

  return M.get_account_admin(safe_id), nil
end

function M.set_account_panel_role(account_id, moderator)
  local role = moderator and "moderator" or "member"
  db.execute(SCHEMA, "UPDATE " .. TABLE .. " SET panel_role = %s WHERE id = %s", role, tostring(account_id))
  return M.get_account_admin(account_id)
end

-- FINDING: verified live via `SELECT ... FROM pg_constraint WHERE contype='f'`
-- that the accountlogins schema has ZERO foreign-key constraints anywhere —
-- not just the missing-DEFAULT gap noted above, the account_follows/
-- account_friend_requests/account_messages/account_notifications ->
-- users(id) ON DELETE CASCADE constraints from app/db/core.py's DDL never
-- made it into this migrated Postgres schema at all. app/db/accounts.py's
-- delete_account_admin() only ever deletes the users + guild_locks rows and
-- relies entirely on that (absent) cascade for the four social tables — so
-- the ORIGINAL Python backend leaks orphaned follow/friend/message/
-- notification rows on every real account deletion too, this isn't a
-- regression. Fixed here at the application layer (explicit deletes) since
-- restoring the FK constraints is a schema DDL change and was blocked by the
-- sandbox's auto-mode classifier when attempted — see final report.
function M.delete_account_admin(account_id)
  local safe_id = tostring(account_id)
  local current = db.fetchone(SCHEMA, "SELECT guild_id FROM " .. TABLE .. " WHERE id = %s LIMIT 1", safe_id)
  if not current then return nil, "SwarmPanel account not found." end
  db.execute(SCHEMA, "DELETE FROM account_follows WHERE follower_account_id = %s OR followed_account_id = %s", safe_id, safe_id)
  db.execute(SCHEMA, "DELETE FROM account_friend_requests WHERE requester_account_id = %s OR addressee_account_id = %s", safe_id, safe_id)
  db.execute(SCHEMA, "DELETE FROM account_messages WHERE sender_account_id = %s OR recipient_account_id = %s", safe_id, safe_id)
  db.execute(SCHEMA, "DELETE FROM account_notifications WHERE recipient_account_id = %s", safe_id)
  db.execute(SCHEMA, "DELETE FROM " .. TABLE .. " WHERE id = %s", safe_id)
  db.execute(SCHEMA, "DELETE FROM guild_locks WHERE guild_id = %s", tostring(current.guild_id))
  return true
end

function M.set_account_webhook_verified_admin(account_id, verified)
  local v = verified and true or false
  db.execute(
    SCHEMA,
    [[UPDATE ]] .. TABLE .. [[ SET
        webhook_verified_at = CASE WHEN %s THEN CURRENT_TIMESTAMP ELSE NULL END,
        email_verified_at = CASE WHEN %s THEN email_verified_at ELSE NULL END,
        email_verification_token_hash = CASE WHEN %s THEN email_verification_token_hash ELSE NULL END,
        email_verification_code_hash = CASE WHEN %s THEN email_verification_code_hash ELSE NULL END,
        email_verification_sent_at = CASE WHEN %s THEN email_verification_sent_at ELSE NULL END,
        webhook_verification_code_hash = CASE WHEN %s THEN NULL ELSE webhook_verification_code_hash END,
        webhook_verification_sent_at = CASE WHEN %s THEN NULL ELSE webhook_verification_sent_at END
      WHERE id = %s]],
    v, v, v, v, v, v, v, tostring(account_id)
  )
  return M.get_account_admin(account_id)
end

-- Self-service password change: unlike reset_account_password_admin (no
-- current-password check, admin-only), this verifies current_password
-- against the stored hash first. Mirrors app/db's update_account_password.
function M.update_account_password(username, guild_id, current_password, new_password)
  local uname = normalize_username(username)
  if not uname then return nil, "Invalid username." end
  local row = db.fetchone(
    SCHEMA,
    "SELECT id, password_hash FROM " .. TABLE .. " WHERE username = %s AND guild_id = %s LIMIT 1",
    uname, guild_id
  )
  if not row then return nil end
  local current_ok = row.password_hash and auth.verify_password_hash(tostring(current_password or ""), row.password_hash) or false
  if not current_ok then
    error("Current password is incorrect.", 0)
  end
  local password, err = normalize_password(new_password, "New password")
  if not password then error(err, 0) end
  db.execute(SCHEMA, "UPDATE " .. TABLE .. " SET password_hash = %s WHERE id = %s", auth.password_hash(password), row.id)
  return M.get_account_profile(uname, guild_id)
end

function M.reset_account_password_admin(account_id, new_password)
  local password, err = normalize_password(new_password, "Password")
  if not password then return nil, err end
  db.execute(SCHEMA, "UPDATE " .. TABLE .. " SET password_hash = %s WHERE id = %s", auth.password_hash(password), tostring(account_id))
  return M.get_account_admin(account_id), nil
end

-- Real (not stubbed) self-service registration: creates the row + claims the
-- guild-id uniqueness lock, same two inserts as register_account_login.py,
-- PLUS (now ported — see notify.lua) the Discord-webhook verification
-- enrollment columns: verification_webhook_url/channel_id/name and the
-- hashed verification code. webhook_verification_code is the RAW code (the
-- caller — routes.lua — generates it via a fresh random code and sends it
-- through notify.send_verification_webhook_code() after this call returns;
-- only the hash is ever persisted, mirroring register_account_login.py's
-- webhook_verification_code_hash column).
function M.register_account_login(username, guild_id, password, email, verification_webhook_url, verification_webhook_channel_id, verification_webhook_name, webhook_verification_code)
  local uname, uerr = normalize_username(username)
  if not uname then error(uerr, 0) end
  local gid = tostring(guild_id or "")
  if gid == "" or gid == "0" or not gid:match("^%d+$") then
    error("Guild ID must be a positive integer.", 0)
  end
  local pw, perr = normalize_password(password)
  if not pw then error(perr, 0) end
  local em, eerr = normalize_email(email)
  if eerr then error(eerr, 0) end
  local webhook_url = tostring(verification_webhook_url or ""):match("^%s*(.-)%s*$")
  if webhook_url == "" then webhook_url = nil end
  local webhook_channel_id = tostring(verification_webhook_channel_id or ""):match("^%s*(.-)%s*$")
  if webhook_channel_id == "" then webhook_channel_id = nil end
  local webhook_name = tostring(verification_webhook_name or ""):match("^%s*(.-)%s*$"):sub(1, 120)
  if webhook_name == "" then webhook_name = nil end
  local code_hash = (webhook_url and webhook_verification_code) and auth.verification_token_hash(webhook_verification_code) or nil

  local existing = db.fetchone(
    SCHEMA,
    "SELECT username, guild_id, email FROM " .. TABLE .. " WHERE username = %s OR guild_id = %s OR (%s IS NOT NULL AND email = %s) LIMIT 1",
    uname, gid, em, em
  )
  if existing then
    if existing.username == uname then error("That username is already registered.", 0) end
    if em and existing.email == em then error("That email is already registered.", 0) end
    error("That guild ID is already registered to another account.", 0)
  end

  -- created_at/public_profile/panel_role are set explicitly rather than
  -- relying on DB column defaults — see the schema-defaults note in
  -- social.lua's set_account_follow(): this accountlogins schema is missing
  -- several DEFAULT clauses that the Python original's DDL specifies.
  local ok, err = pcall(function()
    db.execute(SCHEMA, "BEGIN")
    db.execute(SCHEMA, "INSERT INTO guild_locks (guild_id, username, created_at) VALUES (%s, %s, CURRENT_TIMESTAMP)", gid, uname)
    db.execute(
      SCHEMA,
      [[INSERT INTO ]] .. TABLE .. [[ (
          username, guild_id, password_hash, email, public_profile, panel_role, created_at,
          verification_webhook_url, verification_webhook_channel_id, verification_webhook_name,
          webhook_verification_code_hash, webhook_verification_sent_at
        )
        VALUES (%s, %s, %s, %s, TRUE, 'member', CURRENT_TIMESTAMP, %s, %s, %s, %s, CASE WHEN %s IS NULL THEN NULL ELSE CURRENT_TIMESTAMP END)]],
      uname, gid, auth.password_hash(pw), em, webhook_url, webhook_channel_id, webhook_name, code_hash, code_hash
    )
    db.execute(SCHEMA, "COMMIT")
  end)
  if not ok then
    pcall(db.execute, SCHEMA, "ROLLBACK")
    error(err, 0)
  end
  return { username = uname, guild_id = gid, email = em, verification_webhook_url = webhook_url }
end

-- Port of app/db/accounts.py's update_account_verification_webhook(): a nil
-- webhook_url clears enrollment entirely; an unchanged (url, channel, name)
-- triple is a no-op that just returns the current profile (avoids clobbering
-- webhook_verified_at on a redundant save); anything else replaces the
-- binding and resets all verification state, matching the Python original.
function M.update_account_verification_webhook(username, guild_id, webhook_url, webhook_channel_id, webhook_name)
  local uname = normalize_username(username)
  if not uname then return nil end
  local normalized_url = tostring(webhook_url or ""):match("^%s*(.-)%s*$")
  if normalized_url == "" then normalized_url = nil end
  local normalized_channel = tostring(webhook_channel_id or ""):match("^%s*(.-)%s*$")
  if normalized_channel == "" then normalized_channel = nil end
  local normalized_name = tostring(webhook_name or ""):match("^%s*(.-)%s*$"):sub(1, 120)
  if normalized_name == "" then normalized_name = nil end

  local current = db.fetchone(
    SCHEMA,
    "SELECT verification_webhook_url, verification_webhook_channel_id, verification_webhook_name FROM " .. TABLE .. " WHERE username = %s AND guild_id = %s LIMIT 1",
    uname, guild_id
  )
  if not current then return nil end
  local same = (tostring(current.verification_webhook_url or "") == tostring(normalized_url or ""))
    and (tostring(current.verification_webhook_channel_id or "") == tostring(normalized_channel or ""))
    and (tostring(current.verification_webhook_name or "") == tostring(normalized_name or ""))
  if same then return M.get_account_profile(uname, guild_id) end

  db.execute(
    SCHEMA,
    [[UPDATE ]] .. TABLE .. [[ SET
        verification_webhook_url = %s,
        verification_webhook_channel_id = %s,
        verification_webhook_name = %s,
        webhook_verified_at = NULL,
        webhook_verification_code_hash = NULL,
        webhook_verification_sent_at = NULL
      WHERE username = %s AND guild_id = %s]],
    normalized_url, normalized_channel, normalized_name, uname, guild_id
  )
  return M.get_account_profile(uname, guild_id)
end

-- Port of issue_account_webhook_verification_code(): only takes effect while
-- a webhook is configured and the account isn't already verified — matches
-- the WHERE clause on the Python UPDATE exactly (a no-op UPDATE isn't an
-- error, it just leaves the profile's verification state untouched, same as
-- the original).
function M.issue_account_webhook_verification_code(username, guild_id, code)
  local uname = normalize_username(username)
  if not uname then return nil end
  local code_hash = auth.verification_token_hash(code)
  db.execute(
    SCHEMA,
    [[UPDATE ]] .. TABLE .. [[ SET
        webhook_verification_code_hash = %s,
        webhook_verification_sent_at = CURRENT_TIMESTAMP
      WHERE username = %s AND guild_id = %s
        AND verification_webhook_url IS NOT NULL AND verification_webhook_url != ''
        AND webhook_verified_at IS NULL]],
    code_hash, uname, guild_id
  )
  return M.get_account_profile(uname, guild_id)
end

function M.issue_account_webhook_verification_code_by_id(account_id, code)
  local code_hash = auth.verification_token_hash(code)
  db.execute(
    SCHEMA,
    [[UPDATE ]] .. TABLE .. [[ SET
        webhook_verification_code_hash = %s,
        webhook_verification_sent_at = CURRENT_TIMESTAMP
      WHERE id = %s
        AND verification_webhook_url IS NOT NULL AND verification_webhook_url != ''
        AND webhook_verified_at IS NULL]],
    code_hash, tostring(account_id)
  )
  return M.get_account_admin(account_id)
end

-- Port of verify_account_webhook_code(): code must match the stored hash AND
-- still be within max_age_seconds of when it was issued (webhook_verification_sent_at).
function M.verify_account_webhook_code(username, guild_id, code, max_age_seconds)
  local uname = normalize_username(username)
  if not uname then return nil end
  local code_hash = auth.verification_token_hash(code)
  local row = db.fetchone(
    SCHEMA,
    [[SELECT username, guild_id FROM ]] .. TABLE .. [[
      WHERE username = %s AND guild_id = %s
        AND verification_webhook_url IS NOT NULL AND verification_webhook_url != ''
        AND webhook_verification_code_hash = %s
        AND webhook_verification_sent_at IS NOT NULL
        AND webhook_verification_sent_at >= NOW() - (%s || ' seconds')::interval
      LIMIT 1]],
    uname, guild_id, code_hash, tostring(math.max(1, tonumber(max_age_seconds) or 1))
  )
  if not row then return nil end
  db.execute(
    SCHEMA,
    [[UPDATE ]] .. TABLE .. [[ SET
        webhook_verified_at = CURRENT_TIMESTAMP,
        webhook_verification_code_hash = NULL,
        webhook_verification_sent_at = NULL
      WHERE username = %s AND guild_id = %s]],
    row.username, row.guild_id
  )
  return M.get_account_profile(row.username, row.guild_id)
end

-- Discord DM verification: straight-to-account-owner alternative to the
-- guild-webhook flow above, for operators who'd rather prove ownership of
-- their own Discord account than stand up a channel webhook. Same
-- code+TTL shape as the webhook path, just keyed on discord_user_id instead
-- of verification_webhook_url, so /api/session/verification/verify (below)
-- can check both in one query.
function M.update_account_discord_user_id(username, guild_id, discord_user_id)
  ensure_discord_dm_columns()
  local uname = normalize_username(username)
  if not uname then return nil end
  local normalized_id = tostring(discord_user_id or ""):match("^%s*(.-)%s*$")
  if normalized_id ~= "" and not normalized_id:match("^%d+$") then
    error("Discord User ID must be numbers only.", 0)
  end
  if normalized_id == "" then normalized_id = nil end
  db.execute(
    SCHEMA,
    [[UPDATE ]] .. TABLE .. [[ SET
        discord_user_id = %s, discord_username = NULL,
        discord_dm_verified_at = NULL, discord_dm_verification_code_hash = NULL, discord_dm_verification_sent_at = NULL
      WHERE username = %s AND guild_id = %s]],
    normalized_id, uname, guild_id
  )
  return M.get_account_profile(uname, guild_id)
end

function M.issue_account_discord_dm_verification_code(username, guild_id, code)
  ensure_discord_dm_columns()
  local uname = normalize_username(username)
  if not uname then return nil end
  local code_hash = auth.verification_token_hash(code)
  db.execute(
    SCHEMA,
    [[UPDATE ]] .. TABLE .. [[ SET
        discord_dm_verification_code_hash = %s,
        discord_dm_verification_sent_at = CURRENT_TIMESTAMP
      WHERE username = %s AND guild_id = %s
        AND discord_user_id IS NOT NULL AND discord_user_id != ''
        AND discord_dm_verified_at IS NULL]],
    code_hash, uname, guild_id
  )
  return M.get_account_profile(uname, guild_id)
end

-- Port-alike of verify_account_webhook_code() for the DM path; also records
-- discord_username (cosmetic "Verified as @handle" display) when the caller
-- passes one along (best-effort lookup, see notify.lua's send_discord_dm doc).
function M.verify_account_discord_dm_code(username, guild_id, code, max_age_seconds, discord_username)
  ensure_discord_dm_columns()
  local uname = normalize_username(username)
  if not uname then return nil end
  local code_hash = auth.verification_token_hash(code)
  local row = db.fetchone(
    SCHEMA,
    [[SELECT username, guild_id FROM ]] .. TABLE .. [[
      WHERE username = %s AND guild_id = %s
        AND discord_user_id IS NOT NULL AND discord_user_id != ''
        AND discord_dm_verification_code_hash = %s
        AND discord_dm_verification_sent_at IS NOT NULL
        AND discord_dm_verification_sent_at >= NOW() - (%s || ' seconds')::interval
      LIMIT 1]],
    uname, guild_id, code_hash, tostring(math.max(1, tonumber(max_age_seconds) or 1))
  )
  if not row then return nil end
  db.execute(
    SCHEMA,
    [[UPDATE ]] .. TABLE .. [[ SET
        discord_dm_verified_at = CURRENT_TIMESTAMP,
        discord_username = COALESCE(%s, discord_username),
        discord_dm_verification_code_hash = NULL,
        discord_dm_verification_sent_at = NULL
      WHERE username = %s AND guild_id = %s]],
    discord_username, row.username, row.guild_id
  )
  return M.get_account_profile(row.username, row.guild_id)
end

-- Port of update_account_email(): changing the email resets all email/webhook-
-- independent verification bookkeeping tied to it (the *_verification_* email
-- columns only — webhook verification state is untouched, matching the
-- Python UPDATE's column list).
function M.update_account_email(username, guild_id, email)
  local uname = normalize_username(username)
  if not uname then return nil end
  local normalized, eerr = normalize_email(email)
  if eerr then error(eerr, 0) end
  local current = db.fetchone(SCHEMA, "SELECT email FROM " .. TABLE .. " WHERE username = %s AND guild_id = %s LIMIT 1", uname, guild_id)
  if not current then return nil end
  if tostring(current.email or "") == tostring(normalized or "") then return M.get_account_profile(uname, guild_id) end
  local ok, err = pcall(db.execute, SCHEMA,
    [[UPDATE ]] .. TABLE .. [[ SET
        email = %s,
        email_verified_at = NULL,
        email_verification_token_hash = NULL,
        email_verification_code_hash = NULL,
        email_verification_sent_at = NULL
      WHERE username = %s AND guild_id = %s]],
    normalized, uname, guild_id
  )
  if not ok then
    local message = tostring(err):lower()
    if message:match("duplicate") or message:match("unique") then
      error("That email is already registered.", 0)
    end
    error(err, 0)
  end
  return M.get_account_profile(uname, guild_id)
end

return M
