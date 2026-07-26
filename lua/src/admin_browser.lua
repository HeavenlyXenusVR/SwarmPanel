-- Generic database-browser methods: schema/table listing, table data
-- preview, and truncation. Port of app/db/admin_browser.py.
--
-- SQL-INJECTION NOTE (this is the part priority item 7 in the task
-- specifically flagged to watch for): every schema/table name that reaches
-- raw SQL text (not a %s-bound parameter — Postgres doesn't allow binding
-- identifiers as parameters at all) is run through validate_identifier()
-- first, an allowlist regex (`^[A-Za-z0-9_]+$`) ported byte-for-byte from
-- app/db/identifiers.py. That regex rejects quotes, dots, whitespace,
-- semicolons, comment markers — anything that could break out of the
-- identifier position. Table/column names for `SELECT * FROM <schema>.<table>`
-- and `UPDATE <table> SET <col> = %s` all go through this gate.
local db = require("db")
local config = require("config")

local M = {}

local IDENTIFIER_PATTERN = "^[%w_]+$"

function M.validate_identifier(value, field_name)
  value = tostring(value or ""):match("^%s*(.-)%s*$")
  if value == "" or not value:match(IDENTIFIER_PATTERN) then
    error("Invalid " .. (field_name or "identifier") .. ": " .. tostring(value), 0)
  end
  return value
end

-- "Schema" in the Python/MariaDB original means "one of the MySQL schemas
-- visible from a single connection". This Postgres port keeps one
-- connection PER DATABASE (see db.lua's module doc comment), so the
-- equivalent concept is "one of the swarm's known database names" — the
-- fixed set from config.lua, not a live `pg_database` scan (which would also
-- surface unrelated databases on the same Postgres server, e.g.
-- `image_upscaler`/`postgres`/`template0`, that aren't part of this panel's
-- domain and shouldn't be truncatable through this admin UI).
function M.list_schemas()
  local seen, out = {}, {}
  local function add(name)
    if name and name ~= "" and not seen[name] then
      seen[name] = true
      out[#out + 1] = name
    end
  end
  for _, bot in ipairs(config.all_bots or {}) do add(bot.db_schema) end
  add("accountlogins")
  add("discord_aria")
  add("image_gallery")
  table.sort(out)
  return out
end

function M.list_tables(schema)
  schema = M.validate_identifier(schema, "schema")
  local rows = db.fetchall(
    schema,
    [[SELECT c.relname AS table_name,
             COALESCE(c.reltuples, 0)::bigint AS estimated_rows
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relkind = 'r'
      ORDER BY c.relname]]
  )
  local out = {}
  for _, row in ipairs(rows) do
    -- Postgres sets pg_class.reltuples = -1 for a table that has never been
    -- ANALYZE'd (fresh/empty tables) — clamp to 0 rather than surfacing a
    -- confusing negative "row count" in the admin UI.
    out[#out + 1] = { table_name = row.table_name, estimated_rows = math.max(0, db.toint(row.estimated_rows, 0)) }
  end
  return out
end

local function json_value(v)
  return v -- pg.lua already returns text/bool/number in JSON-safe Lua forms; no bytea/datetime special-casing needed here (see get_table_data below for the one case that does need it: bytea).
end
M.json_row = function(row)
  local out = {}
  for k, v in pairs(row or {}) do out[k] = json_value(v) end
  return out
end

function M.get_table_data(schema, table_name, limit)
  schema = M.validate_identifier(schema, "schema")
  table_name = M.validate_identifier(table_name, "table")
  local safe_limit = math.max(1, math.min(tonumber(limit) or 100, 500))
  local rows = db.fetchall(schema, string.format('SELECT * FROM "%s" LIMIT %%s', table_name), safe_limit)
  local processed = {}
  for _, row in ipairs(rows) do
    local out = {}
    for k, v in pairs(row) do
      -- pgmoon returns bytea as a raw Lua string; there's no reliable way to
      -- tell "binary" from "text" apart post-hoc, so unlike the Python
      -- original (which gets a typed `bytes` object from aiomysql and can
      -- check `isinstance(val, bytes)`) this just passes strings through as-is.
      -- Not currently an issue for any table this browser is pointed at
      -- (no bytea columns in accountlogins/image_gallery/discord_* schemas).
      out[k] = v
    end
    processed[#processed + 1] = out
  end
  return { schema = schema, table = table_name, count = #processed, rows = processed }
end

function M.truncate_table(schema, table_name)
  schema = M.validate_identifier(schema, "schema")
  table_name = M.validate_identifier(table_name, "table")
  db.execute(schema, string.format('TRUNCATE TABLE "%s" CASCADE', table_name))
end

function M.truncate_schema(schema)
  schema = M.validate_identifier(schema, "schema")
  local tables = M.list_tables(schema)
  for _, t in ipairs(tables) do
    db.execute(schema, string.format('TRUNCATE TABLE "%s" CASCADE', M.validate_identifier(t.table_name, "table")))
  end
  local names = {}
  for _, t in ipairs(tables) do names[#names + 1] = t.table_name end
  return { schema = schema, truncated_tables = #tables, tables = names }
end

return M
