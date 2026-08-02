-- Serves the hand-written vanilla-JS/CSS assets for the server-rendered
-- pages (see html.lua). Deliberately tiny: only two files exist, so a
-- generic /static/* wildcard router isn't worth adding to httpd.lua's
-- pattern matcher -- each asset just gets its own exact route.
local httpd = require("httpd")

local M = {}

local ASSETS = {
  { path = "/static/app.css", file = "static/app.css", content_type = "text/css; charset=utf-8" },
  { path = "/static/app.js", file = "static/app.js", content_type = "application/javascript; charset=utf-8" },
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

function M.register()
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
