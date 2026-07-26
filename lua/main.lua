-- SwarmPanel backend (Lua rewrite) entrypoint.
package.path = "./lib/?.lua;./lib/?/init.lua;./src/?.lua;" .. package.path

local config = require("config")
local db = require("db")
local httpd = require("httpd")
local routes = require("routes")

local settings = config.load()
db.init(settings)

httpd.cors.allowed_origins = settings.cors_allowed_origins
-- Settings ship a Python `re` pattern for preview-tunnel origins, e.g.
--   https://[a-zA-Z0-9-]+\.(trycloudflare\.com|ngrok-free\.dev|ngrok\.io)
-- Lua patterns have no alternation operator, so a literal regex translation
-- is not possible. Instead, pull the suffix alternatives out of the `(a|b|c)`
-- group and check "https://<subdomain>.<suffix>" directly. This covers the
-- one shape actually used in .env; anything more exotic than that falls back
-- to exact-origin matching only (cors_allowed_origins).
local function build_origin_suffix_matcher(pcre)
  if not pcre or pcre == "" then return nil end
  local alternation = pcre:match("%(([^%)]+)%)")
  if not alternation then return nil end
  local suffixes = {}
  for part in alternation:gmatch("[^|]+") do
    suffixes[#suffixes + 1] = part:gsub("\\%.", ".")
  end
  return function(origin)
    if not origin then return false end
    local subdomain = origin:match("^https://([%w%-]+)%.")
    if not subdomain then return false end
    for _, suffix in ipairs(suffixes) do
      if origin == "https://" .. subdomain .. "." .. suffix then return true end
    end
    return false
  end
end
httpd.cors.origin_suffix_matcher = build_origin_suffix_matcher(settings.cors_allow_origin_regex)

routes.register({
  settings = settings,
  music_bots = config.music_bots,
  aria_bot = config.aria_bot,
  bot_index = config.bot_index,
  bot_tokens = config.bot_tokens,
  bot_accents = config.bot_accents,
})

httpd.listen("0.0.0.0", settings.port)
httpd.run()
