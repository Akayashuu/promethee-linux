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

-- They paint their own shape over your wallpaper, and most of that shape is
-- nothing at all. Anything the compositor draws around a window lands on the
-- transparent part instead, which is how an invisible window turns into a
-- rounded rectangle floating over your terminal.
hl.window_rule({ match = match, border_size = 0 })
hl.window_rule({ match = match, rounding = 0 })
hl.window_rule({ match = match, no_shadow = true })
hl.window_rule({ match = match, no_blur = true })
hl.window_rule({ match = match, no_anim = true })

-- Nothing tells Hyprland where an overlay wanted to be, so it centres them.
-- Upstream puts the chat 16px from the bottom left corner, under its launcher.
-- The Lua provider takes an expression rather than the `100%-h-16` of the
-- legacy config, and monitor_w, monitor_h, window_w and window_h are what it
-- knows. Percentages parse there and quietly do nothing.
hl.window_rule({
	match = { title = "^(Promethee Panel dm)$" },
	move = { 16, "(monitor_h-window_h-16)" },
})

-- The other panels are yours to place, since where they belong depends on
-- which corner you keep their launcher in:
--
-- hl.window_rule({
-- 	match = { title = "^(Promethee Panel quests)$" },
-- 	move = { "(monitor_w-window_w-16)", "(monitor_h-window_h-16)" },
-- })
