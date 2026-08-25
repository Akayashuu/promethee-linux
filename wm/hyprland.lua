-- Promethee's overlay windows, for a Hyprland running the Lua config provider
-- (end-4/dots-hyprland and friends, `hyprctl systeminfo | grep configProvider`).
--
--   require("promethee")
--
-- in ~/.config/hypr/hyprland.lua, or paste the rules into custom/rules.lua.
-- `./build.sh --install` drops this file next to that config; the require line
-- is yours to add. See wm/hyprland.conf for why any of this is needed, and for
-- the list of window names to write your own rules against.

local match = { class = "^(promethee)$", title = "^(Promethee .+)$" }

-- Wayland drops alwaysOnTop, skipTaskbar and the window's own placement, so
-- every overlay arrives looking like an ordinary window and gets tiled. The
-- collapsed chat panel is the one you notice: a transparent rectangle with a
-- launcher bubble in the corner, holding a tile it never draws in.
hl.window_rule({ match = match, float = true })
hl.window_rule({ match = match, pin = true })
hl.window_rule({ match = match, no_initial_focus = true })

-- They paint their own shape over your wallpaper, so anything the compositor
-- draws around them lands on the transparent part.
hl.window_rule({ match = match, no_shadow = true })
hl.window_rule({ match = match, no_blur = true })

-- Nothing tells Hyprland where an overlay wanted to be, so it centres them.
-- Upstream anchors the chat 16px from the bottom left corner:
--
-- hl.window_rule({ match = { title = "^(Promethee Panel dm)$" }, move = { "16", "100%-h-16" } })
