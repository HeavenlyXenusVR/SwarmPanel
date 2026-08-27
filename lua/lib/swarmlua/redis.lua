-- Minimal RESP (REdis Serialization Protocol) client. copas must already be
-- required by the time this module opens a socket (same rule as every other
-- module in this fleet that touches socket.* -- see lavalink.lua's header
-- comment) so its connection is cooperative, not a process-wide stall.
--
-- Just enough of the protocol for cross-bot shared state (node health --
-- see nodepool.lua): connect, a generic command() that speaks RESP for any
-- command, and thin HSET/HGETALL/EXPIRE/DEL wrappers. Not a general-purpose
-- client -- no pipelining, no pub/sub, no RESP3.
local copas = require("copas") -- must load before socket.* anywhere in the process
local socket = require("socket")

local Redis = {}
Redis.__index = Redis

function Redis.new(opts)
  local self = setmetatable({}, Redis)
  self.host = (opts and opts.host) or "127.0.0.1"
  self.port = (opts and opts.port) or 6379
  self.sock = nil
  return self
end

function Redis:_ensure_connected()
  if self.sock then return true end
  local sock = socket.tcp()
  local ok, err = copas.connect(sock, self.host, self.port)
  if not ok and err ~= "already connected" then
    sock:close()
    return nil, err
  end
  self.sock = sock
  return true
end

local function encode_command(args)
  local parts = { "*" .. #args .. "\r\n" }
  for _, a in ipairs(args) do
    local s = tostring(a)
    parts[#parts + 1] = "$" .. #s .. "\r\n" .. s .. "\r\n"
  end
  return table.concat(parts)
end

-- Parses exactly one RESP reply from self.sock. Returns (value, err) --
-- value is a string/number for simple replies, or a Lua array for arrays;
-- Redis nil (-1 length bulk/array) comes back as Lua nil with no error.
function Redis:_read_reply()
  local line, err = copas.receive(self.sock, "*l")
  if not line then return nil, err end
  local prefix, rest = line:sub(1, 1), line:sub(2)
  if prefix == "+" then
    return rest
  elseif prefix == "-" then
    -- Third return distinguishes "Redis replied with an error" (the socket
    -- is perfectly fine, just like the exact anti-pattern pg.lua's own
    -- BUGFIX above already fixed for Postgres) from every other nil-reply
    -- case here, which really is a transport failure -- see command()'s use
    -- of this below.
    return nil, rest, true
  elseif prefix == ":" then
    return tonumber(rest)
  elseif prefix == "$" then
    local n = tonumber(rest)
    if n == -1 then return nil end
    local data, derr = copas.receive(self.sock, n + 2) -- +2 for trailing \r\n
    if not data then return nil, derr end
    return data:sub(1, n)
  elseif prefix == "*" then
    local n = tonumber(rest)
    if n == -1 then return nil end
    local out = {}
    for i = 1, n do
      local v, verr = self:_read_reply()
      if verr then return nil, verr end
      out[i] = v
    end
    return out
  else
    return nil, "unknown RESP prefix: " .. tostring(prefix)
  end
end

-- command("HSET", key, field, value, ...) -> (reply, err). On any socket
-- error the connection is dropped so the next call reconnects cleanly
-- rather than reusing a socket left in an unknown state mid-reply.
--
-- One Redis instance is shared by every guild's playback coroutine in a
-- bot process (nodepool.lua is called from Lavalink:rest(), which every
-- guild calls independently). copas.send/copas.receive both yield to the
-- scheduler mid-call, so without serialization here two coroutines'
-- send/receive pairs interleave on the same socket -- one coroutine reads
-- bytes meant for another's reply, desyncing the RESP stream entirely
-- (confirmed live: "attempt to get length of a number value" in hgetall,
-- and a nil self.sock from one coroutine's error-path close() racing
-- another's in-flight send()). A simple busy-flag mutex, yielded on via
-- copas.pause, is enough since copas is cooperative -- only I/O calls
-- inside the critical section can hand control to another coroutine.
function Redis:command(...)
  while self._busy do copas.pause() end
  self._busy = true
  local ok, cerr = self:_ensure_connected()
  if not ok then
    self._busy = false
    return nil, cerr
  end
  local args = { ... }
  local sent, serr = copas.send(self.sock, encode_command(args))
  if not sent then
    if self.sock then self.sock:close() end
    self.sock = nil
    self._busy = false
    return nil, serr
  end
  local reply, rerr, is_redis_error = self:_read_reply()
  if rerr and not reply and not is_redis_error then
    if self.sock then self.sock:close() end
    self.sock = nil
    self._busy = false
    return nil, rerr
  end
  self._busy = false
  return reply, rerr
end

function Redis:hset(key, field, value)
  return self:command("HSET", key, field, value)
end

-- Returns a plain {field = value, ...} table (nil-safe: {} on a missing key).
function Redis:hgetall(key)
  local arr, err = self:command("HGETALL", key)
  if not arr then return {}, err end
  local out = {}
  for i = 1, #arr, 2 do out[arr[i]] = arr[i + 1] end
  return out
end

function Redis:expire(key, seconds)
  return self:command("EXPIRE", key, seconds)
end

function Redis:del(key)
  return self:command("DEL", key)
end

return Redis
