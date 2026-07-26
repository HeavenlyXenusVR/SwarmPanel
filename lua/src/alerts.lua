-- Configurable alert rules, port of app/db/alerts.py against
-- accountlogins.swarm_alert_rules (confirmed live via \d).
local db = require("db")

local M = {}
local SCHEMA = "accountlogins"
local TABLE = "swarm_alert_rules"
local VALID_RULE_TYPES = { bot_offline = true, queue_stuck = true, stale_metrics = true, recovery_pending = true }
M.VALID_RULE_TYPES = VALID_RULE_TYPES

local SELECT_COLUMNS = "id, rule_type, threshold_minutes, enabled, escalation_minutes, escalate_email, created_at"

local function row_out(row)
  if not row then return nil end
  local out = {}
  for k, v in pairs(row) do out[k] = v end
  out.enabled = db.tobool(out.enabled)
  out.escalate_email = db.tobool(out.escalate_email)
  if out.threshold_minutes ~= nil then out.threshold_minutes = db.toint(out.threshold_minutes) end
  if out.escalation_minutes ~= nil then out.escalation_minutes = db.toint(out.escalation_minutes) end
  return out
end

function M.list_alert_rules()
  local rows = db.fetchall(SCHEMA, "SELECT " .. SELECT_COLUMNS .. " FROM " .. TABLE .. " ORDER BY created_at DESC, id DESC")
  local out = {}
  for _, row in ipairs(rows) do out[#out + 1] = row_out(row) end
  return out
end

function M.get_alert_rule(rule_id)
  return row_out(db.fetchone(SCHEMA, "SELECT " .. SELECT_COLUMNS .. " FROM " .. TABLE .. " WHERE id = %s", tostring(rule_id)))
end

function M.create_alert_rule(rule_type, threshold_minutes, enabled, escalation_minutes, escalate_email)
  rule_type = tostring(rule_type or ""):lower():match("^%s*(.-)%s*$")
  if not VALID_RULE_TYPES[rule_type] then
    local names = {}
    for k in pairs(VALID_RULE_TYPES) do names[#names + 1] = k end
    table.sort(names)
    error("Unsupported rule_type: '" .. rule_type .. "'. Expected one of: " .. table.concat(names, ", "), 0)
  end
  local threshold = math.max(1, math.min(tonumber(threshold_minutes) or 5, 1440))
  local safe_escalation = (escalation_minutes and tonumber(escalation_minutes) and tonumber(escalation_minutes) > 0)
    and math.max(1, math.min(tonumber(escalation_minutes), 10080)) or nil
  db.execute(
    SCHEMA,
    -- created_at set explicitly — see the schema-defaults note in
    -- social.lua's set_account_follow().
    [[INSERT INTO ]] .. TABLE .. [[ (rule_type, threshold_minutes, enabled, escalation_minutes, escalate_email, created_at)
      VALUES (%s, %s, %s, %s, %s, CURRENT_TIMESTAMP)]],
    rule_type, threshold, enabled and true or false, safe_escalation, escalate_email and true or false
  )
  return row_out(db.fetchone(SCHEMA, "SELECT " .. SELECT_COLUMNS .. " FROM " .. TABLE .. " ORDER BY id DESC LIMIT 1")) or {}
end

local ALLOWED_UPDATE_FIELDS = { rule_type = true, threshold_minutes = true, enabled = true, escalation_minutes = true, escalate_email = true }

function M.update_alert_rule(rule_id, updates)
  updates = updates or {}
  local unknown = {}
  for key in pairs(updates) do
    if not ALLOWED_UPDATE_FIELDS[key] then unknown[#unknown + 1] = key end
  end
  if #unknown > 0 then
    table.sort(unknown)
    error("Unsupported alert rule fields: " .. table.concat(unknown, ", "), 0)
  end

  local cleaned, assignments, values = {}, {}, {}
  if updates.rule_type ~= nil then
    local rule_type = tostring(updates.rule_type or ""):lower():match("^%s*(.-)%s*$")
    if not VALID_RULE_TYPES[rule_type] then error("Unsupported rule_type: '" .. rule_type .. "'", 0) end
    cleaned.rule_type = rule_type
  end
  if updates.threshold_minutes ~= nil then
    cleaned.threshold_minutes = math.max(1, math.min(tonumber(updates.threshold_minutes) or 5, 1440))
  end
  if updates.enabled ~= nil then cleaned.enabled = updates.enabled and true or false end
  if updates.escalation_minutes ~= nil then
    local v = updates.escalation_minutes
    cleaned.escalation_minutes = (v and tonumber(v) and tonumber(v) > 0) and math.max(1, math.min(tonumber(v), 10080)) or false -- false = "set to NULL" sentinel
  end
  if updates.escalate_email ~= nil then cleaned.escalate_email = updates.escalate_email and true or false end

  for key, value in pairs(cleaned) do
    if key == "escalation_minutes" and value == false then
      assignments[#assignments + 1] = "escalation_minutes = NULL"
    else
      assignments[#assignments + 1] = key .. " = %s"
      values[#values + 1] = value
    end
  end
  if #assignments > 0 then
    values[#values + 1] = tostring(rule_id)
    db.execute(SCHEMA, "UPDATE " .. TABLE .. " SET " .. table.concat(assignments, ", ") .. " WHERE id = %s", unpack(values))
  end
  return row_out(db.fetchone(SCHEMA, "SELECT " .. SELECT_COLUMNS .. " FROM " .. TABLE .. " WHERE id = %s", tostring(rule_id)))
end

function M.delete_alert_rule(rule_id)
  db.execute(SCHEMA, "DELETE FROM " .. TABLE .. " WHERE id = %s", tostring(rule_id))
end

function M.list_enabled_alert_rules()
  local ok, rows = pcall(db.fetchall, SCHEMA, "SELECT " .. SELECT_COLUMNS .. " FROM " .. TABLE .. " WHERE enabled = TRUE")
  if not ok then return {} end
  local out = {}
  for _, row in ipairs(rows) do out[#out + 1] = row_out(row) end
  return out
end

return M
