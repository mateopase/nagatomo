return function(runtime, ctx)
  local util = ctx.util
  local core = ctx.core
  local constants = ctx.constants
  local helpers = ctx.helpers
  local osc_paths = ctx.osc_paths
  local osc_args = ctx.osc_args
  local paths = ctx.paths
  local fn = ctx.fn

  local function send_osc(client, path, args)
    core.osc.send(client.to, path, args)
  end

  local function send_connected(client, connected)
    send_osc(client, osc_paths.connection, osc_args.connected[connected == true])
  end

  local function send_grid_led_index(client, index, level)
    send_osc(client, paths.grid[index], osc_args.level[level])
  end

  local function send_grid_led(client, x, y, level)
    send_grid_led_index(client, helpers.grid_index(x, y), level)
  end

  local function send_arc_led_index(client, index, level)
    local args = osc_args.level[level]
    send_osc(client, paths.arc_group1[index], args)
    send_osc(client, paths.arc_group2[index], args)
  end

  local function send_arc_led(client, ring, led, level)
    send_arc_led_index(client, helpers.arc_index(ring, led), level)
  end

  local function send_grid_state_to_client(client, force, retry_only)
    if force then
      for index = 1, constants.GRID_CELL_COUNT do
        local current = runtime.grid_state.current[index]
        send_grid_led_index(client, index, current)
        client.grid_sent[index] = current
      end
      return
    end

    local indices = retry_only and runtime.grid_state.retry_list or runtime.grid_state.dirty_list
    for i = 1, #indices do
      local index = indices[i]
      local current = runtime.grid_state.current[index]
      if retry_only or client.grid_sent[index] ~= current then
        send_grid_led_index(client, index, current)
        client.grid_sent[index] = current
      end
    end
  end

  local function send_arc_state_to_client(client, force, retry_only)
    if force then
      for index = 1, constants.ARC_LED_COUNT do
        local current = runtime.arc_state.current[index]
        send_arc_led_index(client, index, current)
        client.arc_sent[index] = current
      end
      return
    end

    local indices = retry_only and runtime.arc_state.retry_list or runtime.arc_state.dirty_list
    for i = 1, #indices do
      local index = indices[i]
      local current = runtime.arc_state.current[index]
      if retry_only or client.arc_sent[index] ~= current then
        send_arc_led_index(client, index, current)
        client.arc_sent[index] = current
      end
    end
  end

  local function send_grid_state(force, target_client, retry_only)
    if not fn.grid_touchosc_enabled(1) then
      return
    end

    if target_client ~= nil then
      send_grid_state_to_client(target_client, force, retry_only)
      return
    end

    for _, key in ipairs(runtime.client_order) do
      local client = runtime.clients[key]
      if fn.client_is_active(client) then
        send_grid_state_to_client(client, force, retry_only)
      end
    end
  end

  local function send_arc_state(force, target_client, retry_only)
    if not fn.arc_touchosc_enabled(1) then
      return
    end

    if target_client ~= nil then
      send_arc_state_to_client(target_client, force, retry_only)
      return
    end

    for _, key in ipairs(runtime.client_order) do
      local client = runtime.clients[key]
      if fn.client_is_active(client) then
        send_arc_state_to_client(client, force, retry_only)
      end
    end
  end

  local function parse_grid_press(path, args)
    local index = tonumber(path:match("^" .. osc_paths.grid_prefix .. "(%d+)$"))
    if index == nil or index < 1 or index > constants.GRID_CELL_COUNT then
      return nil
    end

    local x = ((index - 1) % constants.GRID_COLS) + 1
    local y = math.floor((index - 1) / constants.GRID_COLS) + 1
    local z = (tonumber(args[1]) or 0) > 0 and 1 or 0
    return x, y, z
  end

  local function handle_grid_press(client, args, path)
    local x, y, z = parse_grid_press(path, args)
    if x == nil then
      return false
    end

    if fn.grid_touchosc_enabled(1) and runtime.grid_vports[1].key then
      runtime.grid_vports[1].key(x, y, z)
    end
    if z == 0 then
      local index = helpers.grid_index(x, y)
      local level = runtime.grid_state.current[index]
      send_grid_led(client, x, y, level)
      client.grid_sent[index] = level
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
    local ring, suffix = path:match("^" .. osc_paths.arc_prefix .. "knob(%d+)(/[%w_]+)$")
    if ring == nil or suffix == nil then
      return nil
    end

    ring = tonumber(ring)
    if ring == nil or ring < 1 or ring > constants.ARC_COLS then
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
      if fn.arc_touchosc_enabled(1) and runtime.arc_vports[1].key then
        runtime.arc_vports[1].key(ring, value)
      end
      return true
    end

    if kind == "encoder" then
      local delta = arc_delta_for_client(client, ring, value)
      if delta ~= 0 and fn.arc_touchosc_enabled(1) and runtime.arc_vports[1].delta then
        runtime.arc_vports[1].delta(ring, delta)
      end
      return true
    end

    return false
  end

  local function handle_connection(args, from)
    local requested = (tonumber(args[1]) or 1) > 0
    if not requested then
      local host, port = fn.normalize_from(from)
      local client = runtime.clients[fn.client_key(host, port)]
      if client ~= nil then
        client.last_seen = fn.now_s()
        fn.mark_dirty()
      end
      return true
    end

    local client = fn.ensure_client(from)
    client.active = true
    client.last_seen = fn.now_s()
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

    if path == osc_paths.connection then
      return handle_connection(args or {}, from)
    end

    if util.string_starts(path, osc_paths.grid_prefix) then
      local x = parse_grid_press(path, args or {})
      if x == nil then
        return false
      end
      local client, created, reactivated = fn.ensure_client(from)
      if created or reactivated then
        send_connected(client, true)
        send_grid_state(true, client)
        send_arc_state(true, client)
      end
      return handle_grid_press(client, args or {}, path)
    end

    if util.string_starts(path, osc_paths.arc_prefix) then
      local ring = parse_arc_message(path, args or {})
      if ring == nil then
        return false
      end
      local client, created, reactivated = fn.ensure_client(from)
      if created or reactivated then
        send_connected(client, true)
        send_grid_state(true, client)
        send_arc_state(true, client)
      end
      return handle_arc_message(client, args or {}, path)
    end

    return false
  end

  function runtime.resend_state(target_client, include_connected)
    if target_client ~= nil then
      if include_connected ~= false then
        send_connected(target_client, true)
      end
      send_grid_state(true, target_client)
      send_arc_state(true, target_client)
      fn.mark_dirty()
      return
    end

    for _, key in ipairs(runtime.client_order) do
      local client = runtime.clients[key]
      if fn.client_is_active(client) then
        if include_connected ~= false then
          send_connected(client, true)
        end
        send_grid_state(true, client)
        send_arc_state(true, client)
      end
    end
    fn.mark_dirty()
  end

  function runtime.run_light_test()
    for _, key in ipairs(runtime.client_order) do
      local client = runtime.clients[key]
      if fn.client_is_active(client) then
        send_connected(client, true)
        for y = 1, constants.GRID_ROWS do
          for x = 1, constants.GRID_COLS do
            send_grid_led(client, x, y, ((x + y) % 2 == 0) and 12 or 3)
          end
        end
      end
    end

    if fn.grid_physical_enabled(1) then
      core.grid.vports[1]:all(0)
      for y = 1, constants.GRID_ROWS do
        for x = 1, constants.GRID_COLS do
          core.grid.vports[1]:led(x, y, ((x + y) % 2 == 0) and 12 or 3)
        end
      end
      core.grid.vports[1]:refresh()
    end

    local quarter = math.pi * 0.5
    local tau = math.pi * 2
    local step = tau / constants.ARC_ROWS
    for _, key in ipairs(runtime.client_order) do
      local client = runtime.clients[key]
      if fn.client_is_active(client) then
        for ring = 1, constants.ARC_COLS do
          for led = 1, constants.ARC_ROWS do
            local sa = step * (led - 1)
            local sb = step * led
            local lit = math.max(0, math.min(sb, quarter) - math.max(sa, 0)) > 0
            send_arc_led(client, ring, led, lit and 15 or 0)
          end
        end
      end
    end

    if fn.arc_physical_enabled(1) then
      core.arc.vports[1]:all(0)
      for ring = 1, constants.ARC_COLS do
        for led = 1, constants.ARC_ROWS do
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
    fn.mark_dirty()
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
    fn.mark_dirty()
  end

  function runtime.dispatch_grid_key(id, x, y, state)
    core.norns_grid_key(id, x, y, state)
    local device = core.grid.devices[id]
    local port = device and device.port or nil
    if port and fn.grid_physical_enabled(port) and runtime.grid_vports[port].key then
      runtime.grid_vports[port].key(x, y, state)
    end
  end

  function runtime.dispatch_grid_tilt(id, x, y, z)
    core.norns_grid_tilt(id, x, y, z)
    local device = core.grid.devices[id]
    local port = device and device.port or nil
    if port and fn.grid_physical_enabled(port) and runtime.grid_vports[port].tilt then
      runtime.grid_vports[port].tilt(x, y, z)
    end
  end

  function runtime.dispatch_arc_add(id, serial, name, dev)
    core.norns_arc_add(id, serial, name, dev)
    runtime.refresh_ports()
    if runtime.arc_api.add then
      runtime.arc_api.add(core.arc.devices[id])
    end
    fn.mark_dirty()
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
    fn.mark_dirty()
  end

  function runtime.dispatch_arc_key(id, ring, state)
    core.norns_arc_key(id, ring, state)
    local device = core.arc.devices[id]
    local port = device and device.port or nil
    if port and fn.arc_physical_enabled(port) and runtime.arc_vports[port].key then
      runtime.arc_vports[port].key(ring, state)
    end
  end

  function runtime.dispatch_arc_delta(id, ring, delta)
    core.norns_arc_delta(id, ring, delta)
    local device = core.arc.devices[id]
    local port = device and device.port or nil
    if port and fn.arc_physical_enabled(port) and runtime.arc_vports[port].delta then
      runtime.arc_vports[port].delta(ring, delta)
    end
  end

  fn.send_connected = send_connected
  fn.send_grid_led = send_grid_led
  fn.send_arc_led = send_arc_led
  fn.send_grid_state = send_grid_state
  fn.send_arc_state = send_arc_state
end
