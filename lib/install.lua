local module_name = ...
local module_prefix = type(module_name) == "string" and module_name:match("^(.*)/install$")
if module_prefix == nil then
  error("unable to derive nagatomo module prefix from install module name")
end

local util = require "util"
local tabutil = require "tabutil"

local MOD_NAME = "nagatomo"

local OSC_PATHS = {
  connection = "/toga_connection",
  grid_prefix = "/togagrid/",
  arc_prefix = "/togaarc/",
}

local GRID_PORTS = 4
local GRID_COLS = 16
local GRID_ROWS = 8
local GRID_CELL_COUNT = GRID_COLS * GRID_ROWS

local ARC_PORTS = 4
local ARC_COLS = 4
local ARC_ROWS = 64
local ARC_LED_COUNT = ARC_COLS * ARC_ROWS

local SENT_UNKNOWN = -1

local POLICY_ORDER = { "auto", "touchosc", "mirror" }
local POLICY_LABELS = {
  auto = "Auto",
  touchosc = "TouchOSC Only",
  mirror = "Mirror Both",
}

local GRID_PATHS = {}
for index = 1, GRID_CELL_COUNT do
  GRID_PATHS[index] = OSC_PATHS.grid_prefix .. index
end

local ARC_PATHS_GROUP1 = {}
local ARC_PATHS_GROUP2 = {}
for index = 1, ARC_LED_COUNT do
  local ring = math.floor((index - 1) / ARC_ROWS) + 1
  local led = ((index - 1) % ARC_ROWS) + 1
  ARC_PATHS_GROUP1[index] = string.format("%sknob%d/group1/button%d", OSC_PATHS.arc_prefix, ring, led)
  ARC_PATHS_GROUP2[index] = string.format("%sknob%d/group2/button%d", OSC_PATHS.arc_prefix, ring, led)
end

local CONNECTED_ARGS = {
  [false] = { 0.0 },
  [true] = { 1.0 },
}

local LEVEL_ARGS = {}
for level = 0, 15 do
  LEVEL_ARGS[level] = { level / 15.0 }
end

local TAU = math.pi * 2
local ARC_STEP = TAU / ARC_ROWS

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

local runtime = {
  data_dir = tostring(_path.data) .. MOD_NAME .. "/",
  prefs_fn = tostring(_path.data) .. MOD_NAME .. "/prefs.lua",
  clients_fn = tostring(_path.data) .. MOD_NAME .. "/clients.lua",
  installed = false,
}

local function create_linear_buffer(length, initial)
  initial = initial or 0
  local buffer = {}
  for i = 1, length do
    buffer[i] = initial
  end
  return buffer
end

local function mark_index(flags, list, index)
  if flags[index] then
    return
  end
  flags[index] = true
  list[#list + 1] = index
end

local function clear_index_list(flags, list)
  for i = 1, #list do
    flags[list[i]] = nil
    list[i] = nil
  end
end

local function grid_index(x, y)
  return x + (y - 1) * GRID_COLS
end

local function arc_index(ring, led)
  return led + (ring - 1) * ARC_ROWS
end

local ctx = {
  util = util,
  tabutil = tabutil,
  core = core,
  constants = {
    GRID_PORTS = GRID_PORTS,
    GRID_COLS = GRID_COLS,
    GRID_ROWS = GRID_ROWS,
    GRID_CELL_COUNT = GRID_CELL_COUNT,
    ARC_PORTS = ARC_PORTS,
    ARC_COLS = ARC_COLS,
    ARC_ROWS = ARC_ROWS,
    ARC_LED_COUNT = ARC_LED_COUNT,
    SENT_UNKNOWN = SENT_UNKNOWN,
    POLICY_ORDER = POLICY_ORDER,
    POLICY_LABELS = POLICY_LABELS,
    TAU = TAU,
    ARC_STEP = ARC_STEP,
  },
  osc_paths = OSC_PATHS,
  osc_args = {
    connected = CONNECTED_ARGS,
    level = LEVEL_ARGS,
  },
  paths = {
    grid = GRID_PATHS,
    arc_group1 = ARC_PATHS_GROUP1,
    arc_group2 = ARC_PATHS_GROUP2,
  },
  helpers = {
    create_linear_buffer = create_linear_buffer,
    mark_index = mark_index,
    clear_index_list = clear_index_list,
    grid_index = grid_index,
    arc_index = arc_index,
  },
  fn = {},
}

require(module_prefix .. "/state")(runtime, ctx)
require(module_prefix .. "/devices")(runtime, ctx)
require(module_prefix .. "/osc")(runtime, ctx)

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

  ctx.fn.load_prefs()
  ctx.fn.load_clients()
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
