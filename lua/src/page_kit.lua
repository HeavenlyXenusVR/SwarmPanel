-- Shared plumbing for every server-rendered page module (pages_auth,
-- pages_fleet, pages_insights, pages_community, pages_account,
-- pages_admin). Each of those used to carry its own copy of
-- session_view()/page_shell()/denied(), which had already drifted apart
-- (Diagnostics' access-denied page, for one, rendered without the viewer's
-- theme or live-socket token). One copy here keeps every screen's chrome
-- identical.
local html = require("html")
local accounts = require("accounts")
local nav = require("nav")

local M = {}

M.HTML_HEADERS = { ["Content-Type"] = "text/html; charset=utf-8" }

-- Builds the {authenticated=, username=, admin_mode=, ...} shape html.lua's
-- layout()/nav expect from the raw auth payload get_auth() returns (or nil
-- when unauthenticated) -- the same fields routes.lua's GET /api/session
-- computes, reused here for page chrome.
function M.session_view(a)
  if not a then return { authenticated = false } end
  return {
    authenticated = true,
    username = a.username,
    site_owner = a.site_owner == true,
    admin_mode = a.admin_mode == true,
    moderator = a.moderator == true,
    image_gallery_owner = (a.admin_mode == true) and (a.site_owner == true),
    guild_id = a.guild_id,
  }
end

function M.preferences_for(a)
  if not a then return nil end
  return accounts.get_panel_preferences(a.username, a.guild_id)
end

-- Wraps a page body (usually html.page(...)) in the full panel layout.
-- extra_script is raw JS placed in a trailing <script>; prefs may be passed
-- in when the caller already loaded them (Appearance does), otherwise
-- they're fetched for the signed-in account.
function M.page_shell(req, a, path, title, body_html, extra_script, prefs)
  local script = extra_script and extra_script ~= "" and ("<script>" .. extra_script .. "</script>") or ""
  return 200, html.layout({
    title = title, path = path, session = M.session_view(a),
    token = req.cookies and req.cookies.swarm_session,
    preferences = prefs or M.preferences_for(a),
    body = body_html .. script,
  }), M.HTML_HEADERS
end

-- Standard "you can't see this" screen, rendered inside the normal shell
-- so the viewer keeps their navigation and theme.
function M.denied(req, a, path, title, message)
  return M.page_shell(req, a, path, title, html.page({
    title = title,
    body = html.notice("error", message or "You don't have access to this page."),
  }))
end

-- True when this session may open the screen at `path`, using the same
-- `when` gate nav.lua applies to the sidebar -- so a screen is reachable
-- exactly when it's listed.
function M.allowed(a, path)
  local _, item = nav.locate(path)
  if not item then return false end
  return nav.can_see(M.session_view(a), item)
end

return M
