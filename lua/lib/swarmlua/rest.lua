-- Discord REST API client (blocking; see README for the async trade-off note).
local copas = require("copas") -- must load before socket.http/ssl.https anywhere in the process
local socket_http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local cjson = require("cjson")

-- ssl.https is built on socket.http and shares its module-level TIMEOUT
-- (seconds) for the connect/send/receive phases. Left unset, this client had
-- NO timeout at all: a stalled DNS resolution, TCP connect, or TLS handshake
-- during a real network outage could block indefinitely. Since this whole
-- process is a single-threaded copas event loop, a genuinely-blocking (not
-- copas-yielding) hang here doesn't just stall one Discord API call -- it
-- freezes every other coroutine in the bot too, including its own heartbeat
-- thread, with no way to recover short of a container restart. Confirmed
-- live: alucard froze for 2+ hours (heartbeat dead, CPU spinning) during a
-- period of real ISP-level packet loss/latency, right as this exact call
-- logged "request failed: temporary failure in name resolution" elsewhere in
-- the swarm. 15s is generous for Discord's API (which normally responds in
-- well under 1s) while still bounding the worst case.
socket_http.TIMEOUT = 15

local API_BASE = "https://discord.com/api/v10"

local Rest = {}
Rest.__index = Rest

function Rest.new(token)
  return setmetatable({ token = token }, Rest)
end

function Rest:_request_once(method, path, body)
  local response_body = {}
  local request_body = body and cjson.encode(body) or nil
  local headers = {
    ["Authorization"] = "Bot " .. self.token,
    ["User-Agent"] = "SwarmLua (https://github.com/, 1.0)",
    ["Content-Type"] = "application/json",
  }
  if request_body then
    headers["Content-Length"] = tostring(#request_body)
  end

  local ok, status = https.request({
    url = API_BASE .. path,
    method = method,
    headers = headers,
    source = request_body and ltn12.source.string(request_body) or nil,
    sink = ltn12.sink.table(response_body),
  })

  local raw = table.concat(response_body)
  local decoded = nil
  if #raw > 0 then
    local ok2, parsed = pcall(cjson.decode, raw)
    if ok2 then decoded = parsed end
  end

  if not ok then
    return nil, "request failed: " .. tostring(status)
  end
  if type(status) == "number" and status == 429 and decoded then
    -- Discord rate limit. Caller should back off retry_after seconds and retry.
    return nil, "rate_limited", decoded.retry_after
  end
  if type(status) == "number" and status >= 400 then
    return nil, "http " .. status .. ": " .. raw
  end
  return decoded, nil
end

-- BUGFIX 2026-08-22: "rate_limited"/retry_after has been part of this
-- module's documented return contract (see README) since it was written,
-- but confirmed live via a fleet-wide grep -- not one of the 13 bots' ~700
-- combined command/handler call sites actually checks for it. Every 429
-- response has always just been treated as a generic failure (a swallowed
-- error, or a user-facing "something went wrong") with no retry, silently
-- dropping whatever the call was trying to do. Retrying transparently
-- inside the shared client fixes every caller everywhere at once, with no
-- signature/contract change: callers that never checked "rate_limited"
-- still just see success or a real failure, exactly as before, except a
-- 429 no longer surfaces as one. Capped at 3 attempts and Discord's own
-- retry_after (rarely more than a couple seconds for a single bot's
-- traffic) so a pathological/misbehaving rate limit can't wedge the
-- calling coroutine indefinitely.
local MAX_RATE_LIMIT_RETRIES = 3

function Rest:request(method, path, body)
  for attempt = 1, MAX_RATE_LIMIT_RETRIES + 1 do
    local decoded, err, retry_after = self:_request_once(method, path, body)
    if err ~= "rate_limited" then
      return decoded, err
    end
    if attempt > MAX_RATE_LIMIT_RETRIES then
      return nil, "rate_limited (gave up after " .. MAX_RATE_LIMIT_RETRIES .. " retries)"
    end
    copas.sleep(tonumber(retry_after) or 1)
  end
end

function Rest:get(path) return self:request("GET", path) end
function Rest:post(path, body) return self:request("POST", path, body) end
function Rest:patch(path, body) return self:request("PATCH", path, body) end
function Rest:delete(path) return self:request("DELETE", path) end
function Rest:put(path, body) return self:request("PUT", path, body) end

return Rest
