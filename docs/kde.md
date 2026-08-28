# Promethee on KDE Plasma

This page is for **KDE Plasma**, especially Wayland. Hyprland, Sway and
plain X11+xdotool users can ignore it.

## 0. Check the session

```bash
echo "$XDG_CURRENT_DESKTOP" "$XDG_SESSION_TYPE"
```

You want something like:

```
KDE wayland
```

`KDE x11` also works; you can use `xdotool` instead of `kdotool` there.

## 1. Install the extra tools

Same toolchain as the README, plus `kdotool` (talks to KWin) and a wallet
for the login:

```bash
sudo pacman -S --needed base-devel git nodejs npm python curl libsecret
yay -S kdotool-bin
```

Check `kdotool`:

```bash
which kdotool
kdotool getactivewindow
kdotool getactivewindow getwindowclassname
```

Expected:

```
/usr/bin/kdotool
{01234567-89ab-cdef-0123-456789abcdef}
kitty
```

The UUID and the class will differ. If the first command prints nothing,
or DBus errors, stop: tracking will not work.

`kdotool getactivewindow getwindowname` may print the command you just
ran. That is Kitty putting the command in the title. Harmless.

## 2. Build

From the repo root:

```bash
./build.sh --install
```

Then:

```bash
export PATH="$HOME/.local/bin:$PATH"
hash -r
command -v promethee
```

That should print `$HOME/.local/bin/promethee`.

## 3. Keep the login (KWallet)

Without this, the terminal keeps you signed in and the task-manager icon
does not.

### One-shot from a terminal

Plasma 6:

```bash
PROMETHEE_PASSWORD_STORE=kwallet6 promethee
```

Plasma 5:

```bash
PROMETHEE_PASSWORD_STORE=kwallet5 promethee
```

No wallet at all (last resort):

```bash
PROMETHEE_PASSWORD_STORE=basic promethee
```

Log in, quit from the tray, run the same command again. You should still
be signed in.

### Make it stick for the icon and the pin

Plasma’s task manager often starts the binary **without** the variables
from your shell or from `Exec=env …` in the `.desktop`. Put the flag in
the launcher the build wrote.

See what it is now:

```bash
cat "$(command -v promethee)"
# usually a symlink to:
cat "$HOME/.local/bin/promethee"
```

You will see something like:

```bash
#!/usr/bin/env bash
exec "/home/YOU/promethee-linux/dist/.runtime/node_modules/electron/dist/promethee" "$@"
```

Edit that file (`nano` / `nvim` on the path `cat` printed). Keep the
`exec "…/electron/dist/promethee"` path **exactly**, and make it:

```bash
#!/usr/bin/env bash
export PROMETHEE_PASSWORD_STORE="${PROMETHEE_PASSWORD_STORE:-kwallet6}"
exec "/home/YOU/promethee-linux/dist/.runtime/node_modules/electron/dist/promethee" --password-store=kwallet6 "$@"
```

Replace `/home/YOU/promethee-linux/...` with the path that was already
there. Then:

```bash
chmod +x /path/to/that/promethee
```

Also fix the desktop file so a menu launch matches:

```bash
grep '^Exec=' ~/.local/share/applications/promethee.desktop
```

Set it to your real launcher path:

```bash
sed -i "s|^Exec=.*|Exec=$HOME/.local/bin/promethee|" ~/.local/share/applications/promethee.desktop
grep '^Exec=' ~/.local/share/applications/promethee.desktop
update-desktop-database ~/.local/share/applications
```

Then:

1. Quit Promethee from the tray.
2. Unpin it from the task manager if it is pinned.
3. Start it once with `promethee` or from the menu.
4. Pin it again.

`./build.sh` overwrites `dist/promethee`. After a rebuild, put the two
lines back.

## 4. See the overlay titles

Overlays cannot place themselves on Wayland. KWin rules need a title.

With Promethee running:

```bash
kdotool search --class promethee getwindowname
```

Typical names:

| Title                        | What it is                                |
|------------------------------|-------------------------------------------|
| `Promethee`                  | dashboard — leave it as a normal window   |
| `Promethee HUD`              | timer pill                                |
| `Promethee Panel dm`         | chat bubble                               |
| `Promethee Panel panel`      | opened chat (another window)              |
| `Promethee Panel quests`     | quests                                    |
| `Promethee Notifications`    | toasts                                    |
| `Promethee Session Complete` | end-of-session recap (needs the keyboard) |
| `Promethee Session End`      | end effect                                |
| `Promethee Poster`           | share image                               |

If a name differs, use whatever that command printed.

## 5. KWin rules

Open:

**System Settings → Window Management → Window Rules → New**

Positions are pixels from the top-left of the *combined* desktop. They
change with resolution and with a second monitor. There is no
`100%-w-16` like Hyprland.

On every rule that sets a position:

- Position: **Force** (not “Apply initially”)
- **Add property → Ignore requested geometry → Force → Yes**

Otherwise Electron puts the window back in the middle.

You cannot drag these windows. Change the two numbers, click Apply.

### Rule: overlays (no keyboard lock)

Do **not** set Accept focus = No here. That also hits
`Promethee Session Complete`: the text field shows a caret, keys go to
the Plasma launcher. A later “Accept focus = Yes” rule does not fix it.

- Description: `overlays Promethee`
- Window class: Exact match, `promethee`
- Keep above: Force, Yes
- Skip taskbar: Force, Yes
- No titlebar and frame: Force, Yes
- Accept focus: **do not add this property**

### Rule: HUD

- Description: `HUD`
- Window class: Exact match, `promethee`
- Window title: Exact match, `Promethee HUD`
- Position: Force, e.g. `900` × `40` (tune)
- Ignore requested geometry: Force, Yes

### Rule: chat bubble

- Description: `Promethee chat`
- Window class: Exact match, `promethee`
- Window title: Exact match, `Promethee Panel dm`
- Position: Force (tune)
- Ignore requested geometry: Force, Yes

### Rule: opened chat

The bubble and the panel are two windows. Do not reuse the
notifications rule.

- Description: `Promethee panel`
- Window class: Exact match, `promethee`
- Window title: Exact match, `Promethee Panel panel`
- Position: Force
- Size: Force, e.g. `420` × `560` if the thread is unreadable
- Ignore requested geometry: Force, Yes

### Rule: notifications

- Description: `Promethee notifs`
- Window class: Exact match, `promethee`
- Window title: Exact match, `Promethee Notifications`
- Position: Force
- Ignore requested geometry: Force, Yes

If the title is wrong: **Detect window properties**, click the toast,
copy the title it fills in.

### Session Complete cannot type

```bash
# nothing to run — this is the overlays rule
```

Remove **Accept focus** from `overlays Promethee` (red trash on that
row). Click the recap field again. Keys should stay in Promethee, not
open the app launcher.

## 6. Debug

```bash
echo "$XDG_CURRENT_DESKTOP" "$XDG_SESSION_TYPE"
PROMETHEE_LINUX_DEBUG=1 PROMETHEE_PASSWORD_STORE=kwallet6 promethee
kdotool search --class promethee getwindowname
```

The debug log should mention the `kwin` backend when you change the
focused window.

Session file after a clean quit:

```bash
ls -l ~/.config/Promethee/session.bin ~/.config/Promethee/linux-shutdown.log
```

If `session.bin` is missing after an icon launch, the launcher still
has no `--password-store=kwallet6` (step 3).
