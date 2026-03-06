-- SPDX-FileCopyrightText: 2026 Mateo Paredes Sepulveda
-- SPDX-License-Identifier: GPL-3.0-or-later

local mod = require "core/mods"
local util = require "util"

local runtime_key = mod.this_name .. ".runtime"
local runtime = package.loaded[runtime_key]
if runtime == nil then
  local candidates = {}
  if _path and _path.code and mod.this_name then
    table.insert(candidates, _path.code .. mod.this_name .. "/lib/runtime.lua")
  end
  table.insert(candidates, "lib/runtime.lua")

  for _, path in ipairs(candidates) do
    if util.file_exists(path) then
      runtime = dofile(path)
      break
    end
  end

  if runtime == nil then
    error("unable to load toga-shim runtime")
  end
  package.loaded[runtime_key] = runtime
end

runtime.install()

local menu = { index = 1 }

local function clip(text, width)
  return util.trim_string_to_width(text, width)
end

local function build_rows()
  local status = runtime.status()
  local rows = {
    {
      kind = "action",
      name = "Grid policy",
      value = function()
        return status.grid_policy
      end,
      action = runtime.cycle_grid_policy,
    },
    {
      kind = "action",
      name = "Arc policy",
      value = function()
        return status.arc_policy
      end,
      action = runtime.cycle_arc_policy,
    },
    {
      kind = "info",
      name = "Bindings",
      value = function()
        local parts = {}
        table.insert(parts, status.grid_bound and "grid" or "-")
        table.insert(parts, status.arc_bound and "arc" or "-")
        return table.concat(parts, " ")
      end,
    },
    {
      kind = "info",
      name = "Script",
      value = function()
        return status.script_name or "none"
      end,
    },
  }

  table.insert(rows, {
    kind = "section",
    name = string.format("Active (%d)", status.total_active),
  })

  if #status.active_clients == 0 then
    table.insert(rows, {
      kind = "info",
      name = "client",
      value = function()
        return "none"
      end,
    })
  else
    for _, client in ipairs(status.active_clients) do
      local label = runtime.describe_client(client)
      table.insert(rows, {
        kind = "info",
        name = "client",
        value = function()
          return label
        end,
      })
    end
  end

  table.insert(rows, {
    kind = "section",
    name = "Recent",
  })

  if #status.recent_clients == 0 then
    table.insert(rows, {
      kind = "info",
      name = "client",
      value = function()
        return "none"
      end,
    })
  else
    for _, client in ipairs(status.recent_clients) do
      local label = runtime.describe_client(client)
      table.insert(rows, {
        kind = "info",
        name = "client",
        value = function()
          return label
        end,
      })
    end
  end

  table.insert(rows, {
    kind = "section",
    name = "Actions",
  })

  table.insert(rows, {
    kind = "action",
    name = "Reconnect clients",
    value = function()
      return ""
    end,
    action = runtime.reconnect_known_clients,
  })

  table.insert(rows, {
    kind = "action",
    name = "Resend state",
    value = function()
      return ""
    end,
    action = function()
      runtime.resend_state(nil, true)
    end,
  })

  table.insert(rows, {
    kind = "action",
    name = "Clear active",
    value = function()
      return ""
    end,
    action = runtime.clear_active_clients,
  })

  table.insert(rows, {
    kind = "action",
    name = "Forget history",
    value = function()
      return ""
    end,
    action = runtime.forget_client_history,
  })

  table.insert(rows, {
    kind = "action",
    name = "Light test",
    value = function()
      return ""
    end,
    action = runtime.run_light_test,
  })

  return rows
end

local function current_rows()
  return build_rows()
end

local function selected_row()
  local rows = current_rows()
  return rows[menu.index], rows
end

function menu.init()
  menu.index = 1
  if screen.font_face then
    screen.font_face(1)
  end
  if screen.font_size then
    screen.font_size(8)
  end
end

function menu.deinit()
end

function menu.redraw()
  local rows = current_rows()
  menu.index = util.clamp(menu.index, 1, math.max(1, #rows))

  screen.clear()
  screen.level(15)
  screen.move(64, 10)
  screen.text_center("TOGA-SHIM")

  local visible = 5
  local top = util.clamp(menu.index - 2, 1, math.max(1, #rows - (visible - 1)))

  for line = 0, visible - 1 do
    local idx = top + line
    local row = rows[idx]
    if row == nil then
      break
    end

    local y = 18 + line * 10
    local selected = idx == menu.index

    if selected then
      screen.level(4)
      screen.move(6, y + 3)
      screen.line(122, y + 3)
      screen.stroke()
    end

    if row.kind == "section" then
      screen.level(selected and 15 or 10)
      screen.move(8, y)
      screen.text(string.upper(row.name))
    else
      screen.level(selected and 15 or 8)
      screen.move(10, y)
      screen.text(clip(row.name, 44))
      local value = row.value and row.value() or ""
      screen.move(122, y)
      screen.text_right(clip(value, 72))
    end
  end

  screen.update()
end

function menu.key(n, z)
  if z == 0 then
    return
  end

  if n == 1 or n == 2 then
    mod.menu.exit()
    return
  end

  if n == 3 then
    local row = selected_row()
    if row and row.kind == "action" and row.action then
      row.action()
      menu.redraw()
    end
  end
end

function menu.enc(n, d)
  if n ~= 2 then
    return
  end

  local rows = current_rows()
  menu.index = util.clamp(menu.index + (d > 0 and 1 or -1), 1, math.max(1, #rows))
  menu.redraw()
end

runtime.set_menu_redraw(function()
  if _menu and _menu.page and _menu.page == mod.this_name then
    menu.redraw()
  end
end)

mod.menu.register(mod.this_name, menu)

return runtime
