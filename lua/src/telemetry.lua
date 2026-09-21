-- SwarmPanel-wide sanitized telemetry/analytics recorder. Writes into the
-- shared accountlogins database (same database swarm_audit_log and panel
-- accounts already live in -- Postgres can't cross-database JOIN here, see
-- db.lua's own header, so keeping this alongside the data it's *about* is
-- what makes it queryable without gymnastics).
--
-- Distinct from metrics.lua's swarm_metrics_history: that table tracks the
-- BOT FLEET's health (queue depth, node uptime, etc, sampled from each
-- bot's own database). This module tracks the PANEL ITSELF: who's using it,
-- which routes/actions run, how long they take, and what errors happen.
--
-- Secrets guarantee: this module is handed only already-derived operational
-- data by callers (HTTP method/path/status, usernames, guild ids,
-- durations, human-readable audit text) -- it never touches the session
-- secret, DB passwords, or bot tokens directly, and no call site in this
-- app passes an env var or credential into it. httpd.lua's request logger
-- only ever forwards method/path/status/latency/client_ip; routes.lua only
-- ever passes the already-authenticated username, never the bearer token or
-- session cookie value itself. As a defense-in-depth backstop against a
-- caller passing something sensitive through a free-text/metadata field
-- anyway:
--   - any metadata table key whose name looks like a credential (token,
--     password, secret, authorization, api_key, cookie, ...) is DROPPED
--     entirely, not redacted-in-place, so a mistakenly-passed
--     {token = "..."} never reaches the query at all;
--   - every string value (free text and metadata strings alike) is scanned
--     for Bearer-header/token-shaped substrings and redacted before being
--     stored.
local db = require("db")
local cjson = require("cjson.safe")

local M = {}
local DB = "accountlogins"
local EVENTS_TABLE = "swarmpanel_telemetry_events"
local STATS_TABLE = "swarmpanel_process_stats"

local MAX_TEXT_LEN = 500
local MAX_METADATA_JSON_LEN = 4000
local MAX_DEPTH = 4

local SECRET_KEY_FRAGMENTS = {
  "token", "password", "passwd", "secret", "authorization", "api_key",
  "apikey", "cookie", "credential", "access_key", "private_key",
  "client_secret", "webhook", "dsn", "auth",
}

local function is_secret_key(k)
  local lk = tostring(k):lower()
  for _, frag in ipairs(SECRET_KEY_FRAGMENTS) do
    if lk:find(frag, 1, true) then return true end
  end
  return false
end

-- Redacts anything shaped like a Bearer/session token (three dot-separated
-- segments in real-token length ranges, same defense used fleet-wide for
-- the Discord bots' own telemetry module -- narrow enough not to mangle
-- ordinary text) or a raw "Bearer <token>" header, then truncates.
local function redact_text(s)
  if type(s) ~= "string" then return s end
  s = s:gsub("([%w_%-]+)%.([%w_%-]+)%.([%w_%-]+)", function(a, b, c)
    if #a >= 15 and #a <= 60 and #b >= 4 and #b <= 20 and #c >= 20 and #c <= 80 then
      return "[redacted-token-shaped]"
    end
    return a .. "." .. b .. "." .. c
  end)
  s = s:gsub("[Bb]earer%s+%S+", "Bearer [redacted]")
  if #s > MAX_TEXT_LEN then s = s:sub(1, MAX_TEXT_LEN) .. "...[truncated]" end
  return s
end

local function sanitize_value(v, depth)
  local t = type(v)
  if t == "string" then return redact_text(v)
  elseif t == "number" or t == "boolean" then return v
  elseif t == "table" then
    if depth >= MAX_DEPTH then return nil end
    local out = {}
    for k, val in pairs(v) do
      if not is_secret_key(k) then
        local sv = sanitize_value(val, depth + 1)
        if sv ~= nil then out[k] = sv end
      end
    end
    return out
  else
    return nil -- functions/userdata/etc never serialized
  end
end

function M.init()
  db.execute(DB, [[CREATE TABLE IF NOT EXISTS ]] .. EVENTS_TABLE .. [[ (
    id BIGSERIAL PRIMARY KEY,
    event_category VARCHAR(40) NOT NULL,
    event_name VARCHAR(120) NOT NULL,
    method VARCHAR(10),
    path VARCHAR(200),
    status_code INTEGER,
    username VARCHAR(80),
    guild_id BIGINT,
    client_ip VARCHAR(64),
    numeric_value DOUBLE PRECISION,
    text_value TEXT,
    metadata JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
  )]])
  db.execute(DB, "CREATE INDEX IF NOT EXISTS swarmpanel_telemetry_events_category_idx ON " .. EVENTS_TABLE .. " (event_category, event_name, created_at)")
  db.execute(DB, "CREATE INDEX IF NOT EXISTS swarmpanel_telemetry_events_created_idx ON " .. EVENTS_TABLE .. " (created_at)")
  db.execute(DB, "CREATE INDEX IF NOT EXISTS swarmpanel_telemetry_events_username_idx ON " .. EVENTS_TABLE .. " (username, created_at)")
  db.execute(DB, "CREATE INDEX IF NOT EXISTS swarmpanel_telemetry_events_path_idx ON " .. EVENTS_TABLE .. " (path, created_at)")
  db.execute(DB, [[CREATE TABLE IF NOT EXISTS ]] .. STATS_TABLE .. [[ (
    id INTEGER PRIMARY KEY DEFAULT 1,
    memory_kb BIGINT,
    uptime_seconds BIGINT,
    active_websocket_count INTEGER,
    requests_last_interval INTEGER,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
  )]])
end

-- record(category, name, opts) -- opts: { method, path, status_code,
-- username, guild_id, client_ip, numeric_value, text_value, metadata }.
-- Fire-and-forget: never throws, a DB hiccup here must never take down
-- whatever real request/action triggered the telemetry.
function M.record(category, name, opts)
  opts = opts or {}
  local text_value = opts.text_value ~= nil and redact_text(tostring(opts.text_value)) or nil
  local metadata_json = nil
  if opts.metadata ~= nil then
    local sanitized = sanitize_value(opts.metadata, 0)
    local ok, encoded = pcall(cjson.encode, sanitized)
    if ok and encoded and #encoded <= MAX_METADATA_JSON_LEN then
      metadata_json = encoded
    end
  end
  local ok2, err = pcall(db.execute, DB,
    ("INSERT INTO %s (event_category, event_name, method, path, status_code, username, guild_id, client_ip, numeric_value, text_value, metadata) " ..
     "VALUES (%%s, %%s, %%s, %%s, %%s, %%s, %%s, %%s, %%s, %%s, %%s::jsonb)"):format(EVENTS_TABLE),
    tostring(category), tostring(name), opts.method, opts.path and tostring(opts.path):sub(1, 200),
    opts.status_code, opts.username and tostring(opts.username):sub(1, 80), opts.guild_id,
    opts.client_ip and tostring(opts.client_ip):sub(1, 64), opts.numeric_value, text_value, metadata_json)
  if not ok2 then
    print("[swarmpanel-lua] telemetry record failed: " .. tostring(err))
  end
end

-- snapshot(opts) -- periodic process resource/activity snapshot, one
-- singleton row (id=1, upserted -- swarmpanel_telemetry_events above is the
-- append-only history; this is current-state).
function M.snapshot(opts)
  opts = opts or {}
  local ok, err = pcall(db.execute, DB,
    ([[INSERT INTO %s (id, memory_kb, uptime_seconds, active_websocket_count, requests_last_interval, updated_at)
       VALUES (1, %%s, %%s, %%s, %%s, now())
       ON CONFLICT (id) DO UPDATE SET memory_kb = EXCLUDED.memory_kb, uptime_seconds = EXCLUDED.uptime_seconds,
         active_websocket_count = EXCLUDED.active_websocket_count, requests_last_interval = EXCLUDED.requests_last_interval,
         updated_at = now()]]):format(STATS_TABLE),
    opts.memory_kb, opts.uptime_seconds, opts.active_websocket_count, opts.requests_last_interval)
  if not ok then print("[swarmpanel-lua] telemetry snapshot failed: " .. tostring(err)) end
end

-- Bounded, low-frequency retention sweep -- call from a periodic tick with
-- low probability so the DELETE stays spread out rather than firing every
-- tick. Keeps swarmpanel_telemetry_events from growing unbounded.
function M.maybe_cleanup(retention_days, probability_denominator)
  if math.random(1, probability_denominator or 200) ~= 1 then return end
  pcall(db.execute, DB, ("DELETE FROM %s WHERE created_at < now() - interval '%s days'"):format(EVENTS_TABLE, tonumber(retention_days) or 30))
end

-- Lightweight in-process request counter (active websocket count and
-- requests-per-interval, both reset on read) -- httpd.lua bumps these on
-- every request/ws connect, the periodic snapshot loop in main.lua reads
-- and resets the request counter each tick.
local request_count = 0
local ws_active_count = 0

function M.count_request()
  request_count = request_count + 1
end

function M.pop_request_count()
  local n = request_count
  request_count = 0
  return n
end

function M.ws_connected()
  ws_active_count = ws_active_count + 1
end

function M.ws_disconnected()
  ws_active_count = math.max(0, ws_active_count - 1)
end

function M.active_websocket_count()
  return ws_active_count
end

return M
