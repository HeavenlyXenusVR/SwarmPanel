-- "List of dicts -> CSV download" helper. Port of app/csv_export.py,
-- including its two security-relevant rules: sensitive-column stripping
-- (password/secret/token/api_key substrings, regardless of which
-- table/query produced the rows) and CSV-formula-injection escaping
-- (Excel/Sheets treat a leading =+-@ as a formula).
local M = {}

local SENSITIVE_MARKERS = { "password", "secret", "token", "api_key" }

local function is_sensitive_column(key)
  local lowered = tostring(key or ""):lower()
  for _, marker in ipairs(SENSITIVE_MARKERS) do
    if lowered:find(marker, 1, true) then return true end
  end
  return false
end

local function csv_cell(value)
  local text = (value == nil) and "" or tostring(value)
  local lead = text:sub(1, 1)
  if text ~= "" and (lead == "=" or lead == "+" or lead == "-" or lead == "@") then
    text = "'" .. text
  end
  -- RFC4180 quoting: always quote and double-up embedded quotes; simplest
  -- correct behavior regardless of whether the cell needs it.
  return '"' .. text:gsub('"', '""') .. '"'
end

function M.rows_to_csv_text(rows)
  local fieldnames, seen = {}, {}
  for _, row in ipairs(rows or {}) do
    for key in pairs(row) do
      if not seen[key] and not is_sensitive_column(key) then
        seen[key] = true
        fieldnames[#fieldnames + 1] = key
      end
    end
  end
  table.sort(fieldnames) -- Lua's pairs() has no stable order; sorted is deterministic (Python's dict-insertion order isn't reproducible here anyway)
  local lines = {}
  local header = {}
  for _, k in ipairs(fieldnames) do header[#header + 1] = csv_cell(k) end
  lines[#lines + 1] = table.concat(header, ",")
  for _, row in ipairs(rows or {}) do
    local cells = {}
    for _, k in ipairs(fieldnames) do cells[#cells + 1] = csv_cell(row[k]) end
    lines[#lines + 1] = table.concat(cells, ",")
  end
  return table.concat(lines, "\r\n") .. "\r\n"
end

local UNSAFE_FILENAME = "[^%w_.-]+"
function M.safe_filename(name)
  local cleaned = tostring(name or "export"):gsub(UNSAFE_FILENAME, "_"):gsub("^_+", ""):gsub("_+$", "")
  if cleaned == "" then cleaned = "export" end
  return cleaned:sub(1, 120)
end

-- Returns (status, body_string, headers) ready to hand back from an
-- httpd.route handler (httpd.lua passes non-table bodies through as-is and
-- respects any Content-Type override in the extra-headers table).
function M.csv_response(rows, filename)
  local body = M.rows_to_csv_text(rows)
  local headers = {
    ["Content-Type"] = "text/csv",
    ["Content-Disposition"] = string.format('attachment; filename="%s.csv"', M.safe_filename(filename)),
  }
  return 200, body, headers
end

return M
