-- Saved queues/playlists: guild-scoped CRUD over accountlogins.swarm_saved_queues.
-- Port of app/db/queues.py.
local db = require("db")
local cjson = require("cjson.safe")

local M = {}
local SCHEMA = "accountlogins"
local TABLE = "swarm_saved_queues"
local MAX_SAVED_QUEUE_ITEMS = 200

local function row_out(row)
  if not row then return nil end
  local out = {}
  for k, v in pairs(row) do out[k] = v end
  if out.guild_id ~= nil then out.guild_id = tostring(out.guild_id) end
  if type(out.items) == "string" then
    local ok, decoded = pcall(cjson.decode, out.items)
    out.items = (ok and type(decoded) == "table") and decoded or {}
  elseif type(out.items) ~= "table" then
    out.items = {}
  end
  return out
end

function M.list_saved_queues(guild_id, bot_key)
  local where, params = "WHERE guild_id = %s", { tostring(guild_id) }
  if bot_key and tostring(bot_key) ~= "" then
    where = where .. " AND bot_key = %s"
    params[#params + 1] = tostring(bot_key):lower():match("^%s*(.-)%s*$")
  end
  local sql = string.format(
    "SELECT id, guild_id, bot_key, name, created_by_username, items, created_at FROM %s %s ORDER BY created_at DESC, id DESC",
    TABLE, where
  )
  local rows = db.fetchall(SCHEMA, sql, unpack(params))
  local out = {}
  for _, row in ipairs(rows) do out[#out + 1] = row_out(row) end
  return out
end

function M.create_saved_queue(guild_id, bot_key, name, created_by, items)
  local safe_name = tostring(name or ""):match("^%s*(.-)%s*$"):sub(1, 120)
  if safe_name == "" then safe_name = "Saved Queue" end
  local safe_items = {}
  for _, item in ipairs(items or {}) do
    local video_url = tostring((item or {}).video_url or ""):match("^%s*(.-)%s*$")
    if video_url ~= "" then
      local title = tostring((item or {}).title or ""):sub(1, 400)
      safe_items[#safe_items + 1] = {
        title = (title ~= "") and title or nil,
        video_url = video_url:sub(1, 1000),
        requester_id = item.requester_id and tostring(item.requester_id) or nil,
      }
      if #safe_items >= MAX_SAVED_QUEUE_ITEMS then break end
    end
  end
  if #safe_items == 0 then error("A saved queue needs at least one track with a video_url.", 0) end

  db.execute(
    SCHEMA,
    -- created_at set explicitly — see the schema-defaults note in
    -- social.lua's set_account_follow().
    [[INSERT INTO ]] .. TABLE .. [[ (guild_id, bot_key, name, created_by_username, items, created_at)
      VALUES (%s, %s, %s, %s, %s, CURRENT_TIMESTAMP)]],
    tostring(guild_id), tostring(bot_key):lower():match("^%s*(.-)%s*$"), safe_name,
    tostring(created_by or "unknown"):sub(1, 80), cjson.encode(safe_items)
  )
  local row = db.fetchone(SCHEMA, "SELECT id, guild_id, bot_key, name, created_by_username, items, created_at FROM " .. TABLE .. " ORDER BY id DESC LIMIT 1")
  return row_out(row) or {}
end

function M.delete_saved_queue(queue_id, guild_id)
  db.execute(SCHEMA, "DELETE FROM " .. TABLE .. " WHERE id = %s AND guild_id = %s", tostring(queue_id), tostring(guild_id))
end

return M
