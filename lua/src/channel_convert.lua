-- Guild-wide voice<->stage channel conversion (per operator request: two
-- buttons on the Controls page letting a guild's owner convert every
-- home-channel-connected bot's channel to a stage channel, and back).
--
-- The music bots themselves already fully support playing FROM a stage
-- channel (auto-unsuppress on join, request-to-speak fallback, stage-
-- instance topic management -- see lib/swarmlua/bot.lua's VOICE_STATE_UPDATE
-- handler and each bot's update_stage_topic/get_channel_kind). What's
-- missing is the actual channel-TYPE conversion action itself -- this
-- module is exactly that, nothing more: it doesn't touch playback, voice
-- connections, or bot state at all, just the underlying Discord channel
-- object each bot's home_vc_id already points at.
local db = require("db")
local discord_service = require("discord_service")

local M = {}

local function ensure_home_table(schema, prefix)
  pcall(db.execute, schema, string.format(
    [[CREATE TABLE IF NOT EXISTS %s_bot_home_channels (
        guild_id BIGINT, bot_name VARCHAR(50), home_vc_id BIGINT,
        PRIMARY KEY (guild_id, bot_name))]], prefix))
end

-- direction: "stage" or "voice". Returns a result table:
--   { converted = [{channel_id, channel_name_hint, bots = [key,...]}, ...],
--     failed = [{channel_id, bots = [key,...], error}, ...],
--     skipped_no_home_channel = <count of bots with no home channel set> }
function M.convert_guild_channels(cfg, guild_id, direction)
  local channel_type = direction == "stage" and discord_service.CHANNEL_TYPE_STAGE or discord_service.CHANNEL_TYPE_VOICE
  if direction ~= "stage" and direction ~= "voice" then
    error("direction must be 'stage' or 'voice', got: " .. tostring(direction), 0)
  end

  -- Distinct channel_id -> { bot_keys = {key, ...}, token = <first bot's
  -- own token, guaranteed present in this guild since it's THAT bot's own
  -- home channel> }. Keyed by channel so two bots sharing one home channel
  -- (unusual but not disallowed) only get ONE PATCH, not one per bot.
  local by_channel = {}
  local skipped = 0

  for _, bot in ipairs(cfg.music_bots) do
    if bot.kind == "music" then
      ensure_home_table(bot.db_schema, bot.table_prefix)
      local row = db.fetchone(bot.db_schema, string.format(
        "SELECT home_vc_id FROM %s_bot_home_channels WHERE guild_id = %%s AND bot_name = %%s", bot.table_prefix
      ), guild_id, bot.key)
      local channel_id = row and row.home_vc_id and tostring(row.home_vc_id)
      if not channel_id or channel_id == "" or channel_id == "0" then
        skipped = skipped + 1
      else
        local entry = by_channel[channel_id]
        if not entry then
          entry = { bot_keys = {}, token = cfg.bot_tokens[bot.key] }
          by_channel[channel_id] = entry
        end
        table.insert(entry.bot_keys, bot.key)
      end
    end
  end

  local converted, failed = {}, {}
  for channel_id, entry in pairs(by_channel) do
    if not entry.token or entry.token == "" then
      table.insert(failed, { channel_id = channel_id, bots = entry.bot_keys, error = "No Discord token configured for this bot" })
    else
      local ok, err = discord_service.set_channel_type(entry.token, channel_id, channel_type)
      if ok then
        table.insert(converted, { channel_id = channel_id, bots = entry.bot_keys })
      else
        table.insert(failed, { channel_id = channel_id, bots = entry.bot_keys, error = tostring(err) })
      end
    end
  end

  return { converted = converted, failed = failed, skipped_no_home_channel = skipped }
end

return M
