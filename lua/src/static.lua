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

-- Assets are held in memory and re-read from disk at most every
-- RELOAD_SECONDS, so an edit still takes effect without a process restart
-- but a page load no longer costs a blocking disk read (and a full
-- 116KB stylesheet copy) per request. Each version carries a content hash:
-- html.lua links assets as /static/app.css?v=<hash>, which lets browsers
-- cache them for a year and still pick up an edit immediately (the URL
-- changes), and the ETag turns a plain revalidation into a bodiless 304.
local socket = require("socket")
local RELOAD_SECONDS = 5
local file_cache = {} -- relpath -> { checked_at =, data =, etag = }

local ok_bit, bit = pcall(require, "bit")
local function content_hash(data)
  if not ok_bit then return string.format("%x", #data) end
  -- djb2 (xor variant); h stays a signed 32-bit int, so h * 33 is always
  -- exact in a double.
  local h = 5381
  for i = 1, #data do
    h = bit.tobit(bit.bxor(h * 33, data:byte(i)))
  end
  return bit.tohex(h) .. string.format("%x", #data)
end

local function read_file(relpath)
  local f = io.open(relpath, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function load_asset(relpath)
  local now = socket.gettime()
  local entry = file_cache[relpath]
  if entry and now - entry.checked_at < RELOAD_SECONDS then return entry end
  local data = read_file(relpath)
  if not data then
    file_cache[relpath] = nil
    return nil
  end
  if entry and entry.data == data then
    entry.checked_at = now
    return entry
  end
  entry = { checked_at = now, data = data, etag = '"' .. content_hash(data) .. '"' }
  file_cache[relpath] = entry
  return entry
end

local ASSET_FILES = {}
for _, asset in ipairs(ASSETS) do ASSET_FILES[asset.path] = asset.file end

-- Versioned URL for a registered asset (falls back to the bare path if the
-- file can't be read, so a missing file still 404s visibly).
function M.url(path)
  local file = ASSET_FILES[path]
  local entry = file and load_asset(file)
  if not entry then return path end
  return path .. "?v=" .. entry.etag:gsub('"', "")
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
      local entry = load_asset(asset.file)
      if not entry then return 404, "Not found", { ["Content-Type"] = "text/plain" } end
      local versioned = req.query and req.query.v and req.query.v ~= ""
      local headers = {
        ["Content-Type"] = asset.content_type,
        ["Cache-Control"] = versioned and "public, max-age=31536000, immutable" or "public, max-age=60",
        ["ETag"] = entry.etag,
      }
      if req.headers and req.headers["if-none-match"] == entry.etag then
        return 304, "", headers
      end
      return 200, entry.data, headers
    end)
  end
end

return M
