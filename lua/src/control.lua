-- Port of app/db/bots.py's control_bot() — the actual bot command path. The
-- panel writes intent rows into <prefix>_swarm_overrides /
-- <prefix>_swarm_direct_orders / <prefix>_queue*, which the already-rewritten
-- Lua music bots poll (same mechanism as the Python bots used). This is
-- pure DB-write business logic with no Discord-API dependency, so it ports
-- 1:1 onto Postgres — only the MySQL-specific syntax (REPLACE INTO, ON
-- DUPLICATE KEY UPDATE) needed translating to Postgres's INSERT ... ON
-- CONFLICT.
--
-- NOTE on guild_id: always pass/format guild_id as the STRING the caller
-- gave us (a Discord snowflake), never as a converted Lua number — see the
-- precision note in dashboard.lua. pg.lua's escape_literal() quotes a Lua
-- string as a SQL string literal, which Postgres implicitly casts to bigint
-- in a bigint column/comparison context, so this is safe and precise.
local db = require("db")
local notify = require("notify")
local config = require("config")

local M = {}

-- Gate: mirrors swarmlua.command_gate's relay-before-execute pattern (see
-- the Lua music bots' own poll_direct_orders/poll_swarm_overrides) for the
-- three actions below (CLEAR/RESET_QUEUE/SHUFFLE) that mutate a bot's queue
-- tables directly from here rather than going through the gated
-- swarm_direct_orders/swarm_overrides tables those bots poll -- those three
-- bypassed "commands only accepted from GWS Commands" entirely, since
-- nothing about them ever reached a bot's own poll loop to gate. Posts a
-- summary into the target bot's own GWS Commands thread using that bot's
-- own Discord token (already held here for the DM/verification flow in
-- notify.lua) and only proceeds if that succeeds -- same fail-closed
-- contract as the bot-side gate.
local function relay_to_command_thread(bot, gid, action, actor)
  local thread_row = db.fetchone(bot.db_schema, string.format(
    "SELECT thread_id FROM %s_command_thread WHERE guild_id = %%s", bot.table_prefix), gid)
  local thread_id = thread_row and thread_row.thread_id
  if not thread_id then
    return false, ("%s's GWS Commands channel isn't set up in this server yet -- try again shortly."):format(bot.display_name)
  end
  local token = config.bot_tokens[bot.key]
  if not token or token == "" then
    return false, "No Discord token configured for " .. bot.display_name .. "."
  end
  local status, resp = notify.bot_api_call("POST", "/channels/" .. tostring(thread_id) .. "/messages", token, {
    embeds = { {
      title = "\xE2\x96\xB6\xEF\xB8\x8F " .. tostring(action),
      description = ("**Command:** `%s`\n**Guild:** `%s`\n**Issued by:** %s"):format(tostring(action), tostring(gid), tostring(actor or "unknown")),
      color = 0x5865F2,
    } },
  })
  if type(status) ~= "number" or status >= 300 then
    return false, "Could not post to " .. bot.display_name .. "'s GWS Commands channel: " .. tostring((type(resp) == "table" and resp.message) or status)
  end
  return true, nil
end

local VALID_ACTIONS = {
  PAUSE = true, RESUME = true, SKIP = true, STOP = true, RESTART = true,
  CLEAR = true, RESET_QUEUE = true, LOOP = true, FILTER = true, SHUFFLE = true,
  SMART_RECOMMEND = true, PLAY = true, RECOVER = true, LEAVE = true,
  SET_HOME = true, SEEK = true,
}
M.VALID_ACTIONS = VALID_ACTIONS

-- `payload.field or "0"` looks like a nil-coalesce but isn't one: Lua only
-- treats nil/false as falsy, so an empty string (exactly what an unset
-- <select> sends as its value -- e.g. the /controls page's "Choose channel"/
-- "None" placeholder options) sails through as "" instead of falling back to
-- "0", which then blows up as `invalid input syntax for type bigint: ""`
-- once it hits a bigint column. Every optional channel-id field needs this
-- instead of the bare `or`.
local function channel_id_or_default(v)
  v = tostring(v or "")
  if v == "" then return "0" end
  return v
end

local VALID_LOOP_MODES = { off = true, song = true, queue = true }
local VALID_FILTER_MODES = {
  none = true, nightcore = true, vaporwave = true, bassboost = true, ["8d"] = true,
  karaoke = true, tremolo = true, vibrato = true, lowpass = true, lofi = true,
  electronic = true, party = true, radio = true, cinema = true,
}

local function ensure_overrides_table(schema, prefix)
  pcall(db.execute, schema, string.format(
    [[CREATE TABLE IF NOT EXISTS %s_swarm_overrides (
        guild_id BIGINT, bot_name VARCHAR(50), command VARCHAR(20),
        attempts INT NOT NULL DEFAULT 0, last_error TEXT NULL,
        PRIMARY KEY(guild_id, bot_name))]], prefix))
  -- BUGFIX: several bots' _swarm_overrides tables predate this DDL and were
  -- created (by an earlier Python-era schema) with `attempts INT NOT NULL`
  -- and no default. CREATE TABLE IF NOT EXISTS is a no-op against those, so
  -- set_override()'s INSERT -- which never supplied `attempts` -- violated
  -- the not-null constraint on every single call, aborting the transaction.
  -- Because nothing here checked db.execute()'s return value, that failure
  -- was invisible: control_bot() always reported success while the override
  -- row was never actually written, so bots silently never received any
  -- panel command. Some other bots' tables (created directly by the Lua bot
  -- code, e.g. strife/lockhart) instead have NEITHER column at all, so
  -- ADD COLUMN IF NOT EXISTS (not ALTER COLUMN ... SET DEFAULT, which
  -- errors outright if the column is simply missing) is required to
  -- self-heal both cases. Cheap metadata-only change, safe on every call.
  pcall(db.execute, schema, string.format(
    "ALTER TABLE %s_swarm_overrides ADD COLUMN IF NOT EXISTS attempts INT NOT NULL DEFAULT 0", prefix))
  pcall(db.execute, schema, string.format(
    "ALTER TABLE %s_swarm_overrides ADD COLUMN IF NOT EXISTS last_error TEXT NULL", prefix))
  -- issued_by: who (panel username) committed this override -- read by the
  -- Lua bots' swarmlua.command_gate relay, which posts it into that bot's
  -- own "GWS Commands" Discord thread before executing.
  pcall(db.execute, schema, string.format(
    "ALTER TABLE %s_swarm_overrides ADD COLUMN IF NOT EXISTS issued_by TEXT", prefix))
end

local function ensure_direct_orders_table(schema, prefix)
  pcall(db.execute, schema, string.format(
    [[CREATE TABLE IF NOT EXISTS %s_swarm_direct_orders (
        id SERIAL PRIMARY KEY, bot_name VARCHAR(50), guild_id BIGINT, vc_id BIGINT,
        text_channel_id BIGINT, command VARCHAR(50), data TEXT,
        attempts INT NOT NULL DEFAULT 0, last_error TEXT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)]], prefix))
  -- Same class of bug as ensure_overrides_table's BUGFIX above: several
  -- bots' _swarm_direct_orders tables already existed (created without a
  -- DEFAULT on `attempts`) before this DDL gained `DEFAULT 0`, so CREATE
  -- TABLE IF NOT EXISTS was a no-op against them and insert_direct_order's
  -- INSERT -- which never supplies `attempts` -- violated the not-null
  -- constraint on every call. That failure was invisible because nothing
  -- checked db.execute()'s return value, so every PLAY/RECOVER/LEAVE/SEEK
  -- order silently vanished while the panel still reported success.
  pcall(db.execute, schema, string.format(
    "ALTER TABLE %s_swarm_direct_orders ADD COLUMN IF NOT EXISTS attempts INT NOT NULL DEFAULT 0", prefix))
  pcall(db.execute, schema, string.format(
    "ALTER TABLE %s_swarm_direct_orders ADD COLUMN IF NOT EXISTS last_error TEXT NULL", prefix))
  -- issued_by: who (panel username) committed this order -- read by the
  -- Lua bots' swarmlua.command_gate relay, which posts it into that bot's
  -- own "GWS Commands" Discord thread before executing.
  pcall(db.execute, schema, string.format(
    "ALTER TABLE %s_swarm_direct_orders ADD COLUMN IF NOT EXISTS issued_by TEXT", prefix))
end

local function ensure_queue_table(schema, prefix)
  pcall(db.execute, schema, string.format(
    [[CREATE TABLE IF NOT EXISTS %s_queue (
        id SERIAL PRIMARY KEY, guild_id BIGINT, bot_name VARCHAR(50),
        video_url TEXT, title TEXT, requester_id BIGINT DEFAULT NULL)]], prefix))
end

local function ensure_home_table(schema, prefix)
  pcall(db.execute, schema, string.format(
    [[CREATE TABLE IF NOT EXISTS %s_bot_home_channels (
        guild_id BIGINT, bot_name VARCHAR(50), home_vc_id BIGINT,
        PRIMARY KEY (guild_id, bot_name))]], prefix))
end

local function set_override(schema, prefix, gid, bot_key, command, actor)
  ensure_overrides_table(schema, prefix)
  local ok, err = db.execute(
    schema,
    string.format(
      [[INSERT INTO %s_swarm_overrides (guild_id, bot_name, command, attempts, issued_by) VALUES (%%s, %%s, %%s, 0, %%s)
        ON CONFLICT (guild_id, bot_name) DO UPDATE SET command = EXCLUDED.command, issued_by = EXCLUDED.issued_by]],
      prefix
    ),
    gid, bot_key, command, actor or "unknown"
  )
  -- Previously unchecked: a failed write here (e.g. the not-null-without-
  -- default bug above) left the panel reporting success while the bot never
  -- saw the command. Surface it as a real error instead.
  if not ok then error("failed to write swarm override: " .. tostring(err), 0) end
end

local function clear_pending_orders(schema, prefix, gid, bot_key)
  pcall(db.execute, schema, string.format("DELETE FROM %s_swarm_overrides WHERE guild_id = %%s AND bot_name = %%s", prefix), gid, bot_key)
  pcall(db.execute, schema, string.format("DELETE FROM %s_swarm_direct_orders WHERE guild_id = %%s AND bot_name = %%s", prefix), gid, bot_key)
end

local function insert_direct_order(schema, prefix, bot_key, gid, vc_id, text_channel_id, command, data, actor)
  ensure_direct_orders_table(schema, prefix)
  local ok, err = db.execute(
    schema,
    string.format(
      "INSERT INTO %s_swarm_direct_orders (bot_name, guild_id, vc_id, text_channel_id, command, data, issued_by) VALUES (%%s, %%s, %%s, %%s, %%s, %%s, %%s)",
      prefix
    ),
    bot_key, gid, vc_id, text_channel_id, command, data, actor or "unknown"
  )
  -- Previously unchecked, same as set_override()'s earlier fix -- a failed
  -- write here left the panel reporting success while the bot never saw
  -- the order.
  if not ok then error("failed to write swarm direct order: " .. tostring(err), 0) end
end

-- shuffle: pull the live queue, keep the first (now-playing/head) row fixed,
-- Fisher-Yates the rest, rewrite the table, mirror into the backup queue.
local function shuffle_live_queue(schema, prefix, gid, bot_key)
  ensure_queue_table(schema, prefix)
  local rows = db.fetchall(
    schema, string.format("SELECT * FROM %s_queue WHERE guild_id = %%s AND bot_name = %%s ORDER BY id ASC", prefix), gid, bot_key
  )
  if #rows <= 1 then return #rows end

  local first = table.remove(rows, 1)
  math.randomseed(os.time() + os.clock() * 1000)
  for i = #rows, 2, -1 do
    local j = math.random(1, i)
    rows[i], rows[j] = rows[j], rows[i]
  end
  table.insert(rows, 1, first)

  db.execute(schema, string.format("DELETE FROM %s_queue WHERE guild_id = %%s AND bot_name = %%s", prefix), gid, bot_key)
  for _, row in ipairs(rows) do
    db.execute(
      schema,
      string.format("INSERT INTO %s_queue (guild_id, bot_name, video_url, title, requester_id, track_uid) VALUES (%%s, %%s, %%s, %%s, %%s, %%s)", prefix),
      row.guild_id, row.bot_name, row.video_url, row.title, row.requester_id, row.track_uid
    )
  end

  pcall(function()
    pcall(db.execute, schema, string.format(
      [[CREATE TABLE IF NOT EXISTS %s_queue_backup (
          id SERIAL PRIMARY KEY, guild_id BIGINT, bot_name VARCHAR(50),
          video_url TEXT, title TEXT, requester_id BIGINT DEFAULT NULL)]], prefix))
    db.execute(schema, string.format("DELETE FROM %s_queue_backup WHERE guild_id = %%s AND bot_name = %%s", prefix), gid, bot_key)
    for _, row in ipairs(rows) do
      db.execute(
        schema,
        string.format("INSERT INTO %s_queue_backup (guild_id, bot_name, video_url, title, requester_id) VALUES (%%s, %%s, %%s, %%s, %%s)", prefix),
        row.guild_id, row.bot_name, row.video_url, row.title, row.requester_id
      )
    end
  end)

  return #rows
end

local function prime_panel_playback_defaults(schema, prefix, gid, bot_key)
  pcall(db.execute, schema, string.format("CREATE TABLE IF NOT EXISTS %s_guild_settings (guild_id BIGINT PRIMARY KEY)", prefix))
  pcall(db.execute, schema, string.format(
    [[INSERT INTO %s_guild_settings (guild_id, loop_mode) VALUES (%%s, %%s)
      ON CONFLICT (guild_id) DO UPDATE SET loop_mode = EXCLUDED.loop_mode]], prefix
  ), gid, "queue")
  return shuffle_live_queue(schema, prefix, gid, bot_key)
end

local function smart_query_from_title(title)
  title = tostring(title or "")
  title = title:gsub("https?://%S+", "")
  title = title:gsub("%s+", " "):match("^%s*(.-)%s*$")
  if #title > 180 then title = title:sub(1, 180) end
  return title
end

-- Returns (result_table, err). result_table has at least {action=, message=}.
function M.control_bot(bot, gid, action, payload, actor)
  local schema, prefix = bot.db_schema, bot.table_prefix
  action = tostring(action or ""):upper()
  actor = tostring(actor or "unknown")
  if not VALID_ACTIONS[action] then return nil, "Unsupported action: " .. action end

  local result = { action = action, command = action }
  local ok, err = pcall(function()
    db.execute(schema, "BEGIN")

    if action == "PAUSE" or action == "RESUME" or action == "SKIP" or action == "STOP" then
      clear_pending_orders(schema, prefix, gid, bot.key)
      set_override(schema, prefix, gid, bot.key, action, actor)
      pcall(db.execute, schema, string.format("ALTER TABLE %s_playback_state ADD COLUMN IF NOT EXISTS is_paused BOOLEAN DEFAULT FALSE", prefix))
      if action == "PAUSE" then
        db.execute(schema, string.format("UPDATE %s_playback_state SET is_paused = TRUE, is_playing = FALSE WHERE guild_id = %%s AND bot_name = %%s", prefix), gid, bot.key)
      elseif action == "RESUME" then
        db.execute(schema, string.format("UPDATE %s_playback_state SET is_paused = FALSE, is_playing = TRUE WHERE guild_id = %%s AND bot_name = %%s", prefix), gid, bot.key)
      elseif action == "STOP" or action == "SKIP" then
        db.execute(schema, string.format("UPDATE %s_playback_state SET is_paused = FALSE WHERE guild_id = %%s AND bot_name = %%s", prefix), gid, bot.key)
      end
      result.message = string.format("%s will %s in guild %s.", bot.display_name, action:lower(), gid)

    elseif action == "RESTART" then
      clear_pending_orders(schema, prefix, "0", bot.key)
      set_override(schema, prefix, "0", bot.key, "RESTART", actor)
      pcall(db.execute, schema, string.format("UPDATE %s_playback_state SET is_playing = FALSE, is_paused = FALSE WHERE bot_name = %%s", prefix), bot.key)
      result.message = "Restart signal queued for " .. bot.display_name .. "."

    elseif action == "CLEAR" then
      local relay_ok, relay_err = relay_to_command_thread(bot, gid, action, actor)
      if not relay_ok then error(relay_err, 0) end
      clear_pending_orders(schema, prefix, gid, bot.key)
      set_override(schema, prefix, gid, bot.key, "STOP", actor)
      ensure_queue_table(schema, prefix)
      db.execute(schema, string.format("DELETE FROM %s_queue WHERE guild_id = %%s AND bot_name = %%s", prefix), gid, bot.key)
      pcall(db.execute, schema, string.format("DELETE FROM %s_queue_backup WHERE guild_id = %%s AND bot_name = %%s", prefix), gid, bot.key)
      pcall(db.execute, schema, string.format(
        [[UPDATE %s_playback_state SET title = NULL, video_url = NULL, position_seconds = 0,
          is_playing = FALSE, is_paused = FALSE WHERE guild_id = %%s AND bot_name = %%s]], prefix
      ), gid, bot.key)
      pcall(db.execute, schema, string.format(
        [[UPDATE %s_voice_state SET desired_connected = FALSE, connected_channel_id = NULL,
          disconnected_at = CURRENT_TIMESTAMP WHERE guild_id = %%s AND bot_name = %%s]], prefix
      ), gid, bot.key)
      result.message = string.format("Cleared the queue and current playback for guild %s on %s.", gid, bot.display_name)

    elseif action == "RESET_QUEUE" then
      local relay_ok, relay_err = relay_to_command_thread(bot, gid, action, actor)
      if not relay_ok then error(relay_err, 0) end
      ensure_queue_table(schema, prefix)
      -- Capture whatever playlist is currently tracked as active for this
      -- guild+bot BEFORE wiping anything, so it can be resynced fresh
      -- afterward -- previously this just cleared state and claimed it
      -- "will repopulate automatically", which was never actually true for
      -- a guild with no other command in flight to trigger a re-resolve.
      local active_playlist = db.fetchone(schema, string.format(
        "SELECT playlist_url, requester_id, channel_id FROM %s_active_playlists WHERE guild_id = %%s AND bot_name = %%s", prefix
      ), gid, bot.key)
      db.execute(schema, string.format("DELETE FROM %s_queue WHERE guild_id = %%s AND bot_name = %%s", prefix), gid, bot.key)
      -- BUGFIX: this used to be a bare pcall with the result discarded --
      -- any failure (missing table, schema drift) silently left the backup
      -- queue untouched while reporting success. Surface it like every
      -- other previously-silent DB-write failure in this file already was.
      local backup_ok, backup_err = pcall(db.execute, schema, string.format("DELETE FROM %s_queue_backup WHERE guild_id = %%s AND bot_name = %%s", prefix), gid, bot.key)
      if not backup_ok then error("failed to clear backup queue: " .. tostring(backup_err), 0) end
      -- BUGFIX: "current playing" was never actually cleared -- only CLEAR's
      -- branch touched playback_state, RESET_QUEUE left the last-known
      -- title/position sitting there stale even though the queue backing it
      -- was gone.
      pcall(db.execute, schema, string.format(
        [[UPDATE %s_playback_state SET title = NULL, video_url = NULL, position_seconds = 0,
          is_playing = FALSE, is_paused = FALSE WHERE guild_id = %%s AND bot_name = %%s]], prefix
      ), gid, bot.key)

      if active_playlist and active_playlist.playlist_url and active_playlist.playlist_url ~= "" then
        local home_row = db.fetchone(schema, string.format(
          "SELECT home_vc_id FROM %s_bot_home_channels WHERE guild_id = %%s AND bot_name = %%s", prefix
        ), gid, bot.key)
        local voice_channel_id = channel_id_or_default((home_row and home_row.home_vc_id) or active_playlist.channel_id)
        local text_channel_id = channel_id_or_default(active_playlist.channel_id)
        insert_direct_order(schema, prefix, bot.key, gid, voice_channel_id, text_channel_id, "PLAY", active_playlist.playlist_url, actor)
        result.message = string.format(
          "Cleared the queue, backup queue, and current playback for guild %s on %s, and queued a fresh resync from its saved playlist.", gid, bot.display_name)
      else
        result.message = string.format(
          "Cleared the queue, backup queue, and current playback for guild %s on %s -- no saved playlist to resync from.", gid, bot.display_name)
      end

    elseif action == "LOOP" then
      local mode = tostring((type(payload) == "table" and payload.loop_mode) or payload or ""):lower()
      if not VALID_LOOP_MODES[mode] then error("Invalid loop mode: " .. mode, 0) end
      pcall(db.execute, schema, string.format("CREATE TABLE IF NOT EXISTS %s_guild_settings (guild_id BIGINT PRIMARY KEY)", prefix))
      db.execute(schema, string.format(
        [[INSERT INTO %s_guild_settings (guild_id, loop_mode) VALUES (%%s, %%s)
          ON CONFLICT (guild_id) DO UPDATE SET loop_mode = EXCLUDED.loop_mode]], prefix
      ), gid, mode)
      result.loop_mode = mode
      result.message = string.format("Loop mode set to %s for guild %s on %s.", mode, gid, bot.display_name)

    elseif action == "FILTER" then
      local mode = tostring((type(payload) == "table" and payload.filter_mode) or payload or ""):lower():gsub("%s+", "")
      if not VALID_FILTER_MODES[mode] then error("Invalid filter mode: " .. mode, 0) end
      pcall(db.execute, schema, string.format("CREATE TABLE IF NOT EXISTS %s_guild_settings (guild_id BIGINT PRIMARY KEY)", prefix))
      db.execute(schema, string.format(
        [[INSERT INTO %s_guild_settings (guild_id, filter_mode) VALUES (%%s, %%s)
          ON CONFLICT (guild_id) DO UPDATE SET filter_mode = EXCLUDED.filter_mode]], prefix
      ), gid, mode)
      set_override(schema, prefix, gid, bot.key, "UPDATE_FILTER", actor)
      result.filter_mode = mode
      result.message = string.format("Filter mode set to %s for guild %s on %s.", mode, gid, bot.display_name)

    elseif action == "SHUFFLE" then
      local relay_ok, relay_err = relay_to_command_thread(bot, gid, action, actor)
      if not relay_ok then error(relay_err, 0) end
      local shuffled = shuffle_live_queue(schema, prefix, gid, bot.key)
      result.queue_count = shuffled
      result.message = string.format("Shuffled %d queued tracks for guild %s on %s.", shuffled, gid, bot.display_name)

    elseif action == "SMART_RECOMMEND" then
      if type(payload) ~= "table" then error("SMART_RECOMMEND payload must be an object with voice_channel_id", 0) end
      clear_pending_orders(schema, prefix, gid, bot.key)
      local voice_channel_id = channel_id_or_default(payload.voice_channel_id)
      local text_channel_id = channel_id_or_default(payload.text_channel_id)
      local requester_id = payload.requester_id and tostring(payload.requester_id) or nil
      local shuffled = prime_panel_playback_defaults(schema, prefix, gid, bot.key)

      local seed, reason = nil, "server_favorite"
      if requester_id then
        seed = db.fetchone(
          schema,
          string.format(
            [[SELECT title, video_url, score FROM %s_user_track_affinity
              WHERE guild_id = %%s AND user_id = %%s AND dislike_count <= like_count
              ORDER BY score DESC, last_requested DESC LIMIT 1]], prefix
          ), gid, requester_id
        )
        if seed then reason = "personal_taste" end
      end
      if not seed then
        seed = db.fetchone(
          schema,
          string.format(
            [[SELECT title, video_url,
                     ((finish_count * 3) + (like_count * 5) + play_count - (skip_count * 2) - (dislike_count * 5)) AS smart_score
              FROM %s_track_intelligence WHERE guild_id = %%s AND dislike_count <= like_count
              ORDER BY smart_score DESC, updated_at DESC LIMIT 1]], prefix
          ), gid
        )
      end
      if not seed then error("No smart recommendation seed exists for this bot and guild yet", 0) end

      local seed_title = tostring(seed.title or seed.video_url or "")
      local query_text = "ytmsearch:" .. smart_query_from_title(seed_title) .. " radio"
      insert_direct_order(schema, prefix, bot.key, gid, voice_channel_id, text_channel_id, "PLAY", query_text, actor)
      pcall(db.execute, schema, string.format(
        [[CREATE TABLE IF NOT EXISTS %s_smart_recommendations (
            id SERIAL PRIMARY KEY, guild_id BIGINT NOT NULL, requester_id BIGINT DEFAULT NULL,
            seed_title TEXT, seed_url TEXT, query_text TEXT, chosen_url TEXT, chosen_title TEXT,
            reason VARCHAR(80), accepted BOOLEAN DEFAULT TRUE, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)]], prefix))
      db.execute(
        schema,
        string.format(
          [[INSERT INTO %s_smart_recommendations (guild_id, requester_id, seed_title, seed_url, query_text, reason)
            VALUES (%%s, %%s, %%s, %%s, %%s, %%s)]], prefix
        ), gid, requester_id, seed_title, seed.video_url, query_text, reason
      )
      result.seed_title = seed_title
      result.query_text = query_text
      result.reason = reason
      result.loop_mode = "queue"
      result.shuffled_queue_count = shuffled
      result.message = string.format("Queued a smart recommendation for %s in guild %s using %s.", bot.display_name, gid, seed_title:sub(1, 120))

    elseif action == "PLAY" then
      clear_pending_orders(schema, prefix, gid, bot.key)
      if type(payload) ~= "table" then error("PLAY payload must be an object with source_url and voice_channel_id", 0) end
      local source_url = tostring(payload.source_url or payload.query or ""):match("^%s*(.-)%s*$")
      if source_url == "" then error("Missing source_url for PLAY action", 0) end
      local voice_channel_id = channel_id_or_default(payload.voice_channel_id)
      local text_channel_id = channel_id_or_default(payload.text_channel_id)
      local shuffled = prime_panel_playback_defaults(schema, prefix, gid, bot.key)
      insert_direct_order(schema, prefix, bot.key, gid, voice_channel_id, text_channel_id, "PLAY", source_url, actor)
      result.loop_mode = "queue"
      result.shuffled_queue_count = shuffled
      result.message = string.format("Queued a direct PLAY order for %s in guild %s.", bot.display_name, gid)

    elseif action == "RECOVER" then
      local voice_channel_id = channel_id_or_default(type(payload) == "table" and (payload.voice_channel_id or payload.vc_id) or nil)
      insert_direct_order(schema, prefix, bot.key, gid, voice_channel_id, "0", "RECOVER", "panel", actor)
      result.message = string.format("Queued a direct RECOVER order for %s in guild %s.", bot.display_name, gid)

    elseif action == "LEAVE" then
      clear_pending_orders(schema, prefix, gid, bot.key)
      local force_leave = type(payload) == "table" and payload.force and true or false
      insert_direct_order(schema, prefix, bot.key, gid, "0", "0", "LEAVE", force_leave and "force" or "", actor)
      result.message = string.format("Queued a direct LEAVE order for %s in guild %s.", bot.display_name, gid)

    elseif action == "SET_HOME" then
      if type(payload) ~= "table" then error("SET_HOME payload must be an object with voice_channel_id", 0) end
      local voice_channel_id = tostring(payload.voice_channel_id or "")
      if voice_channel_id == "" then error("Missing voice_channel_id for SET_HOME action", 0) end
      ensure_home_table(schema, prefix)
      db.execute(
        schema,
        string.format(
          [[INSERT INTO %s_bot_home_channels (guild_id, bot_name, home_vc_id) VALUES (%%s, %%s, %%s)
            ON CONFLICT (guild_id, bot_name) DO UPDATE SET home_vc_id = EXCLUDED.home_vc_id]], prefix
        ), gid, bot.key, voice_channel_id
      )
      result.voice_channel_id = voice_channel_id
      result.message = string.format("Set home channel for %s in guild %s.", bot.display_name, gid)

    elseif action == "SEEK" then
      if type(payload) ~= "table" then error("SEEK payload must be an object with position_seconds", 0) end
      local position_seconds = math.max(0, tonumber(payload.position_seconds) or 0)
      ensure_direct_orders_table(schema, prefix)
      db.execute(schema, string.format("DELETE FROM %s_swarm_direct_orders WHERE guild_id = %%s AND bot_name = %%s AND command = 'SEEK'", prefix), gid, bot.key)
      insert_direct_order(schema, prefix, bot.key, gid, "0", "0", "SEEK", tostring(math.floor(position_seconds)), actor)
      result.position_seconds = math.floor(position_seconds)
      result.message = string.format("Seek order queued for %s in guild %s at position %ds.", bot.display_name, gid, math.floor(position_seconds))
    end

    db.execute(schema, "COMMIT")
  end)

  if not ok then
    pcall(db.execute, schema, "ROLLBACK")
    return nil, tostring(err)
  end
  return result, nil
end

return M
