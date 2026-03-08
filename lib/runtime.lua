-- SPDX-FileCopyrightText: 2026 Mateo Paredes Sepulveda
-- SPDX-License-Identifier: GPL-3.0-or-later

local util = require "util"
local tabutil = require "tabutil"

local MOD_NAME = "nagatomo"
local OSC_PATHS = {
  connection = "/toga_connection",
  grid_prefix = "/togagrid/",
  arc_prefix = "/togaarc/",
}

local runtime = {
  data_dir = tostring(_path.data) .. MOD_NAME .. "/",
  prefs_fn = tostring(_path.data) .. MOD_NAME .. "/prefs.lua",
  clients_fn = tostring(_path.data) .. MOD_NAME .. "/clients.lua",
}

local GRID_PORTS = 4
local GRID_COLS = 16
local GRID_ROWS = 8
local ARC_PORTS = 4
local ARC_COLS = 4
local ARC_ROWS = 64
local SENT_UNKNOWN = -1

local POLICY_ORDER = { "auto", "touchosc", "mirror" }
local POLICY_LABELS = {
  auto = "Auto",
  touchosc = "TouchOSC Only",
  mirror = "Mirror Both",
}

local core = {
  grid = grid,
  arc = arc,
  osc = osc,
  norns_grid_add = _norns.grid.add,
  norns_grid_remove = _norns.grid.remove,
  norns_grid_key = _norns.grid.key,
  norns_grid_tilt = _norns.grid.tilt,
  norns_arc_add = _norns.arc.add,
  norns_arc_remove = _norns.arc.remove,
  norns_arc_key = _norns.arc.key,
  norns_arc_delta = _norns.arc.delta,
  norns_osc_event = _norns.osc.event,
}
runtime.prefs = {
  grid_policy = "auto",
  arc_policy = "auto",
  retry_writes_enabled = false,
}
runtime.clients = {}
runtime.client_order = {}
runtime.grid_virtual = {
  id = -1,
  serial = "touchosc",
  name = "TouchOSC Grid",
  cols = GRID_COLS,
  rows = GRID_ROWS,
  port = 1,
}
runtime.arc_virtual = {
  id = -1,
  serial = "touchosc",
  name = "TouchOSC Arc",
  port = 1,
}
runtime.installed = false
runtime.menu_redraw = nil

local function create_buffer(width, height, initial)
  initial = initial or 0
  local buffer = {}
  for x = 1, width do
    buffer[x] = {}
    for y = 1, height do
      buffer[x][y] = initial
    end
  end
  return buffer
end

runtime.grid_state = {
  current = create_buffer(GRID_COLS, GRID_ROWS, 0),
  retry_pending = create_buffer(GRID_COLS, GRID_ROWS, false),
}

runtime.arc_state = {
  current = create_buffer(ARC_COLS, ARC_ROWS, 0),
  retry_pending = create_buffer(ARC_COLS, ARC_ROWS, false),
}

local function ensure_dir(path)
  if not util.file_exists(path) then
    util.make_dir(path)
  end
end

local function mark_dirty()
  if runtime.menu_redraw then
    pcall(runtime.menu_redraw)
  end
end

local function now_s()
  return util.time()
end

local grid_touchosc_enabled
local arc_touchosc_enabled

local function client_key(host, port)
  return tostring(host) .. ":" .. tostring(port)
end

local function normalize_from(from)
  local host = from and from[1] or "unknown"
  local port = tonumber(from and from[2]) or tostring(from and from[2] or "0")
  return host, port
end

local function reset_client_transient(client)
  client.grid_sent = create_buffer(GRID_COLS, GRID_ROWS, SENT_UNKNOWN)
  client.arc_sent = create_buffer(ARC_COLS, ARC_ROWS, SENT_UNKNOWN)
  client.arc_encoder_pos = {}
  for ring = 1, ARC_COLS do
    client.arc_encoder_pos[ring] = SENT_UNKNOWN
  end
end

local function make_client(host, port, last_seen, active)
  local key = client_key(host, port)
  local client = {
    key = key,
    host = host,
    port = port,
    last_seen = tonumber(last_seen) or 0,
    active = active == true,
  }
  reset_client_transient(client)
  return client
end

local function client_is_active(client)
  return client ~= nil and client.active == true
end

local function snapshot_client(client)
  return {
    host = client.host,
    port = client.port,
    last_seen = client.last_seen,
  }
end

local function save_clients()
  ensure_dir(runtime.data_dir)
  local saved = {}
  for _, key in ipairs(runtime.client_order) do
    local client = runtime.clients[key]
    if client then
      table.insert(saved, snapshot_client(client))
    end
  end
  tabutil.save(saved, runtime.clients_fn)
end

local function load_clients()
  runtime.clients = {}
  runtime.client_order = {}

  if not util.file_exists(runtime.clients_fn) then
    return
  end

  local ok, saved = pcall(tabutil.load, runtime.clients_fn)
  if not ok or type(saved) ~= "table" then
    return
  end

  for _, entry in ipairs(saved) do
    if type(entry) == "table" and entry.host and entry.port then
      local client = make_client(
        entry.host,
        entry.port,
        entry.last_seen,
        false
      )
      runtime.clients[client.key] = client
      table.insert(runtime.client_order, client.key)
    end
  end
end

local function save_prefs()
  ensure_dir(runtime.data_dir)
  tabutil.save({
    grid_policy = runtime.prefs.grid_policy,
    arc_policy = runtime.prefs.arc_policy,
    retry_writes_enabled = runtime.prefs.retry_writes_enabled,
  }, runtime.prefs_fn)
end

local function load_prefs()
  if not util.file_exists(runtime.prefs_fn) then
    save_prefs()
    return
  end

  local ok, saved = pcall(tabutil.load, runtime.prefs_fn)
  if not ok or type(saved) ~= "table" then
    return
  end

  if POLICY_LABELS[saved.grid_policy] then
    runtime.prefs.grid_policy = saved.grid_policy
  end
  if POLICY_LABELS[saved.arc_policy] then
    runtime.prefs.arc_policy = saved.arc_policy
  end
  if type(saved.retry_writes_enabled) == "boolean" then
    runtime.prefs.retry_writes_enabled = saved.retry_writes_enabled
  elseif type(saved.scrub_enabled) == "boolean" then
    runtime.prefs.retry_writes_enabled = saved.scrub_enabled
  end
end

local function default_grid_name(port)
  if port == 1 then
    return runtime.grid_virtual.name
  end
  return "none"
end

local function default_arc_name(port)
  if port == 1 then
    return runtime.arc_virtual.name
  end
  return "none"
end

local function grid_has_physical(port)
  local vport = core.grid.vports[port]
  return vport ~= nil and vport.device ~= nil
end

local function arc_has_physical(port)
  local vport = core.arc.vports[port]
  return vport ~= nil and vport.device ~= nil
end

local function active_client_count()
  local count = 0
  for _, client in pairs(runtime.clients) do
    if client_is_active(client) then
      count = count + 1
    end
  end
  return count
end

local function clear_grid_retry_pending()
  for y = 1, GRID_ROWS do
    for x = 1, GRID_COLS do
      runtime.grid_state.retry_pending[x][y] = false
    end
  end
end

local function clear_arc_retry_pending()
  for ring = 1, ARC_COLS do
    for led = 1, ARC_ROWS do
      runtime.arc_state.retry_pending[ring][led] = false
    end
  end
end

grid_touchosc_enabled = function(port)
  local policy = runtime.prefs.grid_policy
  if port ~= 1 then
    return false
  end
  if policy == "touchosc" or policy == "mirror" then
    return true
  end
  return not grid_has_physical(port)
end

local function grid_physical_enabled(port)
  if runtime.prefs.grid_policy == "touchosc" then
    return false
  end
  return grid_has_physical(port)
end

arc_touchosc_enabled = function(port)
  local policy = runtime.prefs.arc_policy
  if port ~= 1 then
    return false
  end
  if policy == "touchosc" or policy == "mirror" then
    return true
  end
  return not arc_has_physical(port)
end

local function arc_physical_enabled(port)
  if runtime.prefs.arc_policy == "touchosc" then
    return false
  end
  return arc_has_physical(port)
end

local function grid_port_mode(port)
  if port ~= 1 then
    return grid_has_physical(port) and "physical" or "none"
  end
  if runtime.prefs.grid_policy == "touchosc" then
    return "virtual"
  end
  if grid_has_physical(port) then
    return "physical"
  end
  return "virtual"
end

local function arc_port_mode(port)
  if port ~= 1 then
    return arc_has_physical(port) and "physical" or "none"
  end
  if runtime.prefs.arc_policy == "touchosc" then
    return "virtual"
  end
  if arc_has_physical(port) then
    return "physical"
  end
  return "virtual"
end

local function current_grid_device(port)
  local mode = grid_port_mode(port)
  if mode == "physical" then
    return core.grid.vports[port].device
  end
  if mode == "virtual" then
    return runtime.grid_virtual
  end
  return nil
end

local function current_arc_device(port)
  local mode = arc_port_mode(port)
  if mode == "physical" then
    return core.arc.vports[port].device
  end
  if mode == "virtual" then
    return runtime.arc_virtual
  end
  return nil
end

local function grid_port_name(port)
  local mode = grid_port_mode(port)
  if mode == "physical" then
    return core.grid.vports[port].name
  end
  if mode == "virtual" then
    return default_grid_name(port)
  end
  return "none"
end

local function grid_port_cols(port)
  local mode = grid_port_mode(port)
  if mode == "physical" then
    return core.grid.vports[port].cols
  end
  if mode == "virtual" then
    return GRID_COLS
  end
  return 0
end

local function grid_port_rows(port)
  local mode = grid_port_mode(port)
  if mode == "physical" then
    return core.grid.vports[port].rows
  end
  if mode == "virtual" then
    return GRID_ROWS
  end
  return 0
end

local function arc_port_name(port)
  local mode = arc_port_mode(port)
  if mode == "physical" then
    return core.arc.vports[port].name
  end
  if mode == "virtual" then
    return default_arc_name(port)
  end
  return "none"
end

local function refresh_grid_port(port)
  local vport = runtime.grid_vports[port]
  vport.name = grid_port_name(port)
  vport.cols = grid_port_cols(port)
  vport.rows = grid_port_rows(port)
  vport.device = current_grid_device(port)
end

local function refresh_arc_port(port)
  local vport = runtime.arc_vports[port]
  vport.name = arc_port_name(port)
  vport.device = current_arc_device(port)
end

function runtime.refresh_ports()
  for port = 1, GRID_PORTS do
    refresh_grid_port(port)
  end
  for port = 1, ARC_PORTS do
    refresh_arc_port(port)
  end
end

local function list_clients(filter)
  local list = {}
  for _, key in ipairs(runtime.client_order) do
    local client = runtime.clients[key]
    if client and filter(client) then
      table.insert(list, client)
    end
  end
  table.sort(list, function(a, b)
    return (a.last_seen or 0) > (b.last_seen or 0)
  end)
  return list
end

function runtime.active_clients()
  return list_clients(function(client)
    return client_is_active(client)
  end)
end

function runtime.saved_clients()
  return list_clients(function(client)
    return not client_is_active(client)
  end)
end

local function ensure_client(from)
  local host, port = normalize_from(from)
  local key = client_key(host, port)
  local client = runtime.clients[key]
  local created = false
  local reactivated = false

  if client == nil then
    created = true
    client = make_client(host, port, now_s(), true)
    runtime.clients[key] = client
    table.insert(runtime.client_order, key)
  else
    reactivated = not client_is_active(client)
    client.active = true
    client.last_seen = now_s()
    if reactivated then
      reset_client_transient(client)
    end
  end

  if created then
    save_clients()
  end

  mark_dirty()
  return client, created, reactivated
end

local function send_osc(client, path, args)
  core.osc.send({ client.host, client.port }, path, args)
end

local function send_connected(client, connected)
  send_osc(client, OSC_PATHS.connection, { connected and 1.0 or 0.0 })
end

local function send_grid_led(client, x, y, level)
  local index = x + (y - 1) * GRID_COLS
  send_osc(client, string.format("%s%d", OSC_PATHS.grid_prefix, index), { level / 15.0 })
end

local function send_arc_led(client, ring, led, level)
  for group = 1, 2 do
    send_osc(client, string.format("%sknob%d/group%d/button%d", OSC_PATHS.arc_prefix, ring, group, led), { level / 15.0 })
  end
end

local function send_grid_state(force, target_client, retry_only)
  if not grid_touchosc_enabled(1) then
    return
  end

  local clients = target_client and { target_client } or runtime.active_clients()
  for _, client in ipairs(clients) do
    for y = 1, GRID_ROWS do
      for x = 1, GRID_COLS do
        local current = runtime.grid_state.current[x][y]
        local pending_retry = runtime.grid_state.retry_pending[x][y] == true
        if force or (retry_only and pending_retry) or (not retry_only and client.grid_sent[x][y] ~= current) then
          send_grid_led(client, x, y, current)
          client.grid_sent[x][y] = current
        end
      end
    end
  end
end

local function send_arc_state(force, target_client, retry_only)
  if not arc_touchosc_enabled(1) then
    return
  end

  local clients = target_client and { target_client } or runtime.active_clients()
  for _, client in ipairs(clients) do
    for ring = 1, ARC_COLS do
      for led = 1, ARC_ROWS do
        local current = runtime.arc_state.current[ring][led]
        local pending_retry = runtime.arc_state.retry_pending[ring][led] == true
        if force or (retry_only and pending_retry) or (not retry_only and client.arc_sent[ring][led] ~= current) then
          send_arc_led(client, ring, led, current)
          client.arc_sent[ring][led] = current
        end
      end
    end
  end
end

function runtime.resend_state(target_client, include_connected)
  local clients = target_client and { target_client } or runtime.active_clients()
  for _, client in ipairs(clients) do
    if include_connected ~= false then
      send_connected(client, true)
    end
    send_grid_state(true, client)
    send_arc_state(true, client)
  end
  mark_dirty()
end

local function age_string(timestamp)
  if not timestamp or timestamp <= 0 then
    return "never"
  end

  local age = math.max(0, math.floor(now_s() - timestamp))
  if age < 1 then
    return "now"
  end
  if age < 60 then
    return age .. "s"
  end
  if age < 3600 then
    return math.floor(age / 60) .. "m"
  end
  return math.floor(age / 3600) .. "h"
end

function runtime.describe_client(client)
  local state = client_is_active(client) and "active" or "saved"
  return string.format("%s:%s %s %s", client.host, tostring(client.port), state, age_string(client.last_seen))
end

function runtime.status()
  local active_clients = runtime.active_clients()
  local saved_clients = runtime.saved_clients()
  return {
    grid_policy = POLICY_LABELS[runtime.prefs.grid_policy],
    arc_policy = POLICY_LABELS[runtime.prefs.arc_policy],
    retry_writes_enabled = runtime.prefs.retry_writes_enabled,
    active_clients = active_clients,
    saved_clients = saved_clients,
    grid_bound = runtime.grid_vports[1].key ~= nil or runtime.grid_vports[1].tilt ~= nil,
    arc_bound = runtime.arc_vports[1].key ~= nil or runtime.arc_vports[1].delta ~= nil,
    script_name = norns.state.name,
    total_active = #active_clients,
  }
end

local function cycle_policy(kind, direction)
  local current = runtime.prefs[kind]
  local index = 1
  for i, name in ipairs(POLICY_ORDER) do
    if name == current then
      index = i
      break
    end
  end
  if direction and direction < 0 then
    index = ((index - 2 + #POLICY_ORDER) % #POLICY_ORDER) + 1
  else
    index = (index % #POLICY_ORDER) + 1
  end
  runtime.prefs[kind] = POLICY_ORDER[index]
  save_prefs()
  runtime.refresh_ports()
  runtime.resend_state(nil, false)
  print(string.format("[nagatomo] %s policy -> %s", kind, POLICY_LABELS[runtime.prefs[kind]]))
end

function runtime.cycle_grid_policy(direction)
  cycle_policy("grid_policy", direction)
end

function runtime.cycle_arc_policy(direction)
  cycle_policy("arc_policy", direction)
end

function runtime.toggle_retry_writes()
  runtime.prefs.retry_writes_enabled = not runtime.prefs.retry_writes_enabled
  if not runtime.prefs.retry_writes_enabled then
    clear_grid_retry_pending()
    clear_arc_retry_pending()
  end
  save_prefs()
  print(string.format("[nagatomo] retry writes -> %s", runtime.prefs.retry_writes_enabled and "on" or "off"))
  mark_dirty()
end

function runtime.disconnect_all_clients()
  for _, client in pairs(runtime.clients) do
    if client.active then
      send_connected(client, false)
      client.active = false
      reset_client_transient(client)
    end
  end
  clear_grid_retry_pending()
  clear_arc_retry_pending()
  print("[nagatomo] disconnected all active clients")
  mark_dirty()
end

local function reset_grid_state(level)
  for y = 1, GRID_ROWS do
    for x = 1, GRID_COLS do
      runtime.grid_state.current[x][y] = level
      runtime.grid_state.retry_pending[x][y] = false
    end
  end
end

local function reset_arc_state(level)
  for ring = 1, ARC_COLS do
    for led = 1, ARC_ROWS do
      runtime.arc_state.current[ring][led] = level
      runtime.arc_state.retry_pending[ring][led] = false
    end
  end
end

local function apply_level(current, level, rel)
  if rel then
    return util.clamp(current + level, 0, 15)
  end
  return util.clamp(level, 0, 15)
end

local function set_grid_current(x, y, level, mark_retry)
  if x < 1 or x > GRID_COLS or y < 1 or y > GRID_ROWS then
    return false
  end
  if runtime.grid_state.current[x][y] == level then
    if mark_retry then
      runtime.grid_state.retry_pending[x][y] = true
    end
    return false
  end
  runtime.grid_state.current[x][y] = level
  runtime.grid_state.retry_pending[x][y] = mark_retry == true
  return true
end

local function set_arc_current(ring, led, level, mark_retry)
  if ring < 1 or ring > ARC_COLS or led < 1 or led > ARC_ROWS then
    return false
  end
  if runtime.arc_state.current[ring][led] == level then
    if mark_retry then
      runtime.arc_state.retry_pending[ring][led] = true
    end
    return false
  end
  runtime.arc_state.current[ring][led] = level
  runtime.arc_state.retry_pending[ring][led] = mark_retry == true
  return true
end

function runtime.grid_led(port, x, y, level, rel)
  level = math.floor(level or 0)
  if port == 1 then
    local current = runtime.grid_state.current[x] and runtime.grid_state.current[x][y]
    if current ~= nil then
      local next_level = apply_level(current, level, rel)
      set_grid_current(x, y, next_level, runtime.prefs.retry_writes_enabled)
    end
  end
  if grid_physical_enabled(port) then
    core.grid.vports[port]:led(x, y, rel and level or util.clamp(level, 0, 15), rel)
  end
end

function runtime.grid_all(port, level, rel)
  level = math.floor(level or 0)
  if port == 1 then
    for y = 1, GRID_ROWS do
      for x = 1, GRID_COLS do
        local next_level = apply_level(runtime.grid_state.current[x][y], level, rel)
        set_grid_current(x, y, next_level, runtime.prefs.retry_writes_enabled)
      end
    end
  end
  if grid_physical_enabled(port) then
    core.grid.vports[port]:all(rel and level or util.clamp(level, 0, 15), rel)
  end
end

function runtime.grid_refresh(port, force)
  if port == 1 then
    send_grid_state(force == true)
    if force == true then
      clear_grid_retry_pending()
    elseif runtime.prefs.retry_writes_enabled then
      send_grid_state(false, nil, true)
      clear_grid_retry_pending()
    end
  end
  if grid_physical_enabled(port) then
    core.grid.vports[port]:refresh()
  end
end

function runtime.grid_rotation(port, value)
  if grid_physical_enabled(port) then
    core.grid.vports[port]:rotation(value)
  end
end

function runtime.grid_intensity(port, value)
  if grid_physical_enabled(port) then
    core.grid.vports[port]:intensity(value)
  end
end

function runtime.grid_tilt_enable(port, id, value)
  if grid_physical_enabled(port) then
    core.grid.vports[port]:tilt_enable(id, value)
  end
end

function runtime.arc_led(port, ring, led, level, rel)
  level = math.floor(level or 0)
  if port == 1 then
    local current = runtime.arc_state.current[ring] and runtime.arc_state.current[ring][led]
    if current ~= nil then
      local next_level = apply_level(current, level, rel)
      set_arc_current(ring, led, next_level, runtime.prefs.retry_writes_enabled)
    end
  end
  if arc_physical_enabled(port) then
    core.arc.vports[port]:led(ring, led, rel and level or util.clamp(level, 0, 15), rel)
  end
end

function runtime.arc_all(port, level, rel)
  level = math.floor(level or 0)
  if port == 1 then
    for ring = 1, ARC_COLS do
      for led = 1, ARC_ROWS do
        local next_level = apply_level(runtime.arc_state.current[ring][led], level, rel)
        set_arc_current(ring, led, next_level, runtime.prefs.retry_writes_enabled)
      end
    end
  end
  if arc_physical_enabled(port) then
    core.arc.vports[port]:all(rel and level or util.clamp(level, 0, 15), rel)
  end
end

function runtime.arc_segment(port, ring, from_angle, to_angle, level, rel)
  local tau = math.pi * 2

  local function overlap(a, b, c, d)
    if a > b then
      return overlap(a, tau, c, d) + overlap(0, b, c, d)
    elseif c > d then
      return overlap(a, b, c, tau) + overlap(a, b, 0, d)
    end
    return math.max(0, math.min(b, d) - math.max(a, c))
  end

  local function overlap_segments(a, b, c, d)
    a = a % tau
    b = b % tau
    c = c % tau
    d = d % tau
    return overlap(a, b, c, d)
  end

  local step = tau / ARC_ROWS
  level = math.floor(level or 0)
  for led = 1, ARC_ROWS do
    local sa = step * (led - 1)
    local sb = step * led
    local amount = overlap_segments(from_angle, to_angle, sa, sb)
    local brightness = util.round(amount / step * level)
    if port == 1 then
      local current = runtime.arc_state.current[ring] and runtime.arc_state.current[ring][led]
      if current ~= nil then
        local next_level = apply_level(current, brightness, rel)
        set_arc_current(ring, led, next_level, runtime.prefs.retry_writes_enabled)
      end
    end
    if arc_physical_enabled(port) then
      core.arc.vports[port]:led(ring, led, rel and brightness or util.clamp(brightness, 0, 15), rel)
    end
  end
end

function runtime.arc_refresh(port, force)
  if port == 1 then
    send_arc_state(force == true)
    if force == true then
      clear_arc_retry_pending()
    elseif runtime.prefs.retry_writes_enabled then
      send_arc_state(false, nil, true)
      clear_arc_retry_pending()
    end
  end
  if arc_physical_enabled(port) then
    core.arc.vports[port]:refresh()
  end
end

function runtime.arc_intensity(port, value)
  if arc_physical_enabled(port) then
    core.arc.vports[port]:intensity(value)
  end
end

function runtime.grid_cleanup()
  runtime.grid_api.add = nil
  runtime.grid_api.remove = nil
  for port = 1, GRID_PORTS do
    local vport = runtime.grid_vports[port]
    vport.key = nil
    vport.tilt = nil
    vport.remove = nil
  end
  core.grid.cleanup()
  reset_grid_state(0)
  if active_client_count() > 0 and grid_touchosc_enabled(1) then
    send_grid_state(true)
  end
  runtime.refresh_ports()
  mark_dirty()
end

function runtime.arc_cleanup()
  runtime.arc_api.add = nil
  runtime.arc_api.remove = nil
  for port = 1, ARC_PORTS do
    local vport = runtime.arc_vports[port]
    vport.key = nil
    vport.delta = nil
    vport.remove = nil
  end
  core.arc.cleanup()
  reset_arc_state(0)
  if active_client_count() > 0 and arc_touchosc_enabled(1) then
    send_arc_state(true)
  end
  runtime.refresh_ports()
  mark_dirty()
end

local function parse_grid_press(path, args)
  local index = tonumber(path:match("^" .. OSC_PATHS.grid_prefix .. "(%d+)$"))
  if index == nil or index < 1 or index > (GRID_COLS * GRID_ROWS) then
    return nil
  end

  local x = ((index - 1) % GRID_COLS) + 1
  local y = math.floor((index - 1) / GRID_COLS) + 1
  local z = (tonumber(args[1]) or 0) > 0 and 1 or 0
  return x, y, z
end

local function handle_grid_press(client, args, path)
  local x, y, z = parse_grid_press(path, args)
  if x == nil then
    return false
  end

  if grid_touchosc_enabled(1) and runtime.grid_vports[1].key then
    runtime.grid_vports[1].key(x, y, z)
  end
  if z == 0 then
    local level = runtime.grid_state.current[x][y]
    send_grid_led(client, x, y, level)
    client.grid_sent[x][y] = level
  end
  return true
end

local function arc_delta_for_client(client, ring, position)
  client.arc_encoder_pos[ring] = client.arc_encoder_pos[ring] or -1
  local previous = client.arc_encoder_pos[ring]
  local delta = 0

  if previous ~= -1 then
    delta = position - previous
    if delta > 0.5 then
      delta = 1 - delta
    elseif delta < -0.5 then
      delta = -1 - delta
    end
  end

  client.arc_encoder_pos[ring] = position
  return tonumber(string.format("%.0f", delta * 500))
end

local function parse_arc_message(path, args)
  local ring, suffix = path:match("^" .. OSC_PATHS.arc_prefix .. "knob(%d+)(/[%w_]+)$")
  if ring == nil or suffix == nil then
    return nil
  end

  ring = tonumber(ring)
  if ring == nil or ring < 1 or ring > ARC_COLS then
    return nil
  end

  if suffix == "/button" or suffix == "/button1" then
    return ring, "button", (tonumber(args[1]) or 0) > 0 and 1 or 0
  end

  if suffix == "/encoder" or suffix == "/encoder1" then
    return ring, "encoder", tonumber(args[1]) or 0
  end

  return nil
end

local function handle_arc_message(client, args, path)
  local ring, kind, value = parse_arc_message(path, args)
  if ring == nil then
    return false
  end

  if kind == "button" then
    local state = value
    if arc_touchosc_enabled(1) and runtime.arc_vports[1].key then
      runtime.arc_vports[1].key(ring, state)
    end
    return true
  end

  if kind == "encoder" then
    local position = value
    local delta = arc_delta_for_client(client, ring, position)
    if delta ~= 0 and arc_touchosc_enabled(1) and runtime.arc_vports[1].delta then
      runtime.arc_vports[1].delta(ring, delta)
    end
    return true
  end

  return false
end

local function handle_connection(args, from)
  local requested = (tonumber(args[1]) or 1) > 0
  if not requested then
    local host, port = normalize_from(from)
    local client = runtime.clients[client_key(host, port)]
    if client ~= nil then
      client.last_seen = now_s()
      mark_dirty()
    end
    return true
  end

  local client = ensure_client(from)
  client.active = true
  client.last_seen = now_s()
  send_connected(client, true)
  send_grid_state(true, client)
  send_arc_state(true, client)
  print(string.format("[nagatomo] client connected: %s:%s", client.host, tostring(client.port)))
  return true
end

local function handle_touchosc(path, args, from)
  if type(path) ~= "string" then
    return false
  end

  if path == OSC_PATHS.connection then
    return handle_connection(args or {}, from)
  end

  if util.string_starts(path, OSC_PATHS.grid_prefix) then
    local x = parse_grid_press(path, args or {})
    if x == nil then
      return false
    end
    local client, created, reactivated = ensure_client(from)
    if created or reactivated then
      send_connected(client, true)
      send_grid_state(true, client)
      send_arc_state(true, client)
    end
    return handle_grid_press(client, args or {}, path)
  end

  if util.string_starts(path, OSC_PATHS.arc_prefix) then
    local ring = parse_arc_message(path, args or {})
    if ring == nil then
      return false
    end
    local client, created, reactivated = ensure_client(from)
    if created or reactivated then
      send_connected(client, true)
      send_grid_state(true, client)
      send_arc_state(true, client)
    end
    return handle_arc_message(client, args or {}, path)
  end

  return false
end

function runtime.dispatch_osc(path, args, from)
  if handle_touchosc(path, args, from) then
    return
  end
  return core.norns_osc_event(path, args, from)
end

function runtime.dispatch_grid_add(id, serial, name, dev)
  core.norns_grid_add(id, serial, name, dev)
  runtime.refresh_ports()
  if runtime.grid_api.add then
    runtime.grid_api.add(core.grid.devices[id])
  end
  mark_dirty()
end

function runtime.dispatch_grid_remove(id)
  local device = core.grid.devices[id]
  local port = device and device.port or nil
  core.norns_grid_remove(id)
  runtime.refresh_ports()
  if port and runtime.grid_vports[port].remove then
    runtime.grid_vports[port].remove()
  end
  if runtime.grid_api.remove and device then
    runtime.grid_api.remove(device)
  end
  mark_dirty()
end

function runtime.dispatch_grid_key(id, x, y, state)
  core.norns_grid_key(id, x, y, state)
  local device = core.grid.devices[id]
  local port = device and device.port or nil
  if port and grid_physical_enabled(port) and runtime.grid_vports[port].key then
    runtime.grid_vports[port].key(x, y, state)
  end
end

function runtime.dispatch_grid_tilt(id, x, y, z)
  core.norns_grid_tilt(id, x, y, z)
  local device = core.grid.devices[id]
  local port = device and device.port or nil
  if port and grid_physical_enabled(port) and runtime.grid_vports[port].tilt then
    runtime.grid_vports[port].tilt(x, y, z)
  end
end

function runtime.dispatch_arc_add(id, serial, name, dev)
  core.norns_arc_add(id, serial, name, dev)
  runtime.refresh_ports()
  if runtime.arc_api.add then
    runtime.arc_api.add(core.arc.devices[id])
  end
  mark_dirty()
end

function runtime.dispatch_arc_remove(id)
  local device = core.arc.devices[id]
  local port = device and device.port or nil
  core.norns_arc_remove(id)
  runtime.refresh_ports()
  if port and runtime.arc_vports[port].remove then
    runtime.arc_vports[port].remove()
  end
  if runtime.arc_api.remove and device then
    runtime.arc_api.remove(device)
  end
  mark_dirty()
end

function runtime.dispatch_arc_key(id, ring, state)
  core.norns_arc_key(id, ring, state)
  local device = core.arc.devices[id]
  local port = device and device.port or nil
  if port and arc_physical_enabled(port) and runtime.arc_vports[port].key then
    runtime.arc_vports[port].key(ring, state)
  end
end

function runtime.dispatch_arc_delta(id, ring, delta)
  core.norns_arc_delta(id, ring, delta)
  local device = core.arc.devices[id]
  local port = device and device.port or nil
  if port and arc_physical_enabled(port) and runtime.arc_vports[port].delta then
    runtime.arc_vports[port].delta(ring, delta)
  end
end

function runtime.set_menu_redraw(func)
  runtime.menu_redraw = func
end

function runtime.run_light_test()
  local clients = runtime.active_clients()

  for _, client in ipairs(clients) do
    send_connected(client, true)
    for y = 1, GRID_ROWS do
      for x = 1, GRID_COLS do
        send_grid_led(client, x, y, ((x + y) % 2 == 0) and 12 or 3)
      end
    end
  end

  if grid_physical_enabled(1) then
    core.grid.vports[1]:all(0)
    for y = 1, GRID_ROWS do
      for x = 1, GRID_COLS do
        core.grid.vports[1]:led(x, y, ((x + y) % 2 == 0) and 12 or 3)
      end
    end
    core.grid.vports[1]:refresh()
  end

  local quarter = math.pi * 0.5
  local tau = math.pi * 2
  local step = tau / ARC_ROWS
  for _, client in ipairs(clients) do
    for ring = 1, ARC_COLS do
      for led = 1, ARC_ROWS do
        local sa = step * (led - 1)
        local sb = step * led
        local lit = math.max(0, math.min(sb, quarter) - math.max(sa, 0)) > 0
        send_arc_led(client, ring, led, lit and 15 or 0)
      end
    end
  end

  if arc_physical_enabled(1) then
    core.arc.vports[1]:all(0)
    for ring = 1, ARC_COLS do
      for led = 1, ARC_ROWS do
        local sa = step * (led - 1)
        local sb = step * led
        local lit = math.max(0, math.min(sb, quarter) - math.max(sa, 0)) > 0
        core.arc.vports[1]:led(ring, led, lit and 15 or 0)
      end
    end
    core.arc.vports[1]:refresh()
  end

  print("[nagatomo] light test sent; use 'Resend state' to restore the current script state")
end

runtime.grid_api = {
  devices = core.grid.devices,
  vports = {},
  help = core.grid.help,
  add = nil,
  remove = nil,
}

runtime.arc_api = {
  devices = core.arc.devices,
  vports = {},
  help = core.arc.help,
  add = nil,
  remove = nil,
}

for port = 1, GRID_PORTS do
  runtime.grid_vports = runtime.grid_vports or {}
  runtime.grid_vports[port] = {
    port = port,
    name = default_grid_name(port),
    device = nil,
    key = nil,
    tilt = nil,
    remove = nil,
    cols = port == 1 and GRID_COLS or 0,
    rows = port == 1 and GRID_ROWS or 0,
    led = function(self, x, y, level, rel)
      runtime.grid_led(self.port, x, y, level, rel)
    end,
    all = function(self, level, rel)
      runtime.grid_all(self.port, level, rel)
    end,
    refresh = function(self, force)
      runtime.grid_refresh(self.port, force)
    end,
    rotation = function(self, value)
      runtime.grid_rotation(self.port, value)
    end,
    intensity = function(self, value)
      runtime.grid_intensity(self.port, value)
    end,
    tilt_enable = function(self, id, value)
      runtime.grid_tilt_enable(self.port, id, value)
    end,
  }
  runtime.grid_api.vports[port] = runtime.grid_vports[port]
end

for port = 1, ARC_PORTS do
  runtime.arc_vports = runtime.arc_vports or {}
  runtime.arc_vports[port] = {
    port = port,
    name = default_arc_name(port),
    device = nil,
    delta = nil,
    key = nil,
    remove = nil,
    led = function(self, ring, led, level, rel)
      runtime.arc_led(self.port, ring, led, level, rel)
    end,
    all = function(self, level, rel)
      runtime.arc_all(self.port, level, rel)
    end,
    refresh = function(self, force)
      runtime.arc_refresh(self.port, force)
    end,
    segment = function(self, ring, from_angle, to_angle, level, rel)
      runtime.arc_segment(self.port, ring, from_angle, to_angle, level, rel)
    end,
    intensity = function(self, value)
      runtime.arc_intensity(self.port, value)
    end,
  }
  runtime.arc_api.vports[port] = runtime.arc_vports[port]
end

function runtime.grid_api.connect(port)
  runtime.refresh_ports()
  return runtime.grid_vports[port or 1]
end

function runtime.grid_api.update_devices()
  core.grid.update_devices()
  runtime.refresh_ports()
end

function runtime.grid_api.cleanup()
  runtime.grid_cleanup()
end

function runtime.arc_api.connect(port)
  runtime.refresh_ports()
  return runtime.arc_vports[port or 1]
end

function runtime.arc_api.update_devices()
  core.arc.update_devices()
  runtime.refresh_ports()
end

function runtime.arc_api.cleanup()
  runtime.arc_cleanup()
end

function runtime.install()
  if runtime.installed then
    runtime.refresh_ports()
    return runtime
  end

  if norns and norns.script then
    if norns.script.redraw == nil then
      norns.script.redraw = norns.blank
    end
    if norns.script.refresh == nil then
      norns.script.refresh = norns.none
    end
  end

  load_prefs()
  load_clients()
  runtime.refresh_ports()

  _norns.grid.add = runtime.dispatch_grid_add
  _norns.grid.remove = runtime.dispatch_grid_remove
  _norns.grid.key = runtime.dispatch_grid_key
  _norns.grid.tilt = runtime.dispatch_grid_tilt
  _norns.arc.add = runtime.dispatch_arc_add
  _norns.arc.remove = runtime.dispatch_arc_remove
  _norns.arc.key = runtime.dispatch_arc_key
  _norns.arc.delta = runtime.dispatch_arc_delta
  _norns.osc.event = runtime.dispatch_osc

  grid = runtime.grid_api
  arc = runtime.arc_api
  package.loaded["grid"] = runtime.grid_api
  package.loaded["arc"] = runtime.arc_api

  runtime.installed = true
  print("[nagatomo] installed runtime")
  return runtime
end

return runtime
