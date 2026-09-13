-- Postgres connection helper (pgmoon-backed), auto-reconnecting.
local pgmoon = require("pgmoon")
local unpack = table.unpack or unpack

local Pg = {}
Pg.__index = Pg

function Pg.new(opts)
  local self = setmetatable({}, Pg)
  self.opts = {
    host = opts.host or "127.0.0.1",
    port = tonumber(opts.port or 5432),
    user = opts.user,
    password = opts.password,
    database = opts.database,
  }
  self.conn = nil
  return self
end

function Pg:ensure()
  if self.conn and self.conn.sock then
    return true
  end
  local conn = pgmoon.new(self.opts)
  local ok, err = conn:connect()
  if not ok then
    return nil, "postgres connect failed: " .. tostring(err)
  end
  -- Discord snowflake IDs (guild/user/channel/role) live in BIGINT columns and routinely
  -- exceed 2^53, the largest integer a Lua double can represent exactly. pgmoon's default
  -- OID 20 (int8) deserializer runs every bigint value through tonumber(), which silently
  -- corrupts them, e.g. 1304564041863266347 comes back as 1.3045640418633e+18. Force bigint
  -- columns to come back as the raw wire-format string instead, which preserves full
  -- precision; safe to hand straight back into another bigint column or WHERE clause since
  -- Postgres implicitly casts untyped string literals to the target numeric type.
  conn:set_type_deserializer(20, "string")
  self.conn = conn
  return true
end

-- BUGFIX 2026-09-13: pgmoon's receive_message() (init.lua ~line 957) returns
-- `nil, "receive_message: failed to get type: " .. err` when the socket read
-- itself fails (peer closed, idle-killed, reset) -- but it does NOT clear
-- self.sock on that path, only on paths that call conn:disconnect() (which we
-- never do on this side). So after the underlying TCP connection dies (a
-- Postgres-side idle timeout, a network blip, anything short of us calling
-- disconnect ourselves), self.conn.sock stays a truthy-but-dead socket object
-- forever -- the "not self.conn.sock" check below never trips, :ensure()
-- keeps believing the connection is fine, and every single query on this Pg
-- instance fails with this same "closed" error from then on, with no
-- self-healing, until the whole process is restarted by hand. Confirmed live
-- across the fleet's logs (sapphire: "db error: receive_message: failed to
-- get type: closed") -- and since this same q()/Pg instance backs EVERY
-- DB-dependent path (poll_direct_orders, recovery_watchdog, get_home_channel,
-- playback state), one dead connection silently breaks direct orders from
-- Aria/SwarmPanel AND the in-process voice-recovery watchdog at the same
-- time, on whichever bot happens to hit it -- exactly the "stops responding
-- to Aria and never recovers voice after being up for days" symptom. A
-- genuine Postgres-side SQL error (bad query, constraint violation) comes
-- back through this same nil+string-error shape too (see receive_query_result
-- in pgmoon), but always as "SEVERITY: message" (parse_error's format) --
-- never with this literal internal Lua-side tag -- so matching on the tag
-- itself is exact, with no risk of mistaking a real SQL error for a dead
-- socket.
local function is_dead_connection_error(err)
  return type(err) == "string" and err:find("^receive_message: failed to get type:") ~= nil
end

-- query(sql, ...) -> rows, err. Params are escaped via pgmoon's built-in escaping.
function Pg:query(sql, ...)
  local ok, err = self:ensure()
  if not ok then return nil, err end

  local n = select('#', ...)
  if n > 0 then
    local args = { ... }
    for i = 1, n do
      local v = args[i]
      args[i] = (v == nil) and "NULL" or self.conn:escape_literal(v)
    end
    sql = sql:format(unpack(args, 1, n))
  end

  local res, err2 = self.conn:query(sql)
  if res == nil then
    -- BUGFIX: this used to treat ANY nil result as "connection dropped" and
    -- force a reconnect unconditionally -- including plain Postgres ERROR
    -- responses (bad SQL, a constraint/type violation, etc.) on an
    -- otherwise-perfectly-live connection. Harmless for a one-off error, but
    -- a bug that makes the same query fail on every call in a tight loop
    -- (e.g. a column-length violation hit once per row while inserting
    -- hundreds of rows) reconnected on every single failure, opening a new
    -- Postgres backend connection each time -- fast enough to exhaust
    -- max_connections for the whole swarm (13 bots + the panel all share
    -- this instance) well before anyone notices the original bug. pgmoon
    -- tears down its own socket (self.conn.sock becomes falsy) on a genuine
    -- I/O-level connection loss, so that's the actual signal to reconnect
    -- on -- a live socket with a nil query result is just a real error to
    -- hand back to the caller.
    if not self.conn.sock or is_dead_connection_error(err2) then
      -- Best-effort: the socket is already dead, so a terminate-message
      -- send inside disconnect() failing is expected and harmless -- this
      -- is just trying to free the fd instead of leaking it, not something
      -- worth surfacing as a query failure.
      pcall(function() self.conn:disconnect() end)
      self.conn = nil
      local ok2 = self:ensure()
      if not ok2 then return nil, err2 end
      res, err2 = self.conn:query(sql)
      if res == nil then return nil, err2 end
    else
      return nil, err2
    end
  end
  return res
end

return Pg
