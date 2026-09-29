-- Friends, follows, direct messages, and social-snapshot methods.
-- Port of app/db/social.py against the (already-migrated) Postgres
-- accountlogins.{account_follows,account_friend_requests,account_messages,
-- account_notifications} tables — table shapes confirmed live via \d.
--
-- NOTE on require order: this module requires accounts.lua at load time.
-- accounts.lua's search_account_profiles() needs this module back, so it
-- pulls it in with a deferred `require("social")` *inside* the function body
-- instead of at module load time, to avoid a load-time circular require.
local db = require("db")
local accounts = require("accounts")

local M = {}
local SCHEMA = "accountlogins"
local unpack = table.unpack or unpack

local function coerce_int(v)
  local n = tonumber(v)
  if not n then error("Invalid id: " .. tostring(v), 0) end
  return math.floor(n)
end

-- Postgres has no FIELD(); rank statuses in the same priority order
-- (accepted > pending > declined > cancelled) via a CASE expression.
local STATUS_ORDER_SQL = "CASE status WHEN 'accepted' THEN 0 WHEN 'pending' THEN 1 WHEN 'declined' THEN 2 ELSE 3 END"

local function serialize_social_row(row)
  local item = {}
  for k, v in pairs(row or {}) do item[k] = v end
  if item.last_seen_at ~= nil then item.is_online = accounts.is_recently_seen(item.last_seen_at) end
  if item.public_profile ~= nil then item.public_profile = db.tobool(item.public_profile) end
  if item.unread_count ~= nil then item.unread_count = db.toint(item.unread_count, 0) end
  if item.guild_id ~= nil then item.guild_id = tostring(item.guild_id) end
  return item
end
M.serialize_social_row = serialize_social_row

function M.get_account_social_snapshot(account_id, viewer_account_id)
  local target_id = coerce_int(account_id)
  local viewer_id = viewer_account_id and coerce_int(viewer_account_id) or 0
  local row = db.fetchone(
    SCHEMA,
    string.format(
      [[SELECT
          (SELECT COUNT(*) FROM account_follows WHERE followed_account_id=%%s) AS follower_count,
          (SELECT COUNT(*) FROM account_follows WHERE follower_account_id=%%s) AS following_count,
          (SELECT COUNT(*) FROM account_friend_requests
             WHERE status='accepted' AND (requester_account_id=%%s OR addressee_account_id=%%s)) AS friend_count,
          EXISTS(
            SELECT 1 FROM account_follows WHERE follower_account_id=%%s AND followed_account_id=%%s
          ) AS followed_by_me]]
    ),
    target_id, target_id, target_id, target_id, viewer_id, target_id
  ) or {}

  local friend_status = "none"
  if viewer_id ~= 0 and viewer_id == target_id then
    friend_status = "self"
  elseif viewer_id ~= 0 then
    local friend_row = db.fetchone(
      SCHEMA,
      string.format(
        [[SELECT status, requester_account_id FROM account_friend_requests
          WHERE (requester_account_id=%%s AND addressee_account_id=%%s)
             OR (requester_account_id=%%s AND addressee_account_id=%%s)
          ORDER BY %s, created_at DESC LIMIT 1]],
        STATUS_ORDER_SQL
      ),
      viewer_id, target_id, target_id, viewer_id
    )
    local status = friend_row and friend_row.status or "none"
    if status == "accepted" then
      friend_status = "friends"
    elseif status == "pending" then
      friend_status = (db.toint(friend_row.requester_account_id) == viewer_id) and "pending_out" or "pending_in"
    end
  end

  return {
    follower_count = db.toint(row.follower_count, 0),
    following_count = db.toint(row.following_count, 0),
    friend_count = db.toint(row.friend_count, 0),
    followed_by_me = db.tobool(row.followed_by_me),
    friend_status = friend_status,
  }
end

-- Batched form of get_account_social_snapshot() for list views (the
-- directory/search results): the per-profile version costs two round trips
-- per row, and every DB call blocks the whole copas loop, so a 50-row
-- directory page used to serialize ~100 queries in front of every other
-- request on the server. This does the same work in two queries total and
-- returns { [account_id] = snapshot } with the identical snapshot shape.
function M.get_account_social_snapshots(account_ids, viewer_account_id)
  local viewer_id = viewer_account_id and coerce_int(viewer_account_id) or 0
  local ids, seen = {}, {}
  for _, v in ipairs(account_ids or {}) do
    local n = tonumber(v)
    if n and not seen[n] then
      seen[n] = true
      ids[#ids + 1] = math.floor(n)
    end
  end
  local out = {}
  if #ids == 0 then return out end
  for _, id in ipairs(ids) do
    out[id] = {
      follower_count = 0, following_count = 0, friend_count = 0, followed_by_me = false,
      friend_status = (viewer_id ~= 0 and viewer_id == id) and "self" or "none",
    }
  end
  local marks = {}
  for i = 1, #ids do marks[i] = "%s" end
  local id_list = "(" .. table.concat(marks, ", ") .. ")"

  -- ids are already integers (coerced above), so this VALUES list is built
  -- from numbers only -- no user text reaches the SQL string.
  local values = {}
  for i, id in ipairs(ids) do values[i] = "(" .. string.format("%d", id) .. ")" end
  local counts = db.fetchall(
    SCHEMA,
    string.format(
      [[SELECT t.id AS account_id,
          (SELECT COUNT(*) FROM account_follows WHERE followed_account_id=t.id) AS follower_count,
          (SELECT COUNT(*) FROM account_follows WHERE follower_account_id=t.id) AS following_count,
          (SELECT COUNT(*) FROM account_friend_requests
             WHERE status='accepted' AND (requester_account_id=t.id OR addressee_account_id=t.id)) AS friend_count,
          EXISTS(SELECT 1 FROM account_follows WHERE follower_account_id=%%s AND followed_account_id=t.id) AS followed_by_me
        FROM (VALUES %s) AS t(id)]],
      table.concat(values, ", ")
    ),
    viewer_id
  )
  for _, row in ipairs(counts) do
    local snap = out[db.toint(row.account_id)]
    if snap then
      snap.follower_count = db.toint(row.follower_count, 0)
      snap.following_count = db.toint(row.following_count, 0)
      snap.friend_count = db.toint(row.friend_count, 0)
      snap.followed_by_me = db.tobool(row.followed_by_me)
    end
  end

  if viewer_id ~= 0 then
    local params = { viewer_id }
    for _, id in ipairs(ids) do params[#params + 1] = id end
    params[#params + 1] = viewer_id
    for _, id in ipairs(ids) do params[#params + 1] = id end
    local rows = db.fetchall(
      SCHEMA,
      string.format(
        [[SELECT status, requester_account_id, addressee_account_id FROM account_friend_requests
          WHERE (requester_account_id=%%s AND addressee_account_id IN %s)
             OR (addressee_account_id=%%s AND requester_account_id IN %s)
          ORDER BY %s, created_at DESC]],
        id_list, id_list, STATUS_ORDER_SQL
      ),
      unpack(params)
    )
    local decided = {}
    for _, row in ipairs(rows) do
      local requester = db.toint(row.requester_account_id)
      local other = (requester == viewer_id) and db.toint(row.addressee_account_id) or requester
      local snap = out[other]
      -- Rows arrive best-status-first, so the first row per account is the
      -- same one get_account_social_snapshot's LIMIT 1 would have picked.
      if snap and not decided[other] and snap.friend_status ~= "self" then
        decided[other] = true
        if row.status == "accepted" then
          snap.friend_status = "friends"
        elseif row.status == "pending" then
          snap.friend_status = (requester == viewer_id) and "pending_out" or "pending_in"
        end
      end
    end
  end
  return out
end

function M.get_public_account_profile(account_id, viewer_account_id)
  local profile = accounts.get_account_by_id(account_id)
  if not profile then return nil end
  local viewer_id = viewer_account_id and coerce_int(viewer_account_id) or 0
  if not profile.public_profile and db.toint(profile.id) ~= viewer_id then return nil end
  local snap = M.get_account_social_snapshot(profile.id, viewer_id)
  for k, v in pairs(snap) do profile[k] = v end
  local dashboard = require("dashboard")
  local summaries = dashboard.get_music_activity_summary_for_guilds(require("config").music_bots, { profile.guild_id })
  profile.activity = summaries[profile.guild_id] or dashboard.empty_music_activity_summary()
  return profile
end

function M.set_account_follow(follower_account_id, followed_account_id, following)
  local follower_id, followed_id = coerce_int(follower_account_id), coerce_int(followed_account_id)
  if follower_id == followed_id then error("You cannot follow yourself.", 0) end
  if not accounts.get_account_by_id(followed_id) then error("Account not found.", 0) end
  if following then
    -- NOTE: the live accountlogins schema is missing `DEFAULT
    -- CURRENT_TIMESTAMP`/`DEFAULT 'pending'` on several columns across this
    -- domain (created_at here, plus account_friend_requests.status below) —
    -- a real gap found while testing this endpoint against live Postgres.
    -- ALTER TABLE to restore the defaults was blocked by the sandbox's
    -- auto-mode classifier (schema DDL against a live DB is treated as too
    -- risky to run unattended), so every INSERT in this module sets these
    -- columns explicitly instead of relying on a DB default. See final
    -- report — a follow-up with interactive approval should still apply the
    -- ALTER TABLE fix so other, non-panel callers aren't tripped by the same
    -- gap.
    db.execute(
      SCHEMA,
      [[INSERT INTO account_follows (follower_account_id, followed_account_id, created_at) VALUES (%s, %s, CURRENT_TIMESTAMP)
        ON CONFLICT (follower_account_id, followed_account_id) DO NOTHING]],
      follower_id, followed_id
    )
  else
    db.execute(SCHEMA, "DELETE FROM account_follows WHERE follower_account_id=%s AND followed_account_id=%s", follower_id, followed_id)
  end
  local row = db.fetchone(SCHEMA, "SELECT COUNT(*) AS followers FROM account_follows WHERE followed_account_id=%s", followed_id)
  return { account_id = followed_id, following = following and true or false, follower_count = db.toint(row and row.followers, 0) }
end

function M.send_account_friend_request(requester_account_id, addressee_account_id)
  local requester_id, addressee_id = coerce_int(requester_account_id), coerce_int(addressee_account_id)
  if requester_id == addressee_id then error("You cannot friend yourself.", 0) end
  if not accounts.get_account_by_id(addressee_id) then error("Account not found.", 0) end

  local existing = db.fetchone(
    SCHEMA,
    string.format(
      [[SELECT * FROM account_friend_requests
        WHERE (requester_account_id=%%s AND addressee_account_id=%%s)
           OR (requester_account_id=%%s AND addressee_account_id=%%s)
        ORDER BY %s, created_at DESC LIMIT 1]],
      STATUS_ORDER_SQL
    ),
    requester_id, addressee_id, addressee_id, requester_id
  )

  if existing and existing.status == "accepted" then
    return { status = "friends", request = serialize_social_row(existing) }
  end
  if existing and existing.status == "pending" then
    if db.toint(existing.requester_account_id) == addressee_id then
      db.execute(SCHEMA, "UPDATE account_friend_requests SET status='accepted', responded_at=CURRENT_TIMESTAMP WHERE id=%s", existing.id)
      existing.status = "accepted"
      return { status = "friends", request = serialize_social_row(existing) }
    end
    return { status = "pending_out", request = serialize_social_row(existing) }
  end

  local request_id
  if existing then
    db.execute(
      SCHEMA,
      [[UPDATE account_friend_requests SET requester_account_id=%s, addressee_account_id=%s,
          status='pending', created_at=CURRENT_TIMESTAMP, responded_at=NULL WHERE id=%s]],
      requester_id, addressee_id, existing.id
    )
    request_id = existing.id
  else
    -- status/created_at set explicitly — see the schema-defaults note in
    -- set_account_follow() above.
    db.execute(
      SCHEMA,
      "INSERT INTO account_friend_requests (requester_account_id, addressee_account_id, status, created_at) VALUES (%s, %s, 'pending', CURRENT_TIMESTAMP)",
      requester_id, addressee_id
    )
  end

  local row = db.fetchone(
    SCHEMA,
    [[SELECT * FROM account_friend_requests
      WHERE (%s IS NULL OR id=%s) AND requester_account_id=%s AND addressee_account_id=%s
      ORDER BY id DESC LIMIT 1]],
    request_id, request_id, requester_id, addressee_id
  )
  return { status = "pending_out", request = serialize_social_row(row or {}) }
end

function M.list_account_friend_requests(account_id, mode)
  local own_col, other_col = "addressee_account_id", "requester_account_id"
  if mode == "outgoing" then own_col, other_col = "requester_account_id", "addressee_account_id" end
  local rows = db.fetchall(
    SCHEMA,
    string.format(
      [[SELECT fr.*, u.id AS user_id, u.username, u.guild_id, u.display_name, u.avatar_url, u.server_name, u.server_icon_url, u.public_profile, u.last_seen_at
        FROM account_friend_requests fr
        JOIN users u ON u.id = fr.%s
        WHERE fr.%s=%%s AND fr.status='pending'
        ORDER BY fr.created_at DESC LIMIT 100]],
      other_col, own_col
    ),
    coerce_int(account_id)
  )
  local out = {}
  for _, row in ipairs(rows) do out[#out + 1] = serialize_social_row(row) end
  return out
end

function M.respond_account_friend_request(account_id, request_id, action)
  local status_map = { accept = "accepted", decline = "declined", cancel = "cancelled" }
  local status = status_map[tostring(action or ""):lower()]
  if not status then error("Action must be accept, decline, or cancel.", 0) end
  local safe_request_id, safe_account_id = coerce_int(request_id), coerce_int(account_id)
  local where = (action == "cancel")
    and "id=%s AND requester_account_id=%s AND status='pending'"
    or "id=%s AND addressee_account_id=%s AND status='pending'"
  local row = db.fetchone(SCHEMA, "SELECT * FROM account_friend_requests WHERE " .. where, safe_request_id, safe_account_id)
  if not row then return nil end
  db.execute(SCHEMA, "UPDATE account_friend_requests SET status=%s, responded_at=CURRENT_TIMESTAMP WHERE id=%s", status, safe_request_id)
  row.status = status
  return serialize_social_row(row)
end

function M.list_account_friends(account_id)
  local aid = coerce_int(account_id)
  local rows = db.fetchall(
    SCHEMA,
    [[SELECT u.id, u.username, u.guild_id, u.display_name, u.avatar_url, u.bio, u.profile_headline, u.profile_tags,
             u.profile_links, u.profile_banner_url, u.profile_banner_mode, u.profile_card_style, u.profile_social_mode,
             u.server_name, u.server_icon_url, u.public_profile, u.last_seen_at, fr.responded_at AS friended_at
      FROM account_friend_requests fr
      JOIN users u ON u.id = CASE WHEN fr.requester_account_id=%s THEN fr.addressee_account_id ELSE fr.requester_account_id END
      WHERE fr.status='accepted' AND (fr.requester_account_id=%s OR fr.addressee_account_id=%s)
      ORDER BY fr.responded_at DESC, fr.created_at DESC LIMIT 200]],
    aid, aid, aid
  )
  local out = {}
  for _, row in ipairs(rows) do out[#out + 1] = accounts.serialize_profile(row) end
  return out
end

function M.send_account_message(sender_account_id, recipient_account_id, body)
  local sender_id, recipient_id = coerce_int(sender_account_id), coerce_int(recipient_account_id)
  if sender_id == recipient_id then error("You cannot message yourself.", 0) end
  local cleaned = tostring(body or ""):gsub("%s+", " "):match("^%s*(.-)%s*$")
  if cleaned == "" then error("Message cannot be empty.", 0) end
  if #cleaned > 2000 then error("Message must be 2000 characters or fewer.", 0) end
  if not accounts.get_account_by_id(recipient_id) then error("Account not found.", 0) end

  local inserted = db.fetchone(
    SCHEMA,
    [[INSERT INTO account_messages (sender_account_id, recipient_account_id, body, created_at) VALUES (%s, %s, %s, CURRENT_TIMESTAMP)
      RETURNING id]],
    sender_id, recipient_id, cleaned
  )
  local message = db.fetchone(
    SCHEMA,
    [[SELECT msg.*, u.username, u.guild_id, u.display_name, u.avatar_url, u.server_name, u.server_icon_url, u.public_profile, u.last_seen_at
      FROM account_messages msg JOIN users u ON u.id = msg.sender_account_id
      WHERE msg.id = %s LIMIT 1]],
    inserted.id
  )
  local item = serialize_social_row(message or {})
  item.mine = true
  return item
end

function M.list_account_message_threads(account_id)
  local aid = coerce_int(account_id)
  local rows = db.fetchall(
    SCHEMA,
    [[SELECT
        other_user.id, other_user.id AS account_id, other_user.username, other_user.guild_id,
        other_user.display_name, other_user.avatar_url, other_user.server_name, other_user.server_icon_url,
        other_user.public_profile, other_user.last_seen_at,
        latest.id AS last_message_id, latest.body AS last_message, latest.created_at AS last_message_at,
        latest.sender_account_id AS last_sender_account_id, unread.unread_count
      FROM (
        SELECT CASE WHEN sender_account_id=%s THEN recipient_account_id ELSE sender_account_id END AS other_id, MAX(id) AS last_id
        FROM account_messages WHERE sender_account_id=%s OR recipient_account_id=%s GROUP BY other_id
      ) threads
      JOIN account_messages latest ON latest.id = threads.last_id
      JOIN users other_user ON other_user.id = threads.other_id
      LEFT JOIN (
        SELECT sender_account_id AS other_id, COUNT(*) AS unread_count
        FROM account_messages WHERE recipient_account_id=%s AND read_at IS NULL GROUP BY sender_account_id
      ) unread ON unread.other_id = threads.other_id
      ORDER BY latest.created_at DESC LIMIT 100]],
    aid, aid, aid, aid
  )
  local out = {}
  for _, row in ipairs(rows) do out[#out + 1] = serialize_social_row(row) end
  return out
end

function M.list_account_messages(account_id, other_account_id, limit)
  local aid, oid = coerce_int(account_id), coerce_int(other_account_id)
  if aid == oid then error("Pick another account to view messages.", 0) end
  if not accounts.get_account_by_id(oid) then error("Account not found.", 0) end
  -- The open conversation is re-read every couple of seconds by the live
  -- push, so only issue the UPDATE (a write transaction) when there is
  -- actually something unread instead of on every refresh.
  local unread = db.fetchone(
    SCHEMA,
    "SELECT 1 AS present FROM account_messages WHERE sender_account_id=%s AND recipient_account_id=%s AND read_at IS NULL LIMIT 1",
    oid, aid
  )
  if unread then
    db.execute(
      SCHEMA,
      [[UPDATE account_messages SET read_at=COALESCE(read_at, CURRENT_TIMESTAMP)
        WHERE sender_account_id=%s AND recipient_account_id=%s AND read_at IS NULL]],
      oid, aid
    )
  end
  local safe_limit = math.max(1, math.min(tonumber(limit) or 80, 200))
  local rows = db.fetchall(
    SCHEMA,
    [[SELECT msg.*, u.username, u.guild_id, u.display_name, u.avatar_url, u.server_name, u.server_icon_url, u.public_profile, u.last_seen_at
      FROM account_messages msg JOIN users u ON u.id = msg.sender_account_id
      WHERE (msg.sender_account_id=%s AND msg.recipient_account_id=%s)
         OR (msg.sender_account_id=%s AND msg.recipient_account_id=%s)
      ORDER BY msg.created_at DESC, msg.id DESC LIMIT %s]],
    aid, oid, oid, aid, safe_limit
  )
  -- reverse to chronological order
  local out = {}
  for i = #rows, 1, -1 do
    local item = serialize_social_row(rows[i])
    item.mine = db.toint(item.sender_account_id) == aid
    out[#out + 1] = item
  end
  return out
end

-- Best-effort: mirrors create_notification.py's "never break the caller"
-- contract by swallowing failures instead of propagating them.
function M.create_notification(recipient_account_id, kind, title, body, link_path)
  pcall(db.execute,
    SCHEMA,
    [[INSERT INTO account_notifications (recipient_account_id, kind, title, body, link_path, created_at) VALUES (%s, %s, %s, %s, %s, CURRENT_TIMESTAMP)]],
    coerce_int(recipient_account_id), tostring(kind or ""):sub(1, 40), tostring(title or ""):sub(1, 200),
    body and tostring(body):sub(1, 500) or nil, link_path and tostring(link_path):sub(1, 200) or nil
  )
end

function M.list_notifications(account_id, limit)
  local safe_limit = math.max(1, math.min(tonumber(limit) or 30, 100))
  local rows = db.fetchall(
    SCHEMA,
    [[SELECT id, kind, title, body, link_path, read_at, created_at FROM account_notifications
      WHERE recipient_account_id = %s ORDER BY created_at DESC, id DESC LIMIT %s]],
    coerce_int(account_id), safe_limit
  )
  local out = {}
  for _, row in ipairs(rows) do out[#out + 1] = serialize_social_row(row) end
  return out
end

-- Badge counts for the Community section: unread direct messages and
-- pending incoming friend requests. Two COUNT(*)s, cheap enough for every
-- page's live socket to watch.
function M.community_counts(account_id)
  local aid = coerce_int(account_id)
  local row = db.fetchone(
    SCHEMA,
    [[SELECT
        (SELECT COUNT(*) FROM account_messages WHERE recipient_account_id = %s AND read_at IS NULL) AS unread_messages,
        (SELECT COUNT(*) FROM account_friend_requests WHERE addressee_account_id = %s AND status = 'pending') AS pending_requests]],
    aid, aid
  )
  return {
    unread_messages = db.toint(row and row.unread_messages, 0),
    pending_friend_requests = db.toint(row and row.pending_requests, 0),
  }
end

-- Indexes behind every hot social query: the live-push badges/threads/
-- notifications re-run these per connected account every few seconds, and
-- each one blocks the event loop for its full duration. IF NOT EXISTS makes
-- this a no-op after the first run, and each statement is pcall'd on its
-- own -- a panel that cannot create an index must still work, just slower
-- (same precedent as dashboard.lua's ensure_aria_dashboard_indexes).
local social_indexes_ready = false
function M.ensure_indexes()
  if social_indexes_ready then return end
  social_indexes_ready = true
  for _, stmt in ipairs({
    "CREATE INDEX IF NOT EXISTS account_messages_recipient_unread_idx ON account_messages (recipient_account_id, sender_account_id) WHERE read_at IS NULL",
    "CREATE INDEX IF NOT EXISTS account_messages_pair_idx ON account_messages (sender_account_id, recipient_account_id, created_at DESC, id DESC)",
    "CREATE INDEX IF NOT EXISTS account_messages_recipient_pair_idx ON account_messages (recipient_account_id, sender_account_id, id)",
    "CREATE INDEX IF NOT EXISTS account_friend_requests_addressee_status_idx ON account_friend_requests (addressee_account_id, status)",
    "CREATE INDEX IF NOT EXISTS account_friend_requests_requester_status_idx ON account_friend_requests (requester_account_id, status)",
    "CREATE INDEX IF NOT EXISTS account_follows_followed_idx ON account_follows (followed_account_id)",
    "CREATE INDEX IF NOT EXISTS account_notifications_recipient_created_idx ON account_notifications (recipient_account_id, created_at DESC, id DESC)",
    "CREATE INDEX IF NOT EXISTS account_notifications_recipient_unread_idx ON account_notifications (recipient_account_id) WHERE read_at IS NULL",
    "CREATE INDEX IF NOT EXISTS users_last_seen_idx ON users (last_seen_at DESC)",
  }) do
    local ok, done, err = pcall(db.execute, SCHEMA, stmt)
    if not ok or not done then print("[swarmpanel-lua] social index skipped: " .. tostring(ok and err or done)) end
  end
end

function M.unread_notification_count(account_id)
  local row = db.fetchone(SCHEMA, "SELECT COUNT(*) AS unread FROM account_notifications WHERE recipient_account_id = %s AND read_at IS NULL", coerce_int(account_id))
  return db.toint(row and row.unread, 0)
end

function M.mark_notification_read(notification_id, account_id)
  db.execute(
    SCHEMA,
    "UPDATE account_notifications SET read_at = COALESCE(read_at, CURRENT_TIMESTAMP) WHERE id = %s AND recipient_account_id = %s",
    coerce_int(notification_id), coerce_int(account_id)
  )
end

function M.mark_all_notifications_read(account_id)
  db.execute(SCHEMA, "UPDATE account_notifications SET read_at = COALESCE(read_at, CURRENT_TIMESTAMP) WHERE recipient_account_id = %s AND read_at IS NULL", coerce_int(account_id))
end

return M
