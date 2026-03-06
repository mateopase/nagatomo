-- SPDX-FileCopyrightText: 2026 Mateo Paredes Sepulveda
-- SPDX-License-Identifier: GPL-3.0-or-later

local util = require "util"
local tabutil = require "tabutil"

local runtime = {
  data_dir = tostring(_path.data) .. "toga-shim/",
  prefs_fn = tostring(_path.data) .. "toga-shim/prefs.lua",
  clients_fn = tostring(_path.data) .. "toga-shim/clients.lua",
  client_timeout_s = 20,
}

local GRID_PORTS = 4
local GRID_COLS = 16
local GRID_ROWS = 8
local ARC_PORTS = 4
local ARC_COLS = 4
local ARC_ROWS = 64

local POLICY_ORDER = { "auto", "touchosc", "mirror" }
local POLICY_LABELS = {
  auto = "Auto",
  touchosc = "TouchOSC Only",
  mirror = "Mirror Both",
}

local function default_grid_add(dev)
  return dev
end

local function default_arc_add(dev)
  return dev
end

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

runtime.core = core
runtime.prefs = {
  grid_policy = "auto",
  arc_policy = "auto",
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

local function create_buffer(width, height)
  local buffer = {}
  for x = 1, width do
    buffer[x] = {}
    for y = 1, height do
      buffer[x][y] = 0
    end
  end
  return buffer
end

local function clone_buffer(source)
  local copy = {}
  for x, column in ipairs(source) do
    copy[x] = {}
    for y, value in ipairs(column) do
      copy[x][y] = value
    end
  end
  return copy
end

runtime.grid_state = {
  new = create_buffer(GRID_COLS, GRID_ROWS),
  sent = create_buffer(GRID_COLS, GRID_ROWS),
}

runtime.arc_state = {
  new = create_buffer(ARC_COLS, ARC_ROWS),
  sent = create_buffer(ARC_COLS, ARC_ROWS),
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

local function client_key(host, port)
  return tostring(host) .. ":" .. tostring(port)
end

local function normalize_from(from)
  local host = from and from[1] or "unknown"
  local port = tonumber(from and from[2]) or tostring(from and from[2] or "0")
  return host, port
end

local function has_capability(client, name)
  return client.capabilities[name] == true
end

local function add_capability(client, name)
  if not has_capability(client, name) then
    client.capabilities[name] = true
    return true
  end
  return false
end

local function encode_capabilities(capabilities)
  local encoded = {}
  for name, enabled in pairs(capabilities or {}) do
    if enabled then
      table.insert(encoded, name)
    end
  end
  table.sort(encoded)
  return encoded
end

local function decode_capabilities(encoded)
  local capabilities = {}
  for _, name in ipairs(encoded or {}) do
    capabilities[name] = true
  end
  return capabilities
end

local function client_is_active(client)
  if not client or not client.active then
    return false
  end
  return (now_s() - (client.last_seen or 0)) <= runtime.client_timeout_s
end

local function snapshot_client(client)
  return {
    host = client.host,
    port = client.port,
    first_seen = client.first_seen,
    last_seen = client.last_seen,
    capabilities = encode_capabilities(client.capabilities),
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
      local key = client_key(entry.host, entry.port)
      runtime.clients[key] = {
        key = key,
        host = entry.host,
        port = entry.port,
        first_seen = tonumber(entry.first_seen) or now_s(),
        last_seen = tonumber(entry.last_seen) or 0,
        active = false,
        capabilities = decode_capabilities(entry.capabilities),
        arc_encoder_pos = {},
      }
      table.insert(runtime.client_order, key)
    end
  end
end

local function save_prefs()
  ensure_dir(runtime.data_dir)
  tabutil.save({
    grid_policy = runtime.prefs.grid_policy,
    arc_policy = runtime.prefs.arc_policy,
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

local function grid_touchosc_enabled(port)
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

local function arc_touchosc_enabled(port)
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

local function grid_virtual_available(port)
  return port == 1
end

local function arc_virtual_available(port)
  return port == 1
end

local function current_grid_device(port)
  if grid_has_physical(port) then
    return core.grid.vports[port].device
  end
  if grid_virtual_available(port) then
    return runtime.grid_virtual
  end
  return nil
end

local function current_arc_device(port)
  if arc_has_physical(port) then
    return core.arc.vports[port].device
  end
  if arc_virtual_available(port) then
    return runtime.arc_virtual
  end
  return nil
end

local function grid_port_name(port)
  if grid_has_physical(port) then
    return core.grid.vports[port].name
  end
  return default_grid_name(port)
end

local function grid_port_cols(port)
  if grid_has_physical(port) then
    return core.grid.vports[port].cols
  end
  if grid_virtual_available(port) then
    return GRID_COLS
  end
  return 0
end

local function grid_port_rows(port)
  if grid_has_physical(port) then
    return core.grid.vports[port].rows
  end
  if grid_virtual_available(port) then
    return GRID_ROWS
  end
  return 0
end

local function arc_port_name(port)
  if arc_has_physical(port) then
    return core.arc.vports[port].name
  end
  return default_arc_name(port)
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

function runtime.recent_clients()
  return list_clients(function(client)
    return not client_is_active(client)
  end)
end

local function ensure_client(from, capability)
  local host, port = normalize_from(from)
  local key = client_key(host, port)
  local client = runtime.clients[key]
  local created = false
  local reactivated = false

  if client == nil then
    created = true
    client = {
      key = key,
      host = host,
      port = port,
      first_seen = now_s(),
      last_seen = now_s(),
      active = true,
      capabilities = {},
      arc_encoder_pos = {},
    }
    runtime.clients[key] = client
    table.insert(runtime.client_order, key)
  else
    reactivated = not client_is_active(client)
    client.active = true
    client.last_seen = now_s()
  end

  local capability_changed = false
  if capability then
    capability_changed = add_capability(client, capability)
  end

  if created or capability_changed then
    save_clients()
  end

  mark_dirty()
  return client, created, reactivated
end

local function set_client_active(client, active)
  if client == nil then
    return
  end
  client.active = active
  if active then
    client.last_seen = now_s()
  end
  mark_dirty()
end

local function send_osc(client, path, args)
  core.osc.send({ client.host, client.port }, path, args)
end

local function send_connected(client, connected)
  send_osc(client, "/toga_connection", { connected and 1.0 or 0.0 })
end

local function send_grid_led(client, x, y, level)
  local index = x + (y - 1) * GRID_COLS
  send_osc(client, string.format("/togagrid/%d", index), { level / 15.0 })
end

local function send_arc_led(client, ring, led, level)
  for group = 1, 2 do
    send_osc(client, string.format("/togaarc/knob%d/group%d/button%d", ring, group, led), { level / 15.0 })
  end
end

local function send_grid_state(force, target_client)
  if not grid_touchosc_enabled(1) then
    return
  end

  local clients = target_client and { target_client } or runtime.active_clients()
  for _, client in ipairs(clients) do
    for y = 1, GRID_ROWS do
      for x = 1, GRID_COLS do
        local current = runtime.grid_state.new[x][y]
        if force or runtime.grid_state.sent[x][y] ~= current then
          send_grid_led(client, x, y, current)
        end
      end
    end
  end

  for y = 1, GRID_ROWS do
    for x = 1, GRID_COLS do
      runtime.grid_state.sent[x][y] = runtime.grid_state.new[x][y]
    end
  end
end

local function send_arc_state(force, target_client)
  if not arc_touchosc_enabled(1) then
    return
  end

  local clients = target_client and { target_client } or runtime.active_clients()
  for _, client in ipairs(clients) do
    for ring = 1, ARC_COLS do
      for led = 1, ARC_ROWS do
        local current = runtime.arc_state.new[ring][led]
        if force or runtime.arc_state.sent[ring][led] ~= current then
          send_arc_led(client, ring, led, current)
        end
      end
    end
  end

  for ring = 1, ARC_COLS do
    for led = 1, ARC_ROWS do
      runtime.arc_state.sent[ring][led] = runtime.arc_state.new[ring][led]
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

local function reconnect_known_clients()
  for _, key in ipairs(runtime.client_order) do
    local client = runtime.clients[key]
    if client then
      send_connected(client, true)
      send_grid_state(true, client)
      send_arc_state(true, client)
    end
  end
  print("[toga-shim] reconnect requested for known clients")
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
  local state = client_is_active(client) and "active" or "recent"
  return string.format("%s:%s %s %s", client.host, tostring(client.port), state, age_string(client.last_seen))
end

function runtime.status()
  return {
    grid_policy = POLICY_LABELS[runtime.prefs.grid_policy],
    arc_policy = POLICY_LABELS[runtime.prefs.arc_policy],
    active_clients = runtime.active_clients(),
    recent_clients = runtime.recent_clients(),
    grid_bound = runtime.grid_vports[1].key ~= nil or runtime.grid_vports[1].tilt ~= nil,
    arc_bound = runtime.arc_vports[1].key ~= nil or runtime.arc_vports[1].delta ~= nil,
    script_name = norns.state.name,
    total_active = active_client_count(),
  }
end

local function cycle_policy(kind)
  local current = runtime.prefs[kind]
  local index = 1
  for i, name in ipairs(POLICY_ORDER) do
    if name == current then
      index = i
      break
    end
  end
  index = (index % #POLICY_ORDER) + 1
  runtime.prefs[kind] = POLICY_ORDER[index]
  save_prefs()
  runtime.refresh_ports()
  runtime.resend_state(nil, false)
  print(string.format("[toga-shim] %s policy -> %s", kind, POLICY_LABELS[runtime.prefs[kind]]))
end

function runtime.cycle_grid_policy()
  cycle_policy("grid_policy")
end

function runtime.cycle_arc_policy()
  cycle_policy("arc_policy")
end

function runtime.policy_label(kind)
  return POLICY_LABELS[runtime.prefs[kind]]
end

function runtime.clear_active_clients()
  for _, client in pairs(runtime.clients) do
    client.active = false
  end
  print("[toga-shim] cleared active client sessions")
  mark_dirty()
end

function runtime.forget_client_history()
  runtime.clients = {}
  runtime.client_order = {}
  save_clients()
  print("[toga-shim] forgot client history")
  mark_dirty()
end

local function reset_grid_buffers(level)
  for y = 1, GRID_ROWS do
    for x = 1, GRID_COLS do
      runtime.grid_state.new[x][y] = level
      runtime.grid_state.sent[x][y] = level
    end
  end
end

local function reset_arc_buffers(level)
  for ring = 1, ARC_COLS do
    for led = 1, ARC_ROWS do
      runtime.arc_state.new[ring][led] = level
      runtime.arc_state.sent[ring][led] = level
    end
  end
end

function runtime.grid_led(port, x, y, level)
  level = util.clamp(math.floor(level or 0), 0, 15)
  if port == 1 and x >= 1 and x <= GRID_COLS and y >= 1 and y <= GRID_ROWS then
    runtime.grid_state.new[x][y] = level
  end
  if grid_physical_enabled(port) then
    core.grid.vports[port]:led(x, y, level)
  end
end

function runtime.grid_all(port, level)
  level = util.clamp(math.floor(level or 0), 0, 15)
  if port == 1 then
    for y = 1, GRID_ROWS do
      for x = 1, GRID_COLS do
        runtime.grid_state.new[x][y] = level
      end
    end
  end
  if grid_physical_enabled(port) then
    core.grid.vports[port]:all(level)
  end
end

function runtime.grid_refresh(port, force)
  if port == 1 then
    send_grid_state(force == true)
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

function runtime.arc_led(port, ring, led, level)
  level = util.clamp(math.floor(level or 0), 0, 15)
  if port == 1 and ring >= 1 and ring <= ARC_COLS and led >= 1 and led <= ARC_ROWS then
    runtime.arc_state.new[ring][led] = level
  end
  if arc_physical_enabled(port) then
    core.arc.vports[port]:led(ring, led, level)
  end
end

function runtime.arc_all(port, level)
  level = util.clamp(math.floor(level or 0), 0, 15)
  if port == 1 then
    for ring = 1, ARC_COLS do
      for led = 1, ARC_ROWS do
        runtime.arc_state.new[ring][led] = level
      end
    end
  end
  if arc_physical_enabled(port) then
    core.arc.vports[port]:all(level)
  end
end

function runtime.arc_segment(port, ring, from_angle, to_angle, level)
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
  for led = 1, ARC_ROWS do
    local sa = step * (led - 1)
    local sb = step * led
    local amount = overlap_segments(from_angle, to_angle, sa, sb)
    local brightness = util.round(amount / step * level)
    runtime.arc_led(port, ring, led, brightness)
  end
end

function runtime.arc_refresh(port, force)
  if port == 1 then
    send_arc_state(force == true)
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
  core.grid.cleanup()
  runtime.grid_api.add = default_grid_add
  runtime.grid_api.remove = function() end
  for port = 1, GRID_PORTS do
    local vport = runtime.grid_vports[port]
    vport.key = nil
    vport.tilt = nil
    vport.remove = nil
  end
  reset_grid_buffers(0)
  send_grid_state(true)
  runtime.refresh_ports()
  mark_dirty()
end

function runtime.arc_cleanup()
  core.arc.cleanup()
  runtime.arc_api.add = default_arc_add
  runtime.arc_api.remove = function() end
  for port = 1, ARC_PORTS do
    local vport = runtime.arc_vports[port]
    vport.key = nil
    vport.delta = nil
    vport.remove = nil
  end
  reset_arc_buffers(0)
  send_arc_state(true)
  runtime.refresh_ports()
  mark_dirty()
end

local function handle_grid_press(client, args, path)
  local index = tonumber(path:match("^/togagrid/(%d+)$"))
  if index == nil then
    return false
  end

  local x = ((index - 1) % GRID_COLS) + 1
  local y = math.floor((index - 1) / GRID_COLS) + 1
  local z = (tonumber(args[1]) or 0) > 0 and 1 or 0
  if grid_touchosc_enabled(1) and runtime.grid_vports[1].key then
    runtime.grid_vports[1].key(x, y, z)
  end
  if z == 0 then
    send_grid_led(client, x, y, runtime.grid_state.new[x][y])
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

local function handle_arc_message(client, args, path)
  local ring, suffix = path:match("^/togaarc/knob(%d+)(/[%w_]+)$")
  if ring == nil or suffix == nil then
    return false
  end

  ring = tonumber(ring)
  if ring == nil or ring < 1 or ring > ARC_COLS then
    return false
  end

  if suffix == "/button" or suffix == "/button1" then
    local state = (tonumber(args[1]) or 0) > 0 and 1 or 0
    if arc_touchosc_enabled(1) and runtime.arc_vports[1].key then
      runtime.arc_vports[1].key(ring, state)
    end
    return true
  end

  if suffix == "/encoder" or suffix == "/encoder1" then
    local position = tonumber(args[1]) or 0
    local delta = arc_delta_for_client(client, ring, position)
    if delta ~= 0 and arc_touchosc_enabled(1) and runtime.arc_vports[1].delta then
      runtime.arc_vports[1].delta(ring, delta)
    end
    return true
  end

  return false
end

local function handle_connection(client, args)
  local requested = (tonumber(args[1]) or 1) > 0
  if not requested then
    set_client_active(client, false)
    print(string.format("[toga-shim] client disconnected: %s:%s", client.host, tostring(client.port)))
    return true
  end

  send_connected(client, true)
  send_grid_state(true, client)
  send_arc_state(true, client)
  print(string.format("[toga-shim] client connected: %s:%s", client.host, tostring(client.port)))
  return true
end

local function handle_touchosc(path, args, from)
  if type(path) ~= "string" then
    return false
  end

  if not util.string_starts(path, "/toga") then
    return false
  end

  local capability = "connection"
  if util.string_starts(path, "/togagrid/") then
    capability = "grid"
  elseif util.string_starts(path, "/togaarc/") then
    capability = "arc"
  end

  local client, created, reactivated = ensure_client(from, capability)
  if created or reactivated then
    for ring = 1, ARC_COLS do
      client.arc_encoder_pos[ring] = -1
    end
  end

  if path == "/toga_connection" then
    return handle_connection(client, args or {})
  end

  if util.string_starts(path, "/togagrid/") then
    if created or reactivated then
      send_connected(client, true)
      send_grid_state(true, client)
      send_arc_state(true, client)
    end
    return handle_grid_press(client, args or {}, path)
  end

  if util.string_starts(path, "/togaarc/") then
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
  local grid_before = clone_buffer(runtime.grid_state.new)
  local arc_before = clone_buffer(runtime.arc_state.new)

  runtime.grid_all(1, 0)
  for y = 1, GRID_ROWS do
    for x = 1, GRID_COLS do
      runtime.grid_led(1, x, y, ((x + y) % 2 == 0) and 12 or 3)
    end
  end
  runtime.grid_refresh(1, true)

  runtime.arc_all(1, 0)
  local quarter = math.pi * 0.5
  for ring = 1, ARC_COLS do
    runtime.arc_segment(1, ring, 0, quarter, 15)
  end
  runtime.arc_refresh(1, true)

  clock.run(function()
    clock.sleep(0.75)
    runtime.grid_state.new = clone_buffer(grid_before)
    runtime.arc_state.new = clone_buffer(arc_before)
    send_grid_state(true)
    send_arc_state(true)
    if grid_physical_enabled(1) then
      core.grid.vports[1]:all(0)
      core.grid.vports[1]:refresh()
      for y = 1, GRID_ROWS do
        for x = 1, GRID_COLS do
          core.grid.vports[1]:led(x, y, runtime.grid_state.new[x][y])
        end
      end
      core.grid.vports[1]:refresh()
    end
    if arc_physical_enabled(1) then
      core.arc.vports[1]:all(0)
      core.arc.vports[1]:refresh()
      for ring = 1, ARC_COLS do
        for led = 1, ARC_ROWS do
          core.arc.vports[1]:led(ring, led, runtime.arc_state.new[ring][led])
        end
      end
      core.arc.vports[1]:refresh()
    end
  end)

  print("[toga-shim] light test sent")
end

runtime.grid_api = {
  devices = core.grid.devices,
  vports = {},
  help = core.grid.help,
  add = default_grid_add,
  remove = function() end,
}

runtime.arc_api = {
  devices = core.arc.devices,
  vports = {},
  help = core.arc.help,
  add = default_arc_add,
  remove = function() end,
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
    led = function(self, x, y, level)
      runtime.grid_led(self.port, x, y, level)
    end,
    all = function(self, level)
      runtime.grid_all(self.port, level)
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
    led = function(self, ring, led, level)
      runtime.arc_led(self.port, ring, led, level)
    end,
    all = function(self, level)
      runtime.arc_all(self.port, level)
    end,
    refresh = function(self, force)
      runtime.arc_refresh(self.port, force)
    end,
    segment = function(self, ring, from_angle, to_angle, level)
      runtime.arc_segment(self.port, ring, from_angle, to_angle, level)
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

function runtime.grid_api.cleanup()
  runtime.grid_cleanup()
end

function runtime.arc_api.connect(port)
  runtime.refresh_ports()
  return runtime.arc_vports[port or 1]
end

function runtime.arc_api.cleanup()
  runtime.arc_cleanup()
end

function runtime.install()
  if runtime.installed then
    runtime.refresh_ports()
    return runtime
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
  print("[toga-shim] installed runtime")
  return runtime
end

function runtime.snapshot_clients()
  local snapshots = {}
  for _, key in ipairs(runtime.client_order) do
    local client = runtime.clients[key]
    if client then
      table.insert(snapshots, {
        label = runtime.describe_client(client),
        active = client_is_active(client),
      })
    end
  end
  return snapshots
end

function runtime.reconnect_known_clients()
  reconnect_known_clients()
end

return runtime
