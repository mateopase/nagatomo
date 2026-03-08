return function(runtime, ctx)
  local constants = ctx.constants
  local helpers = ctx.helpers
  local fn = ctx.fn

  runtime.grid_virtual = {
    id = -1,
    serial = "touchosc",
    name = "TouchOSC Grid",
    cols = constants.GRID_COLS,
    rows = constants.GRID_ROWS,
    port = 1,
  }
  runtime.arc_virtual = {
    id = -1,
    serial = "touchosc",
    name = "TouchOSC Arc",
    port = 1,
  }

  runtime.grid_state = {
    current = helpers.create_linear_buffer(constants.GRID_CELL_COUNT, 0),
    dirty_flags = {},
    dirty_list = {},
    retry_flags = {},
    retry_list = {},
  }

  runtime.arc_state = {
    current = helpers.create_linear_buffer(constants.ARC_LED_COUNT, 0),
    dirty_flags = {},
    dirty_list = {},
    retry_flags = {},
    retry_list = {},
  }

  local function clear_grid_retry_pending()
    helpers.clear_index_list(runtime.grid_state.retry_flags, runtime.grid_state.retry_list)
  end

  local function clear_arc_retry_pending()
    helpers.clear_index_list(runtime.arc_state.retry_flags, runtime.arc_state.retry_list)
  end

  local function clear_grid_dirty()
    helpers.clear_index_list(runtime.grid_state.dirty_flags, runtime.grid_state.dirty_list)
  end

  local function clear_arc_dirty()
    helpers.clear_index_list(runtime.arc_state.dirty_flags, runtime.arc_state.dirty_list)
  end

  local function mark_grid_dirty(index)
    helpers.mark_index(runtime.grid_state.dirty_flags, runtime.grid_state.dirty_list, index)
  end

  local function mark_grid_retry(index)
    helpers.mark_index(runtime.grid_state.retry_flags, runtime.grid_state.retry_list, index)
  end

  local function mark_arc_dirty(index)
    helpers.mark_index(runtime.arc_state.dirty_flags, runtime.arc_state.dirty_list, index)
  end

  local function mark_arc_retry(index)
    helpers.mark_index(runtime.arc_state.retry_flags, runtime.arc_state.retry_list, index)
  end

  local function reset_grid_state(level, keep_dirty)
    for index = 1, constants.GRID_CELL_COUNT do
      runtime.grid_state.current[index] = level
    end
    if keep_dirty then
      clear_grid_dirty()
      for index = 1, constants.GRID_CELL_COUNT do
        mark_grid_dirty(index)
      end
    else
      clear_grid_dirty()
    end
    clear_grid_retry_pending()
  end

  local function reset_arc_state(level, keep_dirty)
    for index = 1, constants.ARC_LED_COUNT do
      runtime.arc_state.current[index] = level
    end
    if keep_dirty then
      clear_arc_dirty()
      for index = 1, constants.ARC_LED_COUNT do
        mark_arc_dirty(index)
      end
    else
      clear_arc_dirty()
    end
    clear_arc_retry_pending()
  end

  local function apply_level(current, level, rel)
    if rel then
      return ctx.util.clamp(current + level, 0, 15)
    end
    return ctx.util.clamp(level, 0, 15)
  end

  local function set_grid_current_index(index, level, mark_retry)
    if index < 1 or index > constants.GRID_CELL_COUNT then
      return false
    end
    if runtime.grid_state.current[index] == level then
      return false
    end
    runtime.grid_state.current[index] = level
    mark_grid_dirty(index)
    if mark_retry then
      mark_grid_retry(index)
    end
    return true
  end

  local function set_arc_current_index(index, level, mark_retry)
    if index < 1 or index > constants.ARC_LED_COUNT then
      return false
    end
    if runtime.arc_state.current[index] == level then
      return false
    end
    runtime.arc_state.current[index] = level
    mark_arc_dirty(index)
    if mark_retry then
      mark_arc_retry(index)
    end
    return true
  end

  local function refresh_grid_port(port)
    local vport = runtime.grid_vports[port]
    vport.name = fn.grid_port_name(port)
    vport.cols = fn.grid_port_cols(port)
    vport.rows = fn.grid_port_rows(port)
    vport.device = fn.current_grid_device(port)
  end

  local function refresh_arc_port(port)
    local vport = runtime.arc_vports[port]
    vport.name = fn.arc_port_name(port)
    vport.device = fn.current_arc_device(port)
  end

  function runtime.refresh_ports()
    for port = 1, constants.GRID_PORTS do
      refresh_grid_port(port)
    end
    for port = 1, constants.ARC_PORTS do
      refresh_arc_port(port)
    end
  end

  function runtime.grid_led(port, x, y, level, rel)
    level = math.floor(level or 0)
    if port == 1 then
      local index = helpers.grid_index(x, y)
      local current = runtime.grid_state.current[index]
      if current ~= nil then
        local next_level = apply_level(current, level, rel)
        set_grid_current_index(index, next_level, runtime.prefs.retry_writes_enabled)
      end
    end
    if fn.grid_physical_enabled(port) then
      ctx.core.grid.vports[port]:led(x, y, rel and level or ctx.util.clamp(level, 0, 15), rel)
    end
  end

  function runtime.grid_all(port, level, rel)
    level = math.floor(level or 0)
    if port == 1 then
      for index = 1, constants.GRID_CELL_COUNT do
        local next_level = apply_level(runtime.grid_state.current[index], level, rel)
        set_grid_current_index(index, next_level, runtime.prefs.retry_writes_enabled)
      end
    end
    if fn.grid_physical_enabled(port) then
      ctx.core.grid.vports[port]:all(rel and level or ctx.util.clamp(level, 0, 15), rel)
    end
  end

  function runtime.grid_refresh(port, force)
    if port == 1 and fn.grid_touchosc_enabled(1) then
      if force == true then
        fn.send_grid_state(true)
        clear_grid_dirty()
        clear_grid_retry_pending()
      else
        fn.send_grid_state(false)
        clear_grid_dirty()
        if runtime.prefs.retry_writes_enabled then
          fn.send_grid_state(false, nil, true)
          clear_grid_retry_pending()
        end
      end
    end
    if fn.grid_physical_enabled(port) then
      ctx.core.grid.vports[port]:refresh()
    end
  end

  function runtime.grid_rotation(port, value)
    if fn.grid_physical_enabled(port) then
      ctx.core.grid.vports[port]:rotation(value)
    end
  end

  function runtime.grid_intensity(port, value)
    if fn.grid_physical_enabled(port) then
      ctx.core.grid.vports[port]:intensity(value)
    end
  end

  function runtime.grid_tilt_enable(port, id, value)
    if fn.grid_physical_enabled(port) then
      ctx.core.grid.vports[port]:tilt_enable(id, value)
    end
  end

  function runtime.arc_led(port, ring, led, level, rel)
    level = math.floor(level or 0)
    if port == 1 then
      local index = helpers.arc_index(ring, led)
      local current = runtime.arc_state.current[index]
      if current ~= nil then
        local next_level = apply_level(current, level, rel)
        set_arc_current_index(index, next_level, runtime.prefs.retry_writes_enabled)
      end
    end
    if fn.arc_physical_enabled(port) then
      ctx.core.arc.vports[port]:led(ring, led, rel and level or ctx.util.clamp(level, 0, 15), rel)
    end
  end

  function runtime.arc_all(port, level, rel)
    level = math.floor(level or 0)
    if port == 1 then
      for index = 1, constants.ARC_LED_COUNT do
        local next_level = apply_level(runtime.arc_state.current[index], level, rel)
        set_arc_current_index(index, next_level, runtime.prefs.retry_writes_enabled)
      end
    end
    if fn.arc_physical_enabled(port) then
      ctx.core.arc.vports[port]:all(rel and level or ctx.util.clamp(level, 0, 15), rel)
    end
  end

  local function overlap_arc_ranges(a, b, c, d)
    if a > b then
      return overlap_arc_ranges(a, constants.TAU, c, d) + overlap_arc_ranges(0, b, c, d)
    end
    if c > d then
      return overlap_arc_ranges(a, b, c, constants.TAU) + overlap_arc_ranges(a, b, 0, d)
    end
    return math.max(0, math.min(b, d) - math.max(a, c))
  end

  local function overlap_arc_segments(a, b, c, d)
    a = a % constants.TAU
    b = b % constants.TAU
    c = c % constants.TAU
    d = d % constants.TAU
    return overlap_arc_ranges(a, b, c, d)
  end

  function runtime.arc_segment(port, ring, from_angle, to_angle, level, rel)
    level = math.floor(level or 0)
    for led = 1, constants.ARC_ROWS do
      local index = helpers.arc_index(ring, led)
      local sa = constants.ARC_STEP * (led - 1)
      local sb = constants.ARC_STEP * led
      local amount = overlap_arc_segments(from_angle, to_angle, sa, sb)
      local brightness = ctx.util.round(amount / constants.ARC_STEP * level)
      if port == 1 then
        local current = runtime.arc_state.current[index]
        if current ~= nil then
          local next_level = apply_level(current, brightness, rel)
          set_arc_current_index(index, next_level, runtime.prefs.retry_writes_enabled)
        end
      end
      if fn.arc_physical_enabled(port) then
        ctx.core.arc.vports[port]:led(ring, led, rel and brightness or ctx.util.clamp(brightness, 0, 15), rel)
      end
    end
  end

  function runtime.arc_refresh(port, force)
    if port == 1 and fn.arc_touchosc_enabled(1) then
      if force == true then
        fn.send_arc_state(true)
        clear_arc_dirty()
        clear_arc_retry_pending()
      else
        fn.send_arc_state(false)
        clear_arc_dirty()
        if runtime.prefs.retry_writes_enabled then
          fn.send_arc_state(false, nil, true)
          clear_arc_retry_pending()
        end
      end
    end
    if fn.arc_physical_enabled(port) then
      ctx.core.arc.vports[port]:refresh()
    end
  end

  function runtime.arc_intensity(port, value)
    if fn.arc_physical_enabled(port) then
      ctx.core.arc.vports[port]:intensity(value)
    end
  end

  runtime.grid_api = {
    devices = ctx.core.grid.devices,
    vports = {},
    help = ctx.core.grid.help,
    add = nil,
    remove = nil,
  }

  runtime.arc_api = {
    devices = ctx.core.arc.devices,
    vports = {},
    help = ctx.core.arc.help,
    add = nil,
    remove = nil,
  }

  runtime.grid_vports = {}
  for port = 1, constants.GRID_PORTS do
    runtime.grid_vports[port] = {
      port = port,
      name = port == 1 and runtime.grid_virtual.name or "none",
      device = nil,
      key = nil,
      tilt = nil,
      remove = nil,
      cols = port == 1 and constants.GRID_COLS or 0,
      rows = port == 1 and constants.GRID_ROWS or 0,
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

  runtime.arc_vports = {}
  for port = 1, constants.ARC_PORTS do
    runtime.arc_vports[port] = {
      port = port,
      name = port == 1 and runtime.arc_virtual.name or "none",
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
    ctx.core.grid.update_devices()
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
    ctx.core.arc.update_devices()
    runtime.refresh_ports()
  end

  function runtime.arc_api.cleanup()
    runtime.arc_cleanup()
  end

  function runtime.grid_cleanup()
    runtime.grid_api.add = nil
    runtime.grid_api.remove = nil
    for port = 1, constants.GRID_PORTS do
      local vport = runtime.grid_vports[port]
      vport.key = nil
      vport.tilt = nil
      vport.remove = nil
    end
    ctx.core.grid.cleanup()
    local should_send = fn.active_client_count() > 0 and fn.grid_touchosc_enabled(1)
    reset_grid_state(0, not should_send)
    if should_send then
      fn.send_grid_state(true)
      clear_grid_dirty()
    end
    runtime.refresh_ports()
    fn.mark_dirty()
  end

  function runtime.arc_cleanup()
    runtime.arc_api.add = nil
    runtime.arc_api.remove = nil
    for port = 1, constants.ARC_PORTS do
      local vport = runtime.arc_vports[port]
      vport.key = nil
      vport.delta = nil
      vport.remove = nil
    end
    ctx.core.arc.cleanup()
    local should_send = fn.active_client_count() > 0 and fn.arc_touchosc_enabled(1)
    reset_arc_state(0, not should_send)
    if should_send then
      fn.send_arc_state(true)
      clear_arc_dirty()
    end
    runtime.refresh_ports()
    fn.mark_dirty()
  end

  fn.clear_grid_retry_pending = clear_grid_retry_pending
  fn.clear_arc_retry_pending = clear_arc_retry_pending
  fn.clear_grid_dirty = clear_grid_dirty
  fn.clear_arc_dirty = clear_arc_dirty
  fn.reset_grid_state = reset_grid_state
  fn.reset_arc_state = reset_arc_state
  fn.apply_level = apply_level
  fn.set_grid_current_index = set_grid_current_index
  fn.set_arc_current_index = set_arc_current_index
end
