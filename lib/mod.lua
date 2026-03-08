local mod = require "core/mods"

local runtime = require "nagatomo/lib/runtime"
local menu = require "nagatomo/lib/menu"

runtime.install()

runtime.set_menu_redraw(function()
  if _menu and _menu.mode and _menu.page and _menu.page == mod.this_name then
    menu.redraw()
  end
end)

mod.hook.register("script_pre_init", mod.this_name .. " menu reset pre init", function()
  menu.reset()
end)

mod.hook.register("script_post_cleanup", mod.this_name .. " menu reset post cleanup", function()
  menu.reset()
end)

mod.menu.register(mod.this_name, menu)

return runtime
