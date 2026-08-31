-- Real outbound notification delivery: Discord-webhook verification codes
-- (the ONLY channel SwarmPanel account verification actually uses — see
-- below) and SMTP email (the one live channel Image Gallery's admin
-- resend-verification action uses). Port of app/verification.py's
-- _send_verification_webhook_code/_verify_guild_registration_proof/
-- _validate_discord_webhook_url plus app/emailer.py's send_email.
--
-- IMPORTANT finding from reading the Python original end-to-end: SwarmPanel
-- account email verification (register / resend-verification /
-- verification-webhook update / admin resend-verification, all in
-- app/routers/session.py + app/routers/swarm_accounts.py) is 100%
-- Discord-webhook-based. app/emailer.py's send_verification_email() and
-- accounts.py's issue_account_email_verification_token()/
-- verify_account_email_by_token() exist but are DEAD CODE — grepped every
-- router and confirmed nothing ever calls them. The only LIVE SMTP call site
-- in the whole app is Image Gallery's send_image_gallery_verification_email
-- (app/routers/gallery.py's /api/image-gallery/users/resend-verification).
-- This module implements both transports for parity with what's actually
-- reachable, not the dead email-link path.
-- copas must be require()'d before ssl.https/socket.http anywhere in the
-- process (same constraint documented in swarmlua/rest.lua) or copas.lua
-- raises "you must require copas before require'ing socket.http".
local copas = require("copas")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local cjson = require("cjson.safe")
local socket = require("socket")
local mime = require("mime")

-- Shared mutable global on the ssl.https module, same caveat already present
-- in discord_service.lua (which also sets https.TIMEOUT at load time): under
-- copas, two coroutines mid-flight could in principle race this value. In
-- practice these are short-lived admin-triggered actions (registration,
-- resend-verification), not hot paths, so the existing project convention
-- (set once, don't fuss over it) is kept rather than inventing a different
-- pattern for just this module.
https.TIMEOUT = 10

local M = {}

-- ---------------------------------------------------------------------------
-- Discord webhook verification (the live SwarmPanel account channel)
-- ---------------------------------------------------------------------------

-- Mirrors validators.py's _validate_discord_webhook_url(): must be an
-- https://discord.com|discordapp.com/api/webhooks/<id>/<token> URL.
function M.validate_discord_webhook_url(value)
  local url = tostring(value or ""):match("^%s*(.-)%s*$")
  local scheme, host = url:match("^(https?)://([^/]+)")
  local allowed_hosts = { ["discord.com"] = true, ["www.discord.com"] = true, ["discordapp.com"] = true, ["www.discordapp.com"] = true }
  if scheme ~= "https" or not host or not allowed_hosts[host:lower()] then
    error("Invalid Discord webhook URL", 0)
  end
  local path = url:match("^https://[^/]+(/.*)$") or ""
  local parts = {}
  for part in path:gmatch("[^/]+") do parts[#parts + 1] = part end
  if #parts < 4 or parts[1] ~= "api" or parts[2] ~= "webhooks" then
    error("Invalid Discord webhook URL", 0)
  end
  return url
end

local function http_post_json(url, payload)
  local body = cjson.encode(payload)
  local response_body = {}
  local ok, status = https.request({
    url = url,
    method = "POST",
    headers = {
      ["Content-Type"] = "application/json",
      ["Content-Length"] = tostring(#body),
      ["User-Agent"] = "SwarmPanel-Lua (https://github.com/, 1.0)",
    },
    source = ltn12.source.string(body),
    sink = ltn12.sink.table(response_body),
  })
  local raw = table.concat(response_body)
  if not ok then return nil, "request failed: " .. tostring(status) end
  return status, raw
end

local function http_get(url)
  local response_body = {}
  local ok, status = https.request({
    url = url,
    method = "GET",
    headers = { ["User-Agent"] = "SwarmPanel-Lua (https://github.com/, 1.0)" },
    sink = ltn12.sink.table(response_body),
  })
  local raw = table.concat(response_body)
  if not ok then return nil, "request failed: " .. tostring(status) end
  return status, raw
end

-- Port of app/verification.py's _send_verification_webhook_code(). Returns
-- boolean sent (true only on a 2xx from Discord), never raises — same
-- best-effort contract as the Python original (caller reports
-- verification_sent=false rather than failing the whole request).
function M.send_verification_webhook_code(webhook_url, code, username, guild_id)
  local ok, normalized = pcall(M.validate_discord_webhook_url, webhook_url)
  if not ok then return false end
  local content = string.format(
    "SwarmPanel verification for `%s` in guild `%s`\nCode: **%s**\n"
      .. "Enter this code in SwarmPanel to verify your account. "
      .. "If you did not request this, you can ignore this message.",
    tostring(username), tostring(guild_id), tostring(code)
  )
  if #content > 1900 then content = content:sub(1, 1900) end
  local payload = { content = content, allowed_mentions = { parse = {} }, username = "SwarmPanel Verify" }
  local status = http_post_json(normalized, payload)
  return type(status) == "number" and status < 400
end

-- Generic Discord webhook send (used by the end-to-end validation script and
-- available for any future non-verification notification needs). Returns
-- ok, status_or_err.
function M.send_discord_webhook_content(webhook_url, content, opts)
  local normalized = M.validate_discord_webhook_url(webhook_url)
  local payload = { content = content, allowed_mentions = { parse = {} } }
  if opts and opts.username then payload.username = opts.username end
  local status, raw = http_post_json(normalized, payload)
  if type(status) ~= "number" then return false, status end
  return status < 400, status, raw
end

-- ---------------------------------------------------------------------------
-- Bot-authenticated Discord REST calls (DM-based account verification).
-- Distinct from the webhook path above: this uses a real bot identity
-- (Authorization: Bot <token>) that can open a DM channel directly with any
-- Discord user who shares a server with it and allows DMs from server
-- members -- Discord does not allow bots to message arbitrary strangers
-- with no shared server, and there is no way around that from this side.
-- Mirrors the Image Gallery app's discord_bot.lua (same product, proven
-- design), ported onto this file's ssl.https+copas client instead of
-- copas.http since that's this codebase's established HTTP pattern.
-- ---------------------------------------------------------------------------

local function http_bot_call(method, path, token, payload)
  local body = payload and cjson.encode(payload) or nil
  local response_body = {}
  local headers = {
    ["Authorization"] = "Bot " .. tostring(token),
    ["User-Agent"] = "SwarmPanel-Lua (https://github.com/, 1.0)",
  }
  if body then
    headers["Content-Type"] = "application/json"
    headers["Content-Length"] = tostring(#body)
  end
  local ok, status = https.request({
    url = "https://discord.com/api/v10" .. path,
    method = method,
    headers = headers,
    source = body and ltn12.source.string(body) or nil,
    sink = ltn12.sink.table(response_body),
  })
  local raw = table.concat(response_body)
  if not ok then return nil, "request failed: " .. tostring(status) end
  local decode_ok, decoded = pcall(cjson.decode, raw ~= "" and raw or "{}")
  return status, (decode_ok and type(decoded) == "table") and decoded or {}
end

-- Exported for control.lua's command-gate relay (posting a command summary
-- into a bot's own GWS Commands thread, as that bot, before a panel action
-- that mutates its queue tables directly is allowed to proceed) -- same
-- bot-authenticated call this file already uses for DM verification, just
-- generalized past the two DM-shaped call sites below.
M.bot_api_call = http_bot_call

-- Opens (or reuses) a DM channel with discord_user_id and sends `content`.
-- Returns true on success, or false + a user-facing error message. Fails
-- closed on any ambiguity (network error, non-2xx, missing channel id)
-- rather than reporting false success -- same contract Image Gallery's
-- discord_bot.lua already proved out.
function M.send_discord_dm(bot_token, discord_user_id, content)
  if not bot_token or bot_token == "" then
    return false, "Discord DM verification isn't configured on this server yet."
  end
  local digits = tostring(discord_user_id or ""):match("^%d+$")
  if not digits then
    return false, "That doesn't look like a valid Discord User ID (numbers only)."
  end
  local status1, channel = http_bot_call("POST", "/users/@me/channels", bot_token, { recipient_id = digits })
  local code1 = tonumber(status1) or 0
  if code1 < 200 or code1 >= 300 or not channel.id then
    return false, "Could not open a DM with that account -- make sure you share a server with the verification bot and allow direct messages from server members."
  end
  local status2, err_payload = http_bot_call("POST", "/channels/" .. channel.id .. "/messages", bot_token, { content = content })
  local code2 = tonumber(status2) or 0
  if code2 < 200 or code2 >= 300 then
    local reason = err_payload and err_payload.message
    return false, reason and ("Discord rejected the message: " .. reason) or ("Discord rejected the message: " .. tostring(status2))
  end
  return true, nil
end

-- Best-effort username lookup (cosmetic "Verified as @handle" display only)
-- -- returns nil on any failure rather than erroring, since a successful
-- DM-based verification must never be undone by a follow-up API hiccup on
-- this purely cosmetic enrichment.
function M.get_discord_username(bot_token, discord_user_id)
  if not bot_token or bot_token == "" then return nil end
  local status, payload = http_bot_call("GET", "/users/" .. tostring(discord_user_id), bot_token, nil)
  local code = tonumber(status) or 0
  if code < 200 or code >= 300 then return nil end
  return payload.global_name or payload.username
end

-- Port of app/verification.py's _verify_guild_registration_proof(): resolves
-- a webhook URL to its guild_id/channel_id/name via Discord's public
-- (no bot-token-required) GET /webhooks/{id}/{token} endpoint, and confirms
-- it actually belongs to the guild being registered. Raises (error(msg,0))
-- on any validation failure, mirroring the Python ValueError contract that
-- routes.lua's callers already catch via pcall.
function M.verify_guild_registration_proof(guild_id, proof_url)
  -- Guild IDs are Discord snowflakes (up to ~19 digits) — going through
  -- tonumber()/math.floor() here would round-trip through a double and
  -- silently corrupt the low digits past 2^53 (~9.0e15), the exact
  -- string-vs-number snowflake bug already found and fixed twice elsewhere
  -- in this codebase (see the top-level task notes). Stay string-only:
  -- validate all-digits and strip leading zeros by pattern match instead.
  local verified_guild_id = tostring(guild_id or ""):match("^%s*(.-)%s*$")
  if verified_guild_id == "" or not verified_guild_id:match("^%d+$") then
    error("Guild ID must be a Discord server ID number.", 0)
  end
  verified_guild_id = verified_guild_id:gsub("^0+(%d)", "%1")
  local normalized_url = M.validate_discord_webhook_url(proof_url)
  local path = normalized_url:match("^https://[^/]+(/.*)$") or ""
  local parts = {}
  for part in path:gmatch("[^/]+") do parts[#parts + 1] = part end
  local webhook_id, webhook_token = parts[3], parts[4]
  local lookup_url = "https://discord.com/api/v10/webhooks/" .. webhook_id .. "/" .. webhook_token
  local status, raw = http_get(lookup_url)
  if type(status) ~= "number" or status >= 400 then
    error("The Discord webhook proof could not be verified right now. Try again in a moment.", 0)
  end
  local ok, payload = pcall(cjson.decode, raw)
  if not ok or type(payload) ~= "table" then
    error("The Discord webhook proof could not be verified. Create a new webhook in that server and try again.", 0)
  end
  local resolved_guild_id = tostring(payload.guild_id or ""):match("^%s*(.-)%s*$")
  if resolved_guild_id ~= verified_guild_id then
    error("The Discord webhook proof belongs to a different guild.", 0)
  end
  local channel_id = tostring(payload.channel_id or ""):match("^%s*(.-)%s*$")
  if channel_id == "" then
    error("The Discord webhook proof did not return a channel binding.", 0)
  end
  local name = tostring(payload.name or "Webhook"):match("^%s*(.-)%s*$")
  return { guild_id = resolved_guild_id, channel_id = channel_id, webhook_name = name:sub(1, 80) }
end

-- ---------------------------------------------------------------------------
-- SMTP email (Image Gallery resend-verification's live channel)
-- ---------------------------------------------------------------------------

function M.smtp_configured(cfg)
  return cfg.smtp_host ~= nil and cfg.smtp_host ~= "" and cfg.smtp_from_email ~= nil and cfg.smtp_from_email ~= ""
end

-- Minimal hand-rolled SMTP client with STARTTLS support. luasocket's bundled
-- socket.smtp module (confirmed present on this host) does NOT implement
-- STARTTLS at all (grepped its source — only AUTH LOGIN/PLAIN), and Brevo
-- (the SMTP relay actually configured in this environment's .env, port 587)
-- requires STARTTLS before AUTH. Reuses the exact same
-- copas.connect()-then-copas.dohandshake() TLS-upgrade pattern already
-- proven in lua-shared/swarmlua/gateway.lua for the Discord Gateway
-- connection, applied here to a plain-then-TLS SMTP conversation instead of
-- a plain-then-TLS WebSocket one.
function M.send_email(cfg, to_email, subject, body)
  if not M.smtp_configured(cfg) then
    return false, "SMTP is not configured"
  end
  to_email = tostring(to_email or "")
  if to_email == "" or not to_email:match("^[^@%s]+@[^@%s]+%.[^@%s]+$") then
    return false, "invalid recipient address"
  end

  local sock = socket.tcp()
  copas.settimeout(sock, 20)
  local _, conn_err = copas.connect(sock, cfg.smtp_host, cfg.smtp_port)
  if conn_err and conn_err ~= "already connected" then
    pcall(function() sock:close() end)
    return false, "connect failed: " .. tostring(conn_err)
  end

  local function read_reply()
    while true do
      local line, err = copas.receive(sock, "*l")
      if not line then return nil, err end
      local code, sep = line:match("^(%d%d%d)(.?)")
      if not code then return nil, "unexpected SMTP reply: " .. tostring(line) end
      if sep ~= "-" then return tonumber(code) end
    end
  end

  local function send_line(s)
    return copas.send(sock, s .. "\r\n")
  end

  local function fail(msg)
    pcall(send_line, "QUIT")
    pcall(function() sock:close() end)
    return false, msg
  end

  local code, err = read_reply()
  if code ~= 220 then return fail("no SMTP greeting: " .. tostring(err or code)) end

  local domain = "swarmpanel.local"
  send_line("EHLO " .. domain)
  code = read_reply()
  if code ~= 250 then return fail("EHLO rejected: " .. tostring(code)) end

  if cfg.smtp_use_tls then
    send_line("STARTTLS")
    code = read_reply()
    if code ~= 220 then return fail("STARTTLS rejected: " .. tostring(code)) end
    local wrapped, tls_err = copas.dohandshake(sock, { mode = "client", protocol = "any", verify = "none", options = "all" })
    if not wrapped then return fail("TLS handshake failed: " .. tostring(tls_err)) end
    sock = wrapped
    send_line("EHLO " .. domain)
    code = read_reply()
    if code ~= 250 then return fail("post-STARTTLS EHLO rejected: " .. tostring(code)) end
  end

  if cfg.smtp_username and cfg.smtp_username ~= "" then
    send_line("AUTH LOGIN")
    code = read_reply()
    if code ~= 334 then return fail("AUTH LOGIN not accepted: " .. tostring(code)) end
    send_line(mime.b64(cfg.smtp_username))
    code = read_reply()
    if code ~= 334 then return fail("AUTH username rejected: " .. tostring(code)) end
    send_line(mime.b64(cfg.smtp_password or ""))
    code = read_reply()
    if code ~= 235 then return fail("SMTP authentication failed: " .. tostring(code)) end
  end

  send_line("MAIL FROM:<" .. cfg.smtp_from_email .. ">")
  code = read_reply()
  if code ~= 250 then return fail("MAIL FROM rejected: " .. tostring(code)) end

  send_line("RCPT TO:<" .. to_email .. ">")
  code = read_reply()
  if code ~= 250 and code ~= 251 then return fail("recipient rejected: " .. tostring(code)) end

  send_line("DATA")
  code = read_reply()
  if code ~= 354 then return fail("DATA rejected: " .. tostring(code)) end

  local safe_subject = tostring(subject or ""):gsub("[\r\n]", " "):sub(1, 998)
  local normalized_body = tostring(body or ""):gsub("\r\n", "\n"):gsub("\n", "\r\n")
  -- Dot-stuff any line beginning with "." so it isn't parsed as the DATA
  -- terminator (RFC 5321 section 4.5.2).
  normalized_body = normalized_body:gsub("\r\n%.", "\r\n..")
  if normalized_body:sub(1, 1) == "." then normalized_body = "." .. normalized_body end

  local message = table.concat({
    "From: " .. cfg.smtp_from_email,
    "To: " .. to_email,
    "Subject: " .. safe_subject,
    "Date: " .. os.date("!%a, %d %b %Y %H:%M:%S +0000"),
    "MIME-Version: 1.0",
    "Content-Type: text/plain; charset=utf-8",
    "",
    normalized_body,
  }, "\r\n")

  send_line(message)
  send_line(".")
  code = read_reply()
  if code ~= 250 then return fail("message rejected: " .. tostring(code)) end

  send_line("QUIT")
  pcall(read_reply)
  pcall(function() sock:close() end)
  return true
end

local function url_encode(s)
  return (tostring(s):gsub("[^%w%-%.%_%~]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- Port of app/verification.py's _image_gallery_verification_url(): prefers
-- IMAGE_GALLERY_PUBLIC_BACKEND_URL, then the Image Gallery app's own
-- live-config.json (its `gallery_url` field), then falls back to this
-- panel's own public URL. The Python original also has a request-headers
-- fallback (_external_base_url) for when neither is configured; skipped
-- here since this admin-triggered action doesn't have a browser request to
-- read forwarded-host headers from, and pages_public_url covers the same
-- "self-hosted, no config" case in this deployment.
function M.image_gallery_verification_url(cfg, token)
  local origin = os.getenv("IMAGE_GALLERY_PUBLIC_BACKEND_URL")
  if origin then origin = origin:match("^%s*(.-)%s*$") end
  if not origin or origin == "" then
    local path = tostring(cfg.panel_root or ".") .. "/../Image Gallery/live-config.json"
    local f = io.open(path, "r")
    if f then
      local content = f:read("*a")
      f:close()
      local ok, decoded = pcall(cjson.decode, content)
      if ok and type(decoded) == "table" then
        local raw_origin = tostring(decoded.gallery_url or ""):match("^%s*(.-)%s*$")
        if raw_origin:match("^https?://[^/]") then origin = raw_origin end
      end
    end
  end
  origin = (origin or ""):gsub("/+$", "")
  if origin == "" then origin = tostring(cfg.pages_public_url or ""):gsub("/+$", "") end
  return origin .. "/api/auth/verify-email?token=" .. url_encode(token)
end

-- Port of app/emailer.py's send_image_gallery_verification_email() — same
-- subject/body text so this doesn't look like a different product to users
-- who already saw the Python version's emails.
function M.send_image_gallery_verification_email(cfg, to_email, verify_url, code)
  local body = table.concat({
    "Welcome to Image Gallery.",
    "",
    "Your verification code is:",
    "",
    tostring(code),
    "",
    "Enter this code in Image Gallery to verify your email address.",
    "",
    "You can also verify by opening the link below:",
    "",
    tostring(verify_url),
    "",
    "If you did not create this account, you can ignore this message.",
  }, "\n")
  return M.send_email(cfg, to_email, "Verify your Image Gallery email", body)
end

return M
