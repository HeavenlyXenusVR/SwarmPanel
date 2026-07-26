-- Panel-wide admin audit log. Port of app/db/audit.py against the
-- already-migrated Postgres accountlogins.swarm_audit_log table (columns
-- confirmed live via \d: id, actor_username, actor_user_id, action,
-- target_type, target_id, details, created_at).
local db = require("db")
local cjson = require("cjson.safe")

local M = {}
local SCHEMA = "accountlogins"
local TABLE = "swarm_audit_log"

local DIFF_IGNORED_KEYS = { updated_at = true, is_online = true, last_seen_at = true }

-- Structured before/after JSON for update-type audit entries, limited to
-- keys that actually changed. Returns "" (caller omits details) if nothing
-- of interest changed.
-- Table-valued columns (panel_preferences/profile_tags/profile_links, all
-- decoded from JSON text) come back as fresh Lua tables on every DB
-- round-trip, so a plain `~=` would flag them as "changed" even when their
-- content is identical. Compare those by their JSON encoding instead.
local function values_equal(a, b)
  if a == b then return true end
  if type(a) == "table" and type(b) == "table" then
    local ok_a, enc_a = pcall(cjson.encode, a)
    local ok_b, enc_b = pcall(cjson.encode, b)
    return ok_a and ok_b and enc_a == enc_b
  end
  return false
end

function M.diff_details(before, after)
  local changed_before, changed_after, any = {}, {}, false
  for key, new_value in pairs(after or {}) do
    if not DIFF_IGNORED_KEYS[key] then
      local old_value = (before or {})[key]
      if not values_equal(old_value, new_value) then
        changed_before[key] = old_value
        changed_after[key] = new_value
        any = true
      end
    end
  end
  if not any then return "" end
  return cjson.encode({ before = changed_before, after = changed_after })
end

-- Best-effort: must never raise into the caller's destructive action.
function M.record_audit_log(actor, action, opts)
  opts = opts or {}
  pcall(db.execute,
    SCHEMA,
    -- created_at set explicitly: this schema's DEFAULT CURRENT_TIMESTAMP was
    -- lost in migration — see the note in social.lua's set_account_follow().
    [[INSERT INTO ]] .. TABLE .. [[ (actor_username, actor_user_id, action, target_type, target_id, details, created_at)
      VALUES (%s, %s, %s, %s, %s, %s, CURRENT_TIMESTAMP)]],
    tostring(actor or "unknown"):sub(1, 80),
    (opts.actor_user_id ~= nil and opts.actor_user_id ~= "") and tostring(opts.actor_user_id) or nil,
    tostring(action or ""):sub(1, 80),
    opts.target_type and tostring(opts.target_type):sub(1, 40) or nil,
    (opts.target_id ~= nil and opts.target_id ~= "") and tostring(opts.target_id):sub(1, 80) or nil,
    opts.details and tostring(opts.details):sub(1, 4000) or nil
  )
end

function M.list_audit_log(limit, offset, action_filter)
  local safe_limit = math.max(1, math.min(tonumber(limit) or 100, 500))
  local safe_offset = math.max(0, tonumber(offset) or 0)
  local where, params = "", {}
  if action_filter and action_filter ~= "" then
    where = "WHERE action = %s"
    params[1] = tostring(action_filter):sub(1, 80)
  end
  params[#params + 1] = safe_limit
  params[#params + 1] = safe_offset
  local rows = db.fetchall(
    SCHEMA,
    string.format(
      [[SELECT id, actor_username, actor_user_id, action, target_type, target_id, details, created_at
        FROM %s %s ORDER BY created_at DESC, id DESC LIMIT %%s OFFSET %%s]],
      TABLE, where
    ),
    unpack(params)
  )
  local count_params = {}
  if action_filter and action_filter ~= "" then count_params[1] = tostring(action_filter):sub(1, 80) end
  local total_row = db.fetchone(SCHEMA, string.format("SELECT COUNT(*) AS count FROM %s %s", TABLE, where), unpack(count_params))
  return { entries = rows, total = db.toint(total_row and total_row.count, 0) }
end

function M.get_audit_log_entry(entry_id)
  return db.fetchone(SCHEMA, "SELECT id, actor_username, actor_user_id, action, target_type, target_id, details, created_at FROM " .. TABLE .. " WHERE id = %s LIMIT 1", tostring(entry_id))
end

return M
