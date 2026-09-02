-- Guild-wide voice<->stage channel conversion (per operator request: two
-- buttons on the Controls page letting a guild's owner convert every
-- home-channel-connected bot's channel to a stage channel, and back).
--
-- The music bots themselves already fully support playing FROM a stage
-- channel (auto-unsuppress on join, request-to-speak fallback, stage-
-- instance topic management -- see lib/swarmlua/bot.lua's VOICE_STATE_UPDATE
-- handler and each bot's update_stage_topic/get_channel_kind). What this
-- module does is exactly the missing piece: the actual channel conversion.
--
-- BUGFIX 2026-09-02 (confirmed live): a straight PATCH channel-type change
-- doesn't work at all -- Discord rejects GUILD_VOICE<->GUILD_STAGE_VOICE
-- unconditionally with CHANNEL_TYPE_CHANGE_INVALID (confirmed against both
-- a real home channel and a disposable empty test channel, ruling out
-- permissions/active-connection as the cause). See discord_service.lua's
-- M.recreate_channel_as_type for the only approach Discord's API actually
-- supports (delete + recreate) and its real costs (new channel id, lost
-- in-channel chat history, a brief disconnect for whoever's connected).
-- Given the channel id changes, this module ALSO updates every affected
-- bot's home_vc_id afterward and re-issues RECOVER so they rejoin the new
-- channel promptly instead of waiting for the next periodic backstop.
local db = require("db")
local discord_service = require("discord_service")
local control = require("control")

local M = {}

local function ensure_home_table(schema, prefix)
  pcall(db.execute, schema, string.format(
    [[CREATE TABLE IF NOT EXISTS %s_bot_home_channels (
        guild_id BIGINT, bot_name VARCHAR(50), home_vc_id BIGINT,
        PRIMARY KEY (guild_id, bot_name))]], prefix))
end

-- direction: "stage" or "voice". Returns a result table:
--   { converted = [{old_channel_id, new_channel_id, bots = [key,...], warning}, ...],
--     failed = [{channel_id, bots = [key,...], error}, ...],
--     skipped_no_home_channel = <count of bots with no home channel set> }
function M.convert_guild_channels(cfg, guild_id, direction)
  local channel_type = direction == "stage" and discord_service.CHANNEL_TYPE_STAGE or discord_service.CHANNEL_TYPE_VOICE
  if direction ~= "stage" and direction ~= "voice" then
    error("direction must be 'stage' or 'voice', got: " .. tostring(direction), 0)
  end

  -- Distinct channel_id -> { bots = {bot_table, ...}, token = <first bot's
  -- own token, guaranteed present in this guild since it's THAT bot's own
  -- home channel> }. Keyed by channel so two bots sharing one home channel
  -- (unusual but not disallowed) only get ONE conversion, not one per bot.
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
          entry = { bots = {}, token = cfg.bot_tokens[bot.key] }
          by_channel[channel_id] = entry
        end
        table.insert(entry.bots, bot)
      end
    end
  end

  local converted, failed = {}, {}
  for channel_id, entry in pairs(by_channel) do
    local bot_keys = {}
    for _, bot in ipairs(entry.bots) do table.insert(bot_keys, bot.key) end

    if not entry.token or entry.token == "" then
      table.insert(failed, { channel_id = channel_id, bots = bot_keys, error = "No Discord token configured for this bot" })
    else
      local ok, new_channel_id, err_or_warning = discord_service.recreate_channel_as_type(entry.token, channel_id, channel_type)
      if not ok then
        table.insert(failed, { channel_id = channel_id, bots = bot_keys, error = tostring(err_or_warning) })
      else
        -- Point every affected bot's home channel at the new id, then
        -- re-issue RECOVER so they rejoin promptly (the swap disconnected
        -- them, same as any channel deletion would) instead of sitting
        -- disconnected until Aria's next periodic home-channel backstop
        -- (up to ~10 minutes, see aria's ensure_home_channels).
        for _, bot in ipairs(entry.bots) do
          pcall(db.execute, bot.db_schema, string.format(
            "UPDATE %s_bot_home_channels SET home_vc_id = %%s WHERE guild_id = %%s AND bot_name = %%s", bot.table_prefix
          ), new_channel_id, guild_id, bot.key)
          pcall(control.control_bot, bot, guild_id, "RECOVER", { voice_channel_id = new_channel_id }, "channel_convert")
        end
        table.insert(converted, {
          old_channel_id = channel_id, new_channel_id = new_channel_id,
          bots = bot_keys, warning = err_or_warning,
        })
      end
    end
  end

  return { converted = converted, failed = failed, skipped_no_home_channel = skipped }
end

return M
