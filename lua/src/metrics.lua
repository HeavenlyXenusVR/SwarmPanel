-- Fleet-wide stability/metrics snapshots and recent-event feeds. Port of
-- app/db/metrics.py + app/db/metrics_history.py's read paths.
--
-- NOT ported: capture_metrics_snapshot() (a periodic background sampler that
-- writes into accountlogins.swarm_metrics_history) — this rewrite has no
-- scheduler/background-task infrastructure yet (see final report). The table
-- already has real historical rows from whatever wrote them before this pass
-- (verified: 2982 existing rows), so get_metrics_history/get_metric_anomalies
-- below have real data to read even without a Lua-side writer.
local db = require("db")

local M = {}

function M.get_metrics_snapshot(music_bots)
  local bots, totals = {}, {
    bots = 0, guilds = 0, voice_connected = 0, playing = 0, paused = 0,
    queued_tracks = 0, backup_tracks = 0, recovering = 0, lavalink_ready = 0, stale_metrics = 0,
  }

  for _, bot in ipairs(music_bots) do
    local schema, prefix = bot.db_schema, bot.table_prefix
    local metrics, err = {}, nil
    local ok = pcall(function()
      local exists = db.batch_table_exists(schema, { prefix .. "_metrics", prefix .. "_voice_state" })
      if not exists[prefix .. "_metrics"] then return end
      local join_sql = exists[prefix .. "_voice_state"]
        and string.format("LEFT JOIN %s_voice_state v ON v.guild_id = m.guild_id AND v.bot_name = m.bot_name", prefix)
        or ""
      local voice_cols = exists[prefix .. "_voice_state"]
        and [[, v.last_channel_id, v.connected_channel_id AS voice_state_connected_channel_id,
               v.desired_connected, v.reconnect_attempts, v.last_error AS voice_last_error,
               EXTRACT(EPOCH FROM (NOW() - v.last_seen_at))::int AS voice_age_seconds]]
        or ""
      local rows = db.fetchall(
        schema,
        string.format(
          [[SELECT m.guild_id, m.voice_connected, m.connected_channel_id, m.player_connected,
                   m.player_playing, m.player_paused, m.queue_count, m.backup_queue_count,
                   m.is_playing_db, m.is_paused_db, m.position_seconds, m.recovery_pending,
                   m.lavalink_ready, m.last_error,
                   EXTRACT(EPOCH FROM (NOW() - m.updated_at))::int AS metrics_age_seconds
                   %s
            FROM %s_metrics m %s
            WHERE m.bot_name = %%s ORDER BY m.updated_at DESC LIMIT 200]],
          voice_cols, prefix, join_sql
        ),
        bot.key
      )
      for _, row in ipairs(rows) do
        local age = db.toint(row.metrics_age_seconds, 0)
        local stale = age > 45
        metrics[#metrics + 1] = {
          guild_id = tostring(row.guild_id),
          voice_connected = db.tobool(row.voice_connected),
          connected_channel_id = tostring(row.connected_channel_id or row.voice_state_connected_channel_id or ""),
          last_channel_id = tostring(row.last_channel_id or ""),
          desired_connected = db.tobool(row.desired_connected),
          player_connected = db.tobool(row.player_connected),
          player_playing = db.tobool(row.player_playing),
          player_paused = db.tobool(row.player_paused),
          queue_count = db.toint(row.queue_count, 0),
          backup_queue_count = db.toint(row.backup_queue_count, 0),
          is_playing_db = db.tobool(row.is_playing_db),
          is_paused_db = db.tobool(row.is_paused_db),
          position_seconds = db.toint(row.position_seconds, 0),
          recovery_pending = db.tobool(row.recovery_pending),
          lavalink_ready = db.tobool(row.lavalink_ready),
          reconnect_attempts = db.toint(row.reconnect_attempts, 0),
          metrics_age_seconds = age,
          voice_age_seconds = db.toint(row.voice_age_seconds, 0),
          stale = stale,
          last_error = row.last_error or row.voice_last_error,
        }
      end
    end)
    if not ok then err = "metrics query failed" end

    local status = "ok"
    if err then
      status = "error"
    else
      for _, m in ipairs(metrics) do
        if m.stale then status = "stale" break end
      end
    end
    bots[#bots + 1] = { key = bot.key, display_name = bot.display_name, schema = schema, metrics = metrics, error = err, status = status }

    totals.bots = totals.bots + 1
    for _, item in ipairs(metrics) do
      totals.guilds = totals.guilds + 1
      if item.voice_connected then totals.voice_connected = totals.voice_connected + 1 end
      if item.player_playing then totals.playing = totals.playing + 1 end
      if item.player_paused then totals.paused = totals.paused + 1 end
      totals.queued_tracks = totals.queued_tracks + item.queue_count
      totals.backup_tracks = totals.backup_tracks + item.backup_queue_count
      if item.recovery_pending then totals.recovering = totals.recovering + 1 end
      if item.lavalink_ready then totals.lavalink_ready = totals.lavalink_ready + 1 end
      if item.stale then totals.stale_metrics = totals.stale_metrics + 1 end
    end
  end

  return { generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"), totals = totals, bots = bots }
end

function M.record_metric_sample(metric_key, metric_value, guild_id)
  -- The live swarm_metrics_history table has no DEFAULT on captured_at
  -- (verified via information_schema.columns) -- an INSERT that omits it
  -- leaves the column NULL, and get_metrics_history()'s
  -- "captured_at > NOW() - interval" filter silently drops every NULL row,
  -- so the chart would stay empty forever even though rows were being
  -- written successfully. Set it explicitly instead of trusting a default
  -- that doesn't exist.
  local ok, err = pcall(db.execute,
    "accountlogins",
    "INSERT INTO swarm_metrics_history (captured_at, metric_key, metric_value, guild_id) VALUES (NOW(), %s, %s, %s)",
    tostring(metric_key):sub(1, 60), tonumber(metric_value) or 0, guild_id and tostring(guild_id) or nil
  )
  if not ok then print("[swarmpanel-lua] failed to record metric sample " .. tostring(metric_key) .. ": " .. tostring(err)) end
end

-- Port of app/db/metrics_history.py's capture_metrics_snapshot(): samples a
-- handful of key fleet totals into swarm_metrics_history so the Intel
-- page's trend charts/anomaly detection have real data to read. This was
-- explicitly NOT ported when the rest of metrics.lua's read paths were
-- (the Lua rewrite had no background-task scheduler yet, see the module
-- comment at the top of this file) -- swarm_metrics_history stopped
-- receiving new rows the moment the Python app was retired, so every
-- get_metrics_history()/get_metric_anomalies() call since has been
-- querying a table that can never have anything newer than that cutover.
function M.capture_metrics_snapshot(music_bots)
  local ok, snapshot = pcall(M.get_metrics_snapshot, music_bots)
  if not ok then
    print("[swarmpanel-lua] capture_metrics_snapshot: metrics snapshot unavailable: " .. tostring(snapshot))
    return
  end
  local totals = snapshot.totals or {}
  local samples = {
    active_bots = totals.bots, voice_connected = totals.voice_connected, playing = totals.playing,
    queued_tracks = totals.queued_tracks, backup_tracks = totals.backup_tracks,
    connected_guilds = totals.guilds, stale_metrics = totals.stale_metrics,
  }
  for key, value in pairs(samples) do
    if value ~= nil then M.record_metric_sample(key, value) end
  end
end

function M.get_stability_snapshot(music_bots)
  local metrics_result = {}
  pcall(function() metrics_result = M.get_metrics_snapshot(music_bots) end)
  local snapshot = { cooldowns = {}, recent_repairs = {}, metrics = metrics_result, status = "ok" }

  local ok1, cooldowns = pcall(db.fetchall, "discord_aria",
    [[SELECT scope_key, scope_type, guild_id, bot_name, reason,
             EXTRACT(EPOCH FROM (cooldown_until - NOW()))::int AS remaining_seconds,
             cooldown_until, updated_at
      FROM aria_swarm_recovery_cooldowns WHERE cooldown_until > NOW()
      ORDER BY cooldown_until DESC LIMIT 50]])
  if ok1 then snapshot.cooldowns = cooldowns else snapshot.cooldowns_error = tostring(cooldowns) end

  local ok2, repairs = pcall(db.fetchall, "discord_aria",
    [[SELECT issue_type, repair_action, repair_scope, success, confidence, details, error_text, created_at
      FROM aria_repair_journal ORDER BY created_at DESC LIMIT 50]])
  if ok2 then snapshot.recent_repairs = repairs else snapshot.repairs_error = tostring(repairs) end

  return snapshot
end

function M.get_recent_aria_medic_events(limit)
  local bounded = math.max(1, math.min(tonumber(limit) or 25, 50))
  local events = {}

  pcall(function()
    local rows = db.fetchall(
      "discord_aria",
      "SELECT event_type, bot_name, guild_id, severity, created_at FROM aria_swarm_events ORDER BY created_at DESC, id DESC LIMIT %s",
      bounded
    )
    for _, row in ipairs(rows) do
      local event_type = tostring(row.event_type or "aria_event")
      local bot_name = tostring(row.bot_name or "aria")
      local severity = tostring(row.severity or "info"):lower()
      local level = (severity == "critical" or severity == "error") and "error"
        or ((severity == "warning" or severity == "recoverable" or severity == "degraded") and "warning" or "info")
      local desc = event_type:gsub("_", " ")
      if bot_name ~= "" then desc = desc .. " | bot=" .. bot_name end
      if row.guild_id ~= nil and tostring(row.guild_id) ~= "" and tostring(row.guild_id) ~= "0" then
        desc = desc .. " | guild=" .. tostring(row.guild_id)
      end
      events[#events + 1] = {
        type = "aria_medic_event", level = level, title = "Aria Medic Event", description = desc,
        source = "aria", timestamp = row.created_at or os.date("!%Y-%m-%dT%H:%M:%SZ"),
      }
    end
  end)

  pcall(function()
    local n = math.max(3, math.min(10, math.floor(bounded / 2) + 1))
    local rows = db.fetchall(
      "discord_aria",
      "SELECT target_name, action_name, issue_type, success, execution_mode, created_at FROM aria_infra_history ORDER BY created_at DESC, id DESC LIMIT %s",
      n
    )
    for _, row in ipairs(rows) do
      local level = db.tobool(row.success) and "info" or (tostring(row.execution_mode or "") == "planned" and "warning" or "error")
      events[#events + 1] = {
        type = "aria_infra_event", level = level, title = "Aria Infra Action",
        description = string.format(
          "%s -> %s | %s | mode=%s",
          row.action_name or "action", row.target_name or "target", row.issue_type or "issue", row.execution_mode or "unknown"
        ),
        source = "aria", timestamp = row.created_at or os.date("!%Y-%m-%dT%H:%M:%SZ"),
      }
    end
  end)

  table.sort(events, function(a, b) return tostring(a.timestamp) < tostring(b.timestamp) end)
  local out = {}
  local start_idx = math.max(1, #events - bounded + 1)
  for i = start_idx, #events do out[#out + 1] = events[i] end
  return out
end

function M.get_recent_bot_error_events(music_bots, limit)
  local safe_limit = tonumber(limit) or 50
  local per_bot_limit = math.max(3, math.min(25, math.floor(safe_limit / math.max(#music_bots, 1)) + 2))
  local events = {}

  for _, bot in ipairs(music_bots) do
    local schema, prefix = bot.db_schema, bot.table_prefix
    if schema and prefix then
      pcall(function()
        local table_name = prefix .. "_error_events"
        if not db.table_exists(schema, table_name) then return end
        local rows = db.fetchall(
          schema,
          string.format(
            [[SELECT id, bot_name, guild_id, error_level, error_type, title, description, traceback_text, created_at
              FROM %s ORDER BY created_at DESC, id DESC LIMIT %%s]],
            table_name
          ),
          per_bot_limit
        )
        for _, row in ipairs(rows) do
          local description = tostring(row.description or ""):match("^%s*(.-)%s*$")
          local traceback_text = tostring(row.traceback_text or ""):match("^%s*(.-)%s*$")
          if traceback_text ~= "" then
            description = (description .. "\n\n" .. traceback_text):match("^%s*(.-)%s*$")
          end
          events[#events + 1] = {
            type = "bot_error",
            level = tostring(row.error_level or "error"):lower(),
            title = row.title or (bot.display_name .. " Error"),
            description = description,
            source = bot.key,
            timestamp = row.created_at or os.date("!%Y-%m-%dT%H:%M:%SZ"),
            bot_key = bot.key,
            guild_id = row.guild_id ~= nil and tostring(row.guild_id) or nil,
            error_type = row.error_type or "runtime",
          }
        end
      end)
    end
  end

  table.sort(events, function(a, b) return tostring(a.timestamp) < tostring(b.timestamp) end)
  local out = {}
  local cap = math.max(1, math.min(safe_limit, 100))
  local start_idx = math.max(1, #events - cap + 1)
  for i = start_idx, #events do out[#out + 1] = events[i] end
  return out
end

function M.get_metrics_history(metric, hours)
  local safe_hours = math.max(1, math.min(tonumber(hours) or 24, 24 * 30))
  return db.fetchall(
    "accountlogins",
    [[SELECT captured_at, metric_value, guild_id FROM swarm_metrics_history
      WHERE metric_key = %s AND captured_at > (NOW() AT TIME ZONE 'UTC' - (%s || ' hours')::interval)
      ORDER BY captured_at ASC]],
    tostring(metric):sub(1, 60), tostring(safe_hours)
  )
end

function M.get_metric_anomalies(metric, hours, z_threshold)
  z_threshold = z_threshold or 2.5
  local points = M.get_metrics_history(metric, hours)
  local values = {}
  for _, p in ipairs(points) do values[#values + 1] = tonumber(p.metric_value) or 0 end
  if #values < 5 then return {} end
  local sum = 0
  for _, v in ipairs(values) do sum = sum + v end
  local mean = sum / #values
  local var_sum = 0
  for _, v in ipairs(values) do var_sum = var_sum + (v - mean) ^ 2 end
  local stddev = math.sqrt(var_sum / #values)
  if stddev == 0 then return {} end
  local anomalies = {}
  for _, point in ipairs(points) do
    local value = tonumber(point.metric_value) or 0
    local z = math.abs(value - mean) / stddev
    if z > z_threshold then
      local out = {}
      for k, v in pairs(point) do out[k] = v end
      out.mean = math.floor(mean * 100 + 0.5) / 100
      out.z_score = math.floor(z * 100 + 0.5) / 100
      anomalies[#anomalies + 1] = out
    end
  end
  return anomalies
end

return M
