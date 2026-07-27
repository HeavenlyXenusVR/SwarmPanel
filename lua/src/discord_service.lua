-- Discord REST enrichment: bot identity/avatar, guild/channel name
-- resolution, OAuth invite links. Port of the read paths of
-- app/discord_api.py's DiscordInventoryService, on top of the already-
-- vendored lua/lib/swarmlua/rest.lua (blocking client, but copas-patched
-- luasocket/luasec means the blocking wait only suspends the current
-- request's own coroutine, not the whole event loop — same trade-off the
-- vendored rest.lua's own header comment already calls out).
--
-- NOT ported: fetch_active_threads / archived-thread channel-name fallback,
-- fetch_inventory (the full per-bot guild+channel tree used by a settings/
-- inventory page this rewrite hasn't gotten to yet). Scoped to exactly what
-- dashboard.lua's enrichment and /api/bots's invite cards need.
local Rest = require("swarmlua.rest")
local sodium = require("luasodium")
local cjson = require("cjson")
local https = require("ssl.https")

-- Default is 60s (ssl/https.lua's own default) — far too long to hold up an
-- admin dashboard request if Discord is slow/unreachable. Mirrors the
-- Python original's DISCORD_IDENTITY_LOOKUP_TIMEOUT_SECONDS(4s)/
-- DISCORD_NAME_RESOLUTION_TIMEOUT_SECONDS(6s) env-tunable timeouts, collapsed
-- to one conservative per-request socket timeout since this client has no
-- asyncio.wait_for()-style per-call deadline to hook into.
https.TIMEOUT = tonumber(os.getenv("SWARM_PANEL_DISCORD_TIMEOUT_SECONDS")) or 5

local M = {}

-- rest.lua decodes JSON via plain `cjson` (not cjson.safe), whose `null`
-- comes back as the cjson.null lightuserdata sentinel, not Lua nil. That
-- sentinel is truthy in Lua, so `value or fallback` idioms silently pick the
-- JSON-null value instead of falling back — bit us immediately on GWS's real
-- identity response (global_name: null). Normalize at the boundary instead
-- of trying to remember this at every call site.
local function denull(v)
  if v == cjson.null then return nil end
  return v
end

local CACHE_TTL = 300
local cache = {} -- cache_key -> {expires_monotonic, data}
local rest_clients = {} -- token -> Rest instance

local function rest_for(token)
  local r = rest_clients[token]
  if not r then
    r = Rest.new(token)
    rest_clients[token] = r
  end
  return r
end

local function cached_get(token, path)
  local key = token .. "\0" .. path
  local now = os.clock()
  local hit = cache[key]
  if hit and hit[1] > now then return hit[2], nil end
  local rest = rest_for(token)
  local data, err = rest:get(path)
  if data == nil then return nil, err end
  cache[key] = { now + CACHE_TTL, data }
  return data, nil
end

local CHANNEL_TYPE_NAMES = {
  [0] = "text", [2] = "voice", [4] = "category", [5] = "announcement",
  [10] = "announcement_thread", [11] = "public_thread", [12] = "private_thread",
  [13] = "stage", [15] = "forum",
}

function M.fetch_identity(token)
  local data, err = cached_get(token, "/users/@me")
  if not data then return nil, err end
  local user_id = data.id and tostring(data.id) or nil
  local avatar = denull(data.avatar)
  return {
    id = user_id,
    username = denull(data.username),
    global_name = denull(data.global_name),
    discriminator = denull(data.discriminator),
    avatar = avatar,
    avatar_url = (user_id and avatar) and string.format("https://cdn.discordapp.com/avatars/%s/%s.png?size=128", user_id, avatar) or nil,
  }
end

function M.fetch_guilds(token)
  local data, err = cached_get(token, "/users/@me/guilds?limit=200")
  if not data then return {}, err end
  local out = {}
  for _, g in ipairs(data) do
    out[#out + 1] = { id = tostring(g.id), name = denull(g.name) or ("Guild " .. tostring(g.id)), owner = g.owner and true or false, permissions = denull(g.permissions) }
  end
  return out, nil
end

function M.fetch_guild(token, guild_id)
  local data, err = cached_get(token, "/guilds/" .. tostring(guild_id))
  if not data then return { id = tostring(guild_id), name = "Unknown/Inaccessible Guild " .. tostring(guild_id) } end
  return { id = tostring(data.id), name = denull(data.name) or ("Guild " .. tostring(guild_id)) }
end

function M.fetch_guild_channels(token, guild_id)
  local data, err = cached_get(token, "/guilds/" .. tostring(guild_id) .. "/channels")
  if not data or type(data) ~= "table" then return {} end
  local out = {}
  for _, ch in ipairs(data) do
    local ctype = tonumber(ch.type) or -1
    local parent_id = denull(ch.parent_id)
    out[#out + 1] = {
      id = tostring(ch.id), name = denull(ch.name) or ("Channel " .. tostring(ch.id)),
      type = ctype, type_name = CHANNEL_TYPE_NAMES[ctype] or tostring(ctype),
      parent_id = parent_id and tostring(parent_id) or nil,
    }
  end
  return out
end

-- Port of app/discord_api.py's DiscordInventoryService.fetch_inventory():
-- the full per-bot guild+channel tree used by the Controls page's
-- guild/channel pickers. Previously NOT ported (see this file's header
-- comment) -- ControlsPage.jsx's GET /api/bots/:bot_key/inventory call was
-- 404ing against httpd's generic not-found handler, which is what surfaced
-- to users as "not found" for guilds/voice/text channels.
--
-- guild_hints: known guild ids to fall back to (from db-known-guilds) when
-- /users/@me/guilds itself fails or a hinted guild isn't in that list --
-- mirrors the Python original's guild_hints handling, simplified since Lua's
-- rest.lua doesn't distinguish a 404 DiscordAPIError from other failures at
-- this call site (cached_get just returns nil, err for any non-2xx).
function M.fetch_inventory(token, opts)
  opts = opts or {}
  local include_channels = opts.include_channels
  if include_channels == nil then include_channels = true end
  local guild_hints = opts.guild_hints or {}

  local payload = { identity = nil, guilds = {}, errors = {} }

  local identity, ident_err = M.fetch_identity(token)
  if identity then
    payload.identity = identity
  else
    payload.errors[#payload.errors + 1] = "identity: " .. tostring(ident_err)
  end

  local guilds, guilds_err = M.fetch_guilds(token)
  local seen_guild_ids = {}
  local deduped = {}
  if guilds_err then
    payload.errors[#payload.errors + 1] = "guilds: " .. tostring(guilds_err)
  end
  for _, g in ipairs(guilds or {}) do
    local gid = tostring(g.id)
    if not seen_guild_ids[gid] then
      seen_guild_ids[gid] = true
      deduped[#deduped + 1] = g
    end
  end

  -- Only resolve hinted guilds not already returned by /users/@me/guilds --
  -- avoids N redundant Discord API calls on every inventory refresh.
  for _, guild_id in ipairs(guild_hints) do
    local gid_str = tostring(guild_id)
    if not seen_guild_ids[gid_str] then
      local guild = M.fetch_guild(token, guild_id)
      deduped[#deduped + 1] = guild
      seen_guild_ids[tostring(guild.id or gid_str)] = true
    end
  end

  for _, guild in ipairs(deduped) do
    if include_channels then
      local channels = M.fetch_guild_channels(token, guild.id)
      guild.channels = channels
      if #channels == 0 then
        -- fetch_guild_channels swallows errors into an empty list (see its
        -- own comment); surface a hint instead of a silently-empty channel
        -- picker, matching the Python original's channels_error field.
        guild.channels_error = "No channels visible to this bot in this guild."
      end
    else
      guild.channels = {}
    end
  end
  payload.guilds = deduped
  return payload
end

-- placements: array of {guild_id=, channel_id=} (channel_id may be nil).
-- Returns map keyed by "guild_id\0channel_id_or_empty" -> {guild_name=, channel_name=}.
function M.resolve_guild_channel_names(token, placements)
  local by_guild = {}
  for _, p in ipairs(placements) do
    local gid = tostring(p.guild_id)
    by_guild[gid] = by_guild[gid] or {}
    by_guild[gid][p.channel_id and tostring(p.channel_id) or ""] = true
  end

  local output = {}
  for gid, channel_ids in pairs(by_guild) do
    local guild = M.fetch_guild(token, gid)
    local channels = M.fetch_guild_channels(token, gid)
    local channel_name_map = {}
    for _, ch in ipairs(channels) do channel_name_map[ch.id] = ch.name end
    for cid in pairs(channel_ids) do
      local channel_name = (cid ~= "") and channel_name_map[cid] or nil
      output[gid .. "\0" .. cid] = { guild_name = guild.name, channel_name = channel_name }
    end
  end
  return output
end

-- The Discord bot user id is the first (dot-separated) segment of a bot
-- token, base64-encoded. Mirrors auth_deps.py's _client_id_from_token().
function M.client_id_from_token(token)
  local head = tostring(token or ""):match("^([^.]+)")
  if not head or head == "" then return nil end
  local ok, decoded = pcall(sodium.sodium_base642bin, head, sodium.sodium_base64_VARIANT_ORIGINAL)
  if not ok or not decoded then
    -- token heads are unpadded base64 — retry with the URL-safe/no-padding variant
    ok, decoded = pcall(sodium.sodium_base642bin, head, sodium.sodium_base64_VARIANT_ORIGINAL_NO_PADDING)
  end
  if not ok or not decoded then return nil end
  return decoded:match("^%s*(.-)%s*$")
end

local DISCORD_PERMISSION_BITS = {
  ["Kick Members"] = 1, ["Ban Members"] = 2, ["Manage Channels"] = 4, ["Manage Server"] = 5,
  ["View Channels"] = 10, ["Send Messages"] = 11, ["Manage Messages"] = 13, ["Embed Links"] = 14,
  ["Attach Files"] = 15, ["Read Message History"] = 16, ["Connect"] = 20, ["Speak"] = 21,
  ["Use Voice Activity"] = 25, ["Manage Nicknames"] = 27, ["Manage Roles"] = 28,
  ["Use Application Commands"] = 31, ["Request To Speak"] = 32, ["Timeout Members"] = 40,
}

M.MUSIC_BOT_PERMISSIONS = {
  "View Channels", "Send Messages", "Embed Links", "Attach Files", "Read Message History",
  "Connect", "Speak", "Use Voice Activity", "Use Application Commands", "Request To Speak", "Manage Channels",
}
M.ARIA_BOT_PERMISSIONS = {
  "View Channels", "Send Messages", "Embed Links", "Attach Files", "Read Message History",
  "Use Application Commands", "Kick Members", "Manage Messages", "Manage Channels", "Manage Server",
  "Manage Roles", "Manage Nicknames", "Ban Members", "Timeout Members",
}
M.BOT_CAPABILITY_SUMMARIES = {
  music = "Music worker node: slash commands, queue controls, voice/stage playback, feedback messages, embeds, buttons, and channel status/topic updates.",
  orchestrator = "Aria orchestrator: slash commands, swarm routing, AI/game/economy tools, scheduled messages, moderation, roles, nicknames, slowmode, channel locks, and server utilities.",
}

function M.permission_value(permission_names)
  local total = 0
  for _, name in ipairs(permission_names) do
    local bit_index = DISCORD_PERMISSION_BITS[name]
    if bit_index then total = total + (2 ^ bit_index) end
  end
  return total
end

function M.invite_url_for_bot(client_id, permissions, guild_id)
  local url = string.format(
    "https://discord.com/oauth2/authorize?client_id=%s&permissions=%s&scope=%s",
    tostring(client_id), string.format("%.0f", permissions), "bot%20applications.commands"
  )
  if guild_id and tostring(guild_id) ~= "" then
    url = url .. "&guild_id=" .. tostring(guild_id) .. "&disable_guild_select=true"
  end
  return url
end

return M
