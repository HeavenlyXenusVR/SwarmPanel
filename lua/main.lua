-- SwarmPanel backend (Lua rewrite) entrypoint.
package.path = "./lib/?.lua;./lib/?/init.lua;./src/?.lua;" .. package.path

local config = require("config")
local db = require("db")
local httpd = require("httpd")
local routes = require("routes")
local pages = require("pages")
local pages_ops = require("pages_ops")
local pages_identity = require("pages_identity")
local pages_admin = require("pages_admin")
local static = require("static")

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
local pages_cfg = {
  settings = settings,
  music_bots = config.music_bots,
  aria_bot = config.aria_bot,
  get_auth = routes.get_auth,
  require_auth_page = routes.require_auth_page,
  session_cookie_header = routes.session_cookie_header,
  clear_session_cookie_header = routes.clear_session_cookie_header,
}
pages.register(pages_cfg)
pages_ops.register(pages_cfg)
pages_identity.register(pages_cfg)
pages_admin.register(pages_cfg)
static.register()

httpd.listen("0.0.0.0", settings.port)
httpd.run()
