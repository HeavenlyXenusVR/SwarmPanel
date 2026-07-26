-- Image Gallery admin: user/comment/media/report management. Port of
-- app/db/gallery.py against the (separate) `image_gallery` Postgres database
-- — schema confirmed live via \d (users/media_items/media_comments/
-- media_reports/categories/media_collections/media_collection_items all
-- present with the expected columns).
local db = require("db")
local auth = require("auth")
local admin_browser = require("admin_browser")

local M = {}
local SCHEMA = "image_gallery"

local function normalize_email(value)
  local email = tostring(value or ""):match("^%s*(.-)%s*$"):lower()
  if email == "" then return nil end
  if #email > 255 or not email:match("^[^@%s]+@[^@%s]+%.[^@%s]+$") then
    error("Enter a valid email address.", 0)
  end
  return email
end

function M.get_image_gallery_admin_data(limit)
  local safe_limit = math.max(1, math.min(tonumber(limit) or 50, 200))
  local summary = { schema = SCHEMA }
  for _, spec in ipairs({
    { key = "users", table = "users" }, { key = "media", table = "media_items" },
    { key = "comments", table = "media_comments" }, { key = "collections", table = "media_collections" },
  }) do
    local row = db.fetchone(SCHEMA, "SELECT COUNT(*) AS count FROM " .. spec.table)
    summary[spec.key] = db.toint(row and row.count, 0)
  end
  local reports_open = db.fetchone(SCHEMA, "SELECT COUNT(*) AS count FROM media_reports WHERE status='open'")
  summary.reports_open = db.toint(reports_open and reports_open.count, 0)

  local users = db.fetchall(
    SCHEMA,
    [[SELECT u.id, u.username, u.display_name, u.email, u.email_verified_at,
             u.email_verification_sent_at, u.public_profile, u.show_liked_count,
             u.birthdate, u.age_verified_at, u.adult_content_consent,
             u.created_at, u.last_login_at,
             COUNT(DISTINCT m.id) AS media_count,
             COUNT(DISTINCT c.id) AS comment_count,
             COUNT(DISTINCT b.media_id) AS bookmark_count,
             COUNT(DISTINCT col.id) AS collection_count
      FROM users u
      LEFT JOIN media_items m ON m.user_id = u.id
      LEFT JOIN media_comments c ON c.user_id = u.id
      LEFT JOIN media_bookmarks b ON b.user_id = u.id
      LEFT JOIN media_collections col ON col.user_id = u.id
      GROUP BY u.id ORDER BY u.created_at DESC LIMIT %s]],
    safe_limit
  )

  local comments = db.fetchall(
    SCHEMA,
    [[SELECT c.id, c.media_id, c.user_id, c.body, c.created_at, u.username, u.display_name, m.title AS media_title
      FROM media_comments c JOIN users u ON u.id = c.user_id JOIN media_items m ON m.id = c.media_id
      ORDER BY c.created_at DESC LIMIT %s]],
    safe_limit
  )

  local media = db.fetchall(
    SCHEMA,
    [[SELECT m.id, m.user_id, m.title, m.media_kind, m.file_size, m.views, m.downloads,
             m.is_adult, m.moderation_status, m.moderation_reason, m.created_at, u.username
      FROM media_items m JOIN users u ON u.id = m.user_id
      ORDER BY m.created_at DESC LIMIT %s]],
    safe_limit
  )

  local reports = db.fetchall(
    SCHEMA,
    [[SELECT r.id, r.media_id, r.user_id, r.reason, r.details, r.status, r.created_at,
             u.username, u.display_name, m.title AS media_title
      FROM media_reports r JOIN users u ON u.id = r.user_id JOIN media_items m ON m.id = r.media_id
      ORDER BY CASE r.status WHEN 'open' THEN 0 WHEN 'reviewed' THEN 1 ELSE 2 END, r.created_at DESC
      LIMIT %s]],
    safe_limit
  )

  local categories = db.fetchall(
    SCHEMA,
    [[SELECT c.id, c.name, c.slug, c.media_kind, c.created_at, COUNT(m.id) AS media_count
      FROM categories c LEFT JOIN media_items m ON m.category_id = c.id
      GROUP BY c.id ORDER BY c.name ASC]]
  )

  local collections = db.fetchall(
    SCHEMA,
    [[SELECT col.id, col.user_id, col.name, col.is_public, col.created_at, u.username, COUNT(ci.media_id) AS item_count
      FROM media_collections col JOIN users u ON u.id = col.user_id
      LEFT JOIN media_collection_items ci ON ci.collection_id = col.id
      GROUP BY col.id ORDER BY col.created_at DESC LIMIT %s]],
    safe_limit
  )

  return {
    schema = SCHEMA, summary = summary, users = users, comments = comments,
    media = media, reports = reports, categories = categories, collections = collections,
  }
end

function M.get_image_gallery_user_admin(user_id)
  return db.fetchone(
    SCHEMA,
    [[SELECT id, username, display_name, email, email_verified_at, email_verification_sent_at,
             public_profile, show_liked_count, birthdate, age_verified_at, adult_content_consent,
             created_at, last_login_at
      FROM users WHERE id = %s LIMIT 1]],
    tostring(user_id)
  )
end

function M.delete_image_gallery_user(user_id)
  db.execute(SCHEMA, "DELETE FROM users WHERE id = %s", tostring(user_id))
end

function M.delete_image_gallery_comment(comment_id)
  db.execute(SCHEMA, "DELETE FROM media_comments WHERE id = %s", tostring(comment_id))
end

function M.reset_image_gallery_user_password(user_id, new_password)
  if #tostring(new_password or "") < 8 then error("Password must be at least 8 characters.", 0) end
  db.execute(SCHEMA, "UPDATE users SET password_hash = %s WHERE id = %s", auth.password_hash(new_password), tostring(user_id))
end

local USER_UPDATE_ALLOWED = { username = true, display_name = true, email = true, public_profile = true, show_liked_count = true, adult_content_consent = true }

function M.update_image_gallery_user(user_id, updates)
  updates = updates or {}
  local unknown = {}
  for key in pairs(updates) do
    if not USER_UPDATE_ALLOWED[key] then unknown[#unknown + 1] = key end
  end
  if #unknown > 0 then
    table.sort(unknown)
    error("Unsupported user fields: " .. table.concat(unknown, ", "), 0)
  end

  local cleaned = {}
  if updates.username ~= nil then
    local uname = tostring(updates.username or ""):match("^%s*(.-)%s*$"):sub(1, 40)
    if uname == "" then error("Username cannot be empty.", 0) end
    cleaned.username = uname
  end
  if updates.display_name ~= nil then
    local dn = tostring(updates.display_name or ""):match("^%s*(.-)%s*$"):sub(1, 80)
    cleaned.display_name = (dn ~= "") and dn or nil
  end
  local reset_email_verification = false
  if updates.email ~= nil then
    cleaned.email = normalize_email(updates.email)
    if cleaned.email then reset_email_verification = true end
  end
  for _, key in ipairs({ "public_profile", "show_liked_count", "adult_content_consent" }) do
    if updates[key] ~= nil then cleaned[key] = updates[key] and true or false end
  end

  local assignments, values = {}, {}
  for key, value in pairs(cleaned) do
    assignments[#assignments + 1] = admin_browser.validate_identifier(key, "gallery user column") .. " = %s"
    values[#values + 1] = value
  end
  if reset_email_verification then
    assignments[#assignments + 1] = "email_verified_at = NULL"
    assignments[#assignments + 1] = "email_verification_token_hash = NULL"
    assignments[#assignments + 1] = "email_verification_sent_at = NULL"
  end
  if #assignments > 0 then
    values[#values + 1] = tostring(user_id)
    db.execute(SCHEMA, "UPDATE users SET " .. table.concat(assignments, ", ") .. " WHERE id = %s", unpack(values))
  end
  return M.get_image_gallery_user_admin(user_id)
end

function M.set_image_gallery_email_verified(user_id, verified)
  local v = verified and true or false
  db.execute(
    SCHEMA,
    [[UPDATE users SET
        email_verified_at = CASE WHEN %s THEN CURRENT_TIMESTAMP ELSE NULL END,
        email_verification_token_hash = CASE WHEN %s THEN NULL ELSE email_verification_token_hash END
      WHERE id = %s]],
    v, v, tostring(user_id)
  )
  return M.get_image_gallery_user_admin(user_id)
end

function M.set_image_gallery_age_verified(user_id, verified)
  local v = verified and true or false
  db.execute(
    SCHEMA,
    [[UPDATE users SET age_verified_at = CASE WHEN %s THEN CURRENT_TIMESTAMP ELSE NULL END, adult_content_consent = %s WHERE id = %s]],
    v, v, tostring(user_id)
  )
  return M.get_image_gallery_user_admin(user_id)
end

-- Takes an ALREADY-HASHED token (routes.lua generates the raw token, hashes
-- it via auth.verification_token_hash(), and keeps the raw value only long
-- enough to build the verify_url + email body via notify.lua's real SMTP
-- send — see the /api/image-gallery/users/resend-verification route).
function M.issue_image_gallery_email_verification_token(user_id, token_hash)
  db.execute(
    SCHEMA,
    [[UPDATE users SET email_verification_token_hash = %s, email_verification_sent_at = CURRENT_TIMESTAMP
      WHERE id = %s AND email IS NOT NULL AND email_verified_at IS NULL]],
    token_hash, tostring(user_id)
  )
  return M.get_image_gallery_user_admin(user_id)
end

local MEDIA_UPDATE_ALLOWED = { title = true, is_adult = true, moderation_status = true, moderation_reason = true }
local VALID_MODERATION_STATUSES = { clear = true, review = true, blocked = true }

function M.update_image_gallery_media(media_id, updates)
  updates = updates or {}
  local unknown = {}
  for key in pairs(updates) do
    if not MEDIA_UPDATE_ALLOWED[key] then unknown[#unknown + 1] = key end
  end
  if #unknown > 0 then
    table.sort(unknown)
    error("Unsupported media fields: " .. table.concat(unknown, ", "), 0)
  end

  local cleaned = {}
  if updates.title ~= nil then
    local title = tostring(updates.title or ""):match("^%s*(.-)%s*$"):sub(1, 160)
    if title == "" then error("Media title cannot be empty.", 0) end
    cleaned.title = title
  end
  if updates.is_adult ~= nil then
    cleaned.is_adult = updates.is_adult and true or false
    cleaned.adult_marked_by_user = cleaned.is_adult
  end
  if updates.moderation_status ~= nil then
    local status = tostring(updates.moderation_status or ""):lower():match("^%s*(.-)%s*$")
    if not VALID_MODERATION_STATUSES[status] then error("Moderation status must be clear, review, or blocked.", 0) end
    cleaned.moderation_status = status
  end
  if updates.moderation_reason ~= nil then
    local reason = tostring(updates.moderation_reason or ""):match("^%s*(.-)%s*$"):sub(1, 300)
    cleaned.moderation_reason = (reason ~= "") and reason or nil
  end

  if next(cleaned) ~= nil then
    local assignments, values = {}, {}
    for key, value in pairs(cleaned) do
      assignments[#assignments + 1] = admin_browser.validate_identifier(key, "gallery media column") .. " = %s"
      values[#values + 1] = value
    end
    values[#values + 1] = tostring(media_id)
    db.execute(SCHEMA, "UPDATE media_items SET " .. table.concat(assignments, ", ") .. ", moderated_at = CURRENT_TIMESTAMP WHERE id = %s", unpack(values))
  end
  return db.fetchone(SCHEMA, "SELECT * FROM media_items WHERE id = %s", tostring(media_id))
end

function M.delete_image_gallery_media(media_id)
  db.execute(SCHEMA, "DELETE FROM media_items WHERE id = %s", tostring(media_id))
end

function M.update_image_gallery_report_status(report_id, status)
  status = tostring(status or ""):lower():match("^%s*(.-)%s*$")
  if status ~= "open" and status ~= "reviewed" and status ~= "dismissed" then
    error("Report status must be open, reviewed, or dismissed.", 0)
  end
  db.execute(SCHEMA, "UPDATE media_reports SET status = %s WHERE id = %s", status, tostring(report_id))
end

return M
