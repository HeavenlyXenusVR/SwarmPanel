-- Postgres access layer built on the vendored swarmlua/pg.lua.
--
-- IMPORTANT difference from the old MariaDB backend: MariaDB let one
-- connection do cross-database queries (`FROM db_a.tbl JOIN db_b.tbl`).
-- Postgres does not — a connection is bound to one database for its
-- lifetime. None of SwarmPanel's queries actually JOIN across two different
-- top-level databases (accountlogins / discord_aria / each bot's own
-- discord_music_<bot> db are always queried independently, then combined in
-- application code), so the fix is simply: keep one lazily-connected Pg
-- instance PER DATABASE NAME instead of one pool for the whole server.
local Pg = require("swarmlua.pg")
local socket = require("socket")

local M = {}
local pools = {} -- dbname -> Pg instance
local cfg = nil

function M.init(settings)
  cfg = settings
end

function M.conn(dbname)
  local pg = pools[dbname]
  if not pg then
    pg = Pg.new({
      host = cfg.db_host,
      port = cfg.db_port,
      user = cfg.db_user,
      password = cfg.db_password,
      database = dbname,
    })
    pools[dbname] = pg
  end
  return pg
end

-- pgmoon's default OID 1700 (NUMERIC) deserializer runs every value through
-- tonumber() same as its OID 20 (int8/bigint) one — pg.lua already patches
-- bigint (see pg.lua's own comment on that), but NOT numeric, and the
-- image_gallery schema stores several large id-ish columns (user_id,
-- media_id, avatar_file_id, banned_by, file_size, ...) as NUMERIC(20,0),
-- which is exactly the >2^53 precision-loss trap the swarm-wide snowflake
-- rule warns about. Patched here at the call site instead of editing the
-- vendored pg.lua: force NUMERIC to come back as a string too, on every
-- connection (including after an auto-reconnect, since pgmoon.new() resets
-- deserializers on each fresh socket) — cheap to re-check per query via a
-- one-field marker on the live connection object.
local function ensure_numeric_precision(pg)
  local ok = pg:ensure()
  if ok and pg.conn and not pg.conn._swarmpanel_numeric_fixed then
    pg.conn:set_type_deserializer(1700, "string")
    pg.conn._swarmpanel_numeric_fixed = true
  end
  return ok
end

-- Runs `sql` (with %s-style placeholders, pgmoon-escaped) against `dbname`.
-- Returns rows (array of column->value tables) or nil, err.
function M.query(dbname, sql, ...)
  local pg = M.conn(dbname)
  ensure_numeric_precision(pg)
  local rows, err = pg:query(sql, ...)
  if rows == nil then
    return nil, err
  end
  if rows == true then return {} end -- DDL/DML with no result set
  return rows
end

function M.fetchall(dbname, sql, ...)
  local rows, err = M.query(dbname, sql, ...)
  return rows or {}, err
end

function M.fetchone(dbname, sql, ...)
  local rows, err = M.query(dbname, sql, ...)
  if not rows or not rows[1] then return nil, err end
  return rows[1], nil
end

function M.execute(dbname, sql, ...)
  local rows, err = M.query(dbname, sql, ...)
  if rows == nil then return nil, err end
  return true
end

-- Coerces a value that may have come back as a Lua string (bigint/count
-- columns are forced to string in pg.lua to preserve snowflake precision)
-- into a Lua number. Safe to call on values that are already numbers.
function M.toint(v, default)
  if v == nil then return default end
  if type(v) == "number" then return math.floor(v) end
  local n = tonumber(v)
  if n == nil then return default end
  return math.floor(n)
end

function M.tobool(v)
  if type(v) == "boolean" then return v end
  if v == nil then return false end
  if v == "t" or v == "true" or v == "1" or v == 1 then return true end
  return false
end

local table_exists_cache = {} -- "db\0table" -> {expires_monotonic, bool}
local TABLE_EXISTS_TTL = 60

function M.table_exists(dbname, table_name)
  local key = dbname .. "\0" .. table_name
  local cached = table_exists_cache[key]
  -- BUGFIX 2026-08-22: os.clock() is CPU time, not wall-clock -- meaningless
  -- as a cache-expiry clock for a mostly-idle, I/O-bound web server process
  -- (same root cause as Music/lua-shared/swarmlua/lavalink.lua's identical
  -- BUGFIX for its REST-latency metric). CPU time accrues far slower than
  -- real time here, so this cache's "60 second" TTL could in practice take
  -- far longer than 60 real seconds to actually expire -- e.g. a bot's
  -- schema/table created for the first time (like Dazzle's, added this
  -- session) could keep reporting "does not exist" on the dashboard for
  -- much longer than intended after it actually starts existing.
  -- socket.gettime() is real wall-clock time.
  local now = socket.gettime()
  if cached and cached[1] > now then return cached[2] end
  local row = M.fetchone(
    dbname,
    "SELECT 1 AS present FROM information_schema.tables WHERE table_schema='public' AND table_name=%s LIMIT 1",
    table_name
  )
  local exists = row ~= nil
  table_exists_cache[key] = { now + TABLE_EXISTS_TTL, exists }
  return exists
end

-- Batch existence check: one query, returns a set {table_name=true,...}.
function M.batch_table_exists(dbname, table_names)
  if #table_names == 0 then return {} end
  local placeholders = {}
  for i, name in ipairs(table_names) do placeholders[i] = name end
  -- Build "%s, %s, %s..." for the IN clause; pg.lua's format-based escaping
  -- handles each element individually via escape_literal.
  local marks = {}
  for i = 1, #table_names do marks[i] = "%s" end
  local sql = string.format(
    "SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_name IN (%s)",
    table.concat(marks, ", ")
  )
  local rows = M.fetchall(dbname, sql, unpack(placeholders))
  local out = {}
  for _, row in ipairs(rows) do out[row.table_name] = true end
  return out
end

return M
