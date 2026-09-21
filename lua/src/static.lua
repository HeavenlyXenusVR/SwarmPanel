-- Serves the hand-written vanilla-JS/CSS assets for the server-rendered
-- pages (see html.lua). Deliberately tiny: only two files exist, so a
-- generic /static/* wildcard router isn't worth adding to httpd.lua's
-- pattern matcher -- each asset just gets its own exact route.
local httpd = require("httpd")

local M = {}

local ASSETS = {
  { path = "/static/app.css", file = "static/app.css", content_type = "text/css; charset=utf-8" },
  { path = "/static/app.js", file = "static/app.js", content_type = "application/javascript; charset=utf-8" },
  { path = "/static/images/image-gallery.png", file = "static/images/image-gallery.png", content_type = "image/png" },
  { path = "/static/images/lumisound.png", file = "static/images/lumisound.png", content_type = "image/png" },
}

-- Read from disk on every request rather than caching in memory: these
-- files are small (tens of KB), request volume for them is low (one fetch
-- per page load, browsers cache via Cache-Control below), and reading fresh
-- means an edit takes effect on the next request with no process restart.
local function read_file(relpath)
  local f = io.open(relpath, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

-- robots.txt: this panel is reachable from the public internet (the access
-- telemetry shows real crawler traffic from Bing/AWS/etc), and it had no
-- robots.txt at all -- so every crawler that came looking got a 404 and had
-- no instruction not to index the thing. 43 of the panel's logged 404s over
-- one week were exactly this, all of them /robots.txt or /sitemap.xml.
--
-- This is an operator console behind a login, so the correct answer for
-- every well-behaved crawler is "index nothing". Served inline rather than
-- from a file: it is three lines, and a missing file must not turn into
-- another 404. It is not a security control -- anything ignoring robots.txt
-- ignores this too; the login and ratelimit.lua are what actually guard the
-- panel -- it just keeps the console out of search results and stops the
-- 404 noise from burying real ones in the telemetry.
local ROBOTS_TXT = "User-agent: *\nDisallow: /\n"

function M.register()
  httpd.route("GET", "/robots.txt", function()
    return 200, ROBOTS_TXT, {
      ["Content-Type"] = "text/plain; charset=utf-8",
      ["Cache-Control"] = "public, max-age=86400",
    }
  end)

  for _, asset in ipairs(ASSETS) do
    httpd.route("GET", asset.path, function(req)
      local data = read_file(asset.file)
      if not data then return 404, "Not found", { ["Content-Type"] = "text/plain" } end
      return 200, data, {
        ["Content-Type"] = asset.content_type,
        ["Cache-Control"] = "public, max-age=60",
      }
    end)
  end
end

return M
