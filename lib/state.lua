return function(runtime, ctx)
  local util = ctx.util
  local tabutil = ctx.tabutil
  local constants = ctx.constants
  local helpers = ctx.helpers
  local fn = ctx.fn

  runtime.prefs = {
    grid_policy = "auto",
    arc_policy = "auto",
    retry_writes_enabled = false,
  }
  runtime.clients = {}
  runtime.client_order = {}
  runtime.menu_redraw = nil

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

  local function reset_client_transient(client)
    client.grid_sent = helpers.create_linear_buffer(constants.GRID_CELL_COUNT, constants.SENT_UNKNOWN)
    client.arc_sent = helpers.create_linear_buffer(constants.ARC_LED_COUNT, constants.SENT_UNKNOWN)
    client.arc_encoder_pos = helpers.create_linear_buffer(constants.ARC_COLS, constants.SENT_UNKNOWN)
  end

  local function make_client(host, port, last_seen, active)
    local key = client_key(host, port)
    local client = {
      key = key,
      host = host,
      port = port,
      to = { host, tostring(port) },
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
        local client = make_client(entry.host, entry.port, entry.last_seen, false)
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

    if constants.POLICY_LABELS[saved.grid_policy] then
      runtime.prefs.grid_policy = saved.grid_policy
    end
    if constants.POLICY_LABELS[saved.arc_policy] then
      runtime.prefs.arc_policy = saved.arc_policy
    end
    if type(saved.retry_writes_enabled) == "boolean" then
      runtime.prefs.retry_writes_enabled = saved.retry_writes_enabled
    elseif type(saved.scrub_enabled) == "boolean" then
      runtime.prefs.retry_writes_enabled = saved.scrub_enabled
    end
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

  local function grid_has_physical(port)
    local vport = ctx.core.grid.vports[port]
    return vport ~= nil and vport.device ~= nil
  end

  local function arc_has_physical(port)
    local vport = ctx.core.arc.vports[port]
    return vport ~= nil and vport.device ~= nil
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
      return ctx.core.grid.vports[port].device
    end
    if mode == "virtual" then
      return runtime.grid_virtual
    end
    return nil
  end

  local function current_arc_device(port)
    local mode = arc_port_mode(port)
    if mode == "physical" then
      return ctx.core.arc.vports[port].device
    end
    if mode == "virtual" then
      return runtime.arc_virtual
    end
    return nil
  end

  local function grid_port_name(port)
    local mode = grid_port_mode(port)
    if mode == "physical" then
      return ctx.core.grid.vports[port].name
    end
    if mode == "virtual" then
      return runtime.grid_virtual.name
    end
    return "none"
  end

  local function grid_port_cols(port)
    local mode = grid_port_mode(port)
    if mode == "physical" then
      return ctx.core.grid.vports[port].cols
    end
    if mode == "virtual" then
      return constants.GRID_COLS
    end
    return 0
  end

  local function grid_port_rows(port)
    local mode = grid_port_mode(port)
    if mode == "physical" then
      return ctx.core.grid.vports[port].rows
    end
    if mode == "virtual" then
      return constants.GRID_ROWS
    end
    return 0
  end

  local function arc_port_name(port)
    local mode = arc_port_mode(port)
    if mode == "physical" then
      return ctx.core.arc.vports[port].name
    end
    if mode == "virtual" then
      return runtime.arc_virtual.name
    end
    return "none"
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

  local function cycle_policy(kind, direction)
    local current = runtime.prefs[kind]
    local index = 1
    for i, name in ipairs(constants.POLICY_ORDER) do
      if name == current then
        index = i
        break
      end
    end
    if direction and direction < 0 then
      index = ((index - 2 + #constants.POLICY_ORDER) % #constants.POLICY_ORDER) + 1
    else
      index = (index % #constants.POLICY_ORDER) + 1
    end
    runtime.prefs[kind] = constants.POLICY_ORDER[index]
    save_prefs()
    runtime.refresh_ports()
    runtime.resend_state(nil, false)
    print(string.format("[nagatomo] %s policy -> %s", kind, constants.POLICY_LABELS[runtime.prefs[kind]]))
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

  function runtime.describe_client(client)
    local state = client_is_active(client) and "active" or "saved"
    return string.format("%s:%s %s %s", client.host, tostring(client.port), state, age_string(client.last_seen))
  end

  function runtime.status()
    local active_clients = runtime.active_clients()
    local saved_clients = runtime.saved_clients()
    return {
      grid_policy = constants.POLICY_LABELS[runtime.prefs.grid_policy],
      arc_policy = constants.POLICY_LABELS[runtime.prefs.arc_policy],
      retry_writes_enabled = runtime.prefs.retry_writes_enabled,
      active_clients = active_clients,
      saved_clients = saved_clients,
      grid_bound = runtime.grid_vports[1].key ~= nil or runtime.grid_vports[1].tilt ~= nil,
      arc_bound = runtime.arc_vports[1].key ~= nil or runtime.arc_vports[1].delta ~= nil,
      script_name = norns.state.name,
      total_active = #active_clients,
    }
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
      fn.clear_grid_retry_pending()
      fn.clear_arc_retry_pending()
    end
    save_prefs()
    print(string.format("[nagatomo] retry writes -> %s", runtime.prefs.retry_writes_enabled and "on" or "off"))
    mark_dirty()
  end

  function runtime.disconnect_all_clients()
    for _, key in ipairs(runtime.client_order) do
      local client = runtime.clients[key]
      if client and client.active then
        fn.send_connected(client, false)
        client.active = false
        reset_client_transient(client)
      end
    end
    fn.clear_grid_dirty()
    fn.clear_grid_retry_pending()
    fn.clear_arc_dirty()
    fn.clear_arc_retry_pending()
    print("[nagatomo] disconnected all active clients")
    mark_dirty()
  end

  function runtime.set_menu_redraw(func)
    runtime.menu_redraw = func
  end

  fn.ensure_dir = ensure_dir
  fn.mark_dirty = mark_dirty
  fn.now_s = now_s
  fn.client_key = client_key
  fn.normalize_from = normalize_from
  fn.client_is_active = client_is_active
  fn.active_client_count = active_client_count
  fn.grid_touchosc_enabled = grid_touchosc_enabled
  fn.arc_touchosc_enabled = arc_touchosc_enabled
  fn.grid_physical_enabled = grid_physical_enabled
  fn.arc_physical_enabled = arc_physical_enabled
  fn.grid_port_mode = grid_port_mode
  fn.arc_port_mode = arc_port_mode
  fn.current_grid_device = current_grid_device
  fn.current_arc_device = current_arc_device
  fn.grid_port_name = grid_port_name
  fn.grid_port_cols = grid_port_cols
  fn.grid_port_rows = grid_port_rows
  fn.arc_port_name = arc_port_name
  fn.ensure_client = ensure_client
  fn.load_clients = load_clients
  fn.load_prefs = load_prefs
  fn.save_prefs = save_prefs
end
