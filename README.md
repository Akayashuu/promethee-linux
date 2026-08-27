# promethee-linux

Run [Promethee](https://promethee.io) natively on Linux.

Promethee ships for Windows and macOS only. The Electron app itself is
portable. The missing piece is a Linux backend for the one thing the product is
built on: knowing which window you're looking at.

This repo adds that backend, then builds a native app from Promethee's own
Windows release. **No Promethee code is redistributed here.**

## Install

```bash
git clone https://github.com/Akayashuu/promethee-linux
cd promethee-linux
./build.sh --install
promethee
```

`build.sh` downloads the current Windows build from Promethee's release
channel, verifies it, patches it for Linux and writes `dist/`. First run pulls
~400 MiB; later builds reuse it.

Verified on Promethee 1.3.26 / Electron 43.2.0 under Hyprland.

`--install` also leaves compositor rules for the app's overlay windows beside
your Hyprland or Sway config. Source them, or the HUD and the panels get tiled
like ordinary windows: [patch 7](#7-naming-the-overlay-windows) is what they are
for.

## Requirements

- Node ≥ 20, npm, python3, curl
- A C++ toolchain: `base-devel` (Arch) / `build-essential` (Debian)
- `libsecret`, for keytar
- A window backend: **Hyprland**, **Sway**, **KWin (KDE Plasma + kdotool)** or **X11 + xdotool**
  KDE Wayland: see [docs/kde.md](docs/kde.md).
## What works

| | |
|---|---|
| Activity tracking, sessions, quests, XP, leaderboards, HUD | yes |
| App blocking | no, the blocker is Win32-only |
| Launch at login | no, Electron reports `unsupported-platform` |
| Virtual-desktop pinning | no, Windows-only and already guarded upstream |

From the app's own database, tracking a real session:

```
window_events
  kitty     | kitty    | ~                                 | hyprland
  Discord   | discord  | #dev-coding | Agent Builder FR     | hyprland
  Promethee | electron | Promethee                         | hyprland
```

## How it works

```
release channel ──▶ extract ──▶ rebuild natives ──▶ patch ──▶ dist/
```

1. Reads Promethee's `RELEASES` manifest for the current build
2. Downloads that package and checks it against the published SHA-1
3. Extracts `resources/` (the `.nupkg` is a zip, so nothing has to be unpacked
   by hand)
4. Rebuilds `better-sqlite3` and `keytar` for this Electron's ABI
5. Applies the seven patches below
6. Fetches the matching Electron and writes `dist/promethee`

Nothing is pinned: the manifest names whichever build is current, so a rebuild
picks up a new release on its own.

Already have a copy of the app bundle, or want to stay on an older one? Point at
it instead of the channel:

```bash
./build.sh --source /path/to/resources
```

## Staying current

The app's own updater is off and its channel wouldn't apply here anyway, so
nothing would otherwise tell you a new Promethee is out:

```bash
./build.sh --check      # up to date (1.3.26)
```

Exit status is the interface: `0` current, `1` a newer release is out, `2` the
channel was unreachable. `--install` wires that into a daily systemd user timer
that notifies you when a rebuild is due:

```bash
systemctl --user list-timers promethee-update-check.timer
systemctl --user disable --now promethee-update-check.timer   # opt out
```

A new release can also move the ground under a patch. That's not silent: the
anchors are structural, and a required patch that stops matching fails the
build rather than producing a half-working app.

## The patches

The bundles are minified and their identifiers change on every upstream build,
so each patch anchors on a **structural signature** rather than a name. A
required patch that matches nothing aborts the build, because a loud failure
beats a half-working app.

### 1. Linux active-window backend

Upstream's dispatcher falls through on anything that isn't Windows or macOS:

```js
async function Aw(e = {}) {
  if (process.platform === "win32") return Iqe(e);   // get-windows
  if (process.platform !== "darwin") return null;    // ← Linux lands here
  ...
}
```

It returns `null`, silently, forever: no active app, no sessions, no XP. The
patch inserts a `linux` branch calling an injected shim that returns the same
shape upstream builds from `get-windows`:

```js
{ owner: { name, bundleId, processId, path }, title, source, frame }
```

| Backend | Transport | Requires |
|---|---|---|
| Hyprland | IPC socket directly, `hyprctl` fallback | `HYPRLAND_INSTANCE_SIGNATURE` |
| Sway | `swaymsg -t get_tree` | `SWAYSOCK` |
| X11 | `xdotool` | `DISPLAY` |

Window classes are slugs (`code-oss`, `org.gnome.Nautilus`), so the shim indexes
your `.desktop` entries once and maps class → `Name=`, so you get the names your
launcher shows. Executable paths come from `/proc/<pid>/exe`. Results are cached
for 900 ms so a burst of callers doesn't become a burst of IPC round-trips.

### 2. Control socket

The app is tray-first, and everything it can do sits behind an `ipcMain`
handler reachable from its own renderer only. This patch wraps `ipcMain.handle`
as those handlers register and serves them over a Unix socket, one JSON object
per line. That is enough to drive a focus session from outside the app, and to
render one in a bar:

```
-> {"id":1,"channel":"session:start","args":["Focus"]}
<- {"id":1,"ok":true,"data":{"success":true}}
<- {"event":"state","state":{"session":{…},"profile":{…},"today":{…}}}
```

State is pushed every two seconds and after every call, so a client renders a
live timer without polling. The socket is 0600 in the user's own runtime
directory; it is a full remote control for the app, so treat it as you would the
session bus. [docs/protocol.md](docs/protocol.md) is the contract.

### 3. Naming the password store

Without this, the app forgets your login every time it closes.

Chromium picks its password store from `XDG_CURRENT_DESKTOP`. On Hyprland, as
on any compositor it hasn't heard of, it recognises nothing, and
`safeStorage.isEncryptionAvailable()` comes back `false`. The app takes that at
its word:

```
[auth] writeStoredSession: safeStorage unavailable, cannot persist
[auth] Session NOT saved (getAccessToken rotated)
```

`session.bin` is never written at all. The login lives in memory and dies with
the process, so quitting logs you out and every restart is a fresh install as
far as auth is concerned. The Secret Service was running the whole time; it
just has to be named. The shim appends `--password-store=gnome-libsecret`
unless one was passed on the command line. `PROMETHEE_PASSWORD_STORE` overrides
it: `basic` for a machine with no keyring, where the alternative is not
persisting at all.

The shim also writes `linux-shutdown.log` in `userData`: one line per start,
carrying whether `session.bin` survived and which backend was selected, then
`will-quit` and `exit`. It's unconditional and on disk because the question it
answers outlives the process being asked. It's what turned "the login is lost
somewhere" into the two lines above.

It also settled a wrong guess. Being killed mid-token-rotation looked like the
culprit, since nothing asks a Windows tray app to stop while on Linux
everything does. The log shows a `SIGTERM` reaching `will-quit` and `exit 0`
with the shim's own handler never firing: Electron already stops cleanly on a
signal. That handler stays as a floor under the behaviour, not as a fix for it.

### 4. Surviving a hard reboot

Naming the password store gets the login written to disk. Keeping it there is a
second problem, and a machine that stops without asking is what finds it.

The logged-in state is three files in `userData`: `session.bin` (the tokens,
through `safeStorage`), `has-session.json` (the flag the app checks before it
will even read the tokens) and `session-user.json` (the cached user, which is
what lets a start with no network keep you signed in). None of the three is
written durably. `session.bin` is `fsync`ed but opened with `"w"`, so it's
truncated in place and the directory entry is never synced; the other two are a
bare `writeFileSync`. On ext4 with delayed allocation, a power cut or a forced
reboot can take all three, and the log says so afterwards:

```
2026-08-25T04:57:15.275Z started pid 1126883, session.bin present
<a hole of NULs where the tail of the log should be>
2026-08-25T10:09:18.182Z started pid 9818, session.bin MISSING
```

Nothing signed out and nothing expired. The app comes back calling itself a new
install, and a session that was still running is left orphaned in the database.

So the shim keeps its own copy, written the way the originals should have been:
temp file, `fsync`, `rename`, then `fsync` of the directory, which is what makes
the rename itself survive. At startup, any of the three that is missing is put
back from the copy.

What it must never do is resurrect a session that really is over, and that case
is distinguishable. Signing out and a refresh token the server rejects both
delete these files *while the app is running*, so a disappearance this process
witnesses is deliberate and takes the copy with it. A disappearance that has
already happened by the time the process starts had no author. That is the
crash, and only that gets restored. `linux-shutdown.log` records which of the
two happened: `session.bin restored` is a reboot this machine shrugged off.

### 5. Auto-updater off

`electron-updater`'s Linux path hard-requires an `APPIMAGE` env var and throws
`ERR_UPDATER_OLD_FILE_NOT_FOUND` without one. There's no Linux release channel
anyway, so its own `isUpdaterActive()` guard is answered with `false`.

### 6. Opaque main window

The main window has two option branches for three platforms:

```js
...process.platform === "win32"
  ? { transparent: !1, backgroundColor: "#1D1D1D" }
  : { transparent: !0, vibrancy: "under-window", visualEffectState: "…" }
```

Linux lands in the macOS one. There, the `vibrancy` layer is what paints the
background; here it's a silent no-op, and the page doesn't paint one either:

```css
html,body,#root{ … background:0 0; … }
```

So nothing fills the window. Frameless and see-through, it opens as an empty
rectangle over your wallpaper. The patch widens the condition rather than
rewriting the branch, so Linux gets the opaque background Windows already uses
and macOS keeps the exact object upstream wrote.

### 7. Naming the overlay windows

The app is built around overlays: the HUD pill, the chat and quest panels,
notifications, the end-of-session effect. Each is a frameless, transparent,
`focusable: false` window that places itself over your work and paints only the
few pixels it needs:

```js
new BrowserWindow({ x, y, transparent: !0, backgroundColor: "#00000000",
                    alwaysOnTop: !0, focusable: !1, skipTaskbar: !0,
                    visibleOnAllWorkspaces: !0, type: process.platform === "darwin" ? "panel" : void 0 })
```

On Wayland, every option on that second and third line is a no-op, and so is
the window's own `x`/`y`: a client cannot place itself, cannot ask to stay on
top, and cannot say it isn't a normal window. A tiling compositor reads a
toplevel like any other and gives it a tile. The chat panel is the one you
notice. Collapsed, it draws a launcher bubble in one corner and leaves the rest
of its surface transparent, so what lands on screen is a large invisible
rectangle sitting on half a workspace. Its input region is empty, so clicking
does not even reach it.

Only the compositor can put that back, and a rule needs something to match on.
Every window here is class `promethee` titled `Promethee`, which is nothing to
match on. So the patch names them, from the role each window already loads
with:

```
file:///…/index.html?mode=panel-block&block=dm&collapsed=1  →  Promethee Panel dm
file:///…/index.html?mode=floating                          →  Promethee HUD
file:///…/index.html?mode=full                              →  Promethee
```

The dashboard keeps the bare name and stays an ordinary, tileable window.
Everything else becomes `Promethee <role>`, and the renderer is not allowed to
title over it afterwards. [wm/](wm/) has the rules that follow from that, for
Hyprland and Sway, and `--install` puts the right one next to your config:

```
windowrule = float,        class:^(promethee)$, title:^(Promethee .+)$
windowrule = pin,          class:^(promethee)$, title:^(Promethee .+)$
windowrule = bordersize 0, class:^(promethee)$, title:^(Promethee .+)$
windowrule = rounding 0,   class:^(promethee)$, title:^(Promethee .+)$
windowrule = move 16 100%-h-16, title:^(Promethee Panel dm)$
```

Floating them is half the job. An overlay paints its own shape and leaves the
rest of its surface transparent, so a border and rounded corners land on the
nothing around it: the invisible window becomes a rounded rectangle drawn over
your terminal. And since the app's own placement is lost on the way to Wayland,
the compositor centres what upstream put in a corner, so the last rule puts the
chat back where its launcher belongs.

Sourcing them is left to you, and it is one line. Nothing else in this repo
touches your compositor's config.

## Clients

The control socket is the integration point: the focus timer, and starting or
ending a session, without opening a window. There is a Quickshell widget here
because that is what this machine runs. Nothing about the socket is specific to
it.

```bash
./clients/quickshell/install.sh      # bar widget for dots-hyprland "ii"
qs -c ii kill && qs -c ii -d
```

For any other bar (Waybar, eww, polybar), `promethee-ctl` puts the socket on
stdout, and `--install` links it into `~/.local/bin`:

```bash
promethee-ctl state                       # one JSON object, then exit
promethee-ctl watch                       # one per push, until interrupted
promethee-ctl call session:start Focus
```

[clients/README.md](clients/README.md) has the wiring for each;
[docs/protocol.md](docs/protocol.md) is what a new client is written against.

## Debugging

```bash
PROMETHEE_LINUX_DEBUG=1 ./dist/promethee
PROMETHEE_DEBUG=1 ./dist/promethee      # the app's own auth log, /tmp/promethee-debug.log
```

Logs which backend answered, how many desktop entries were indexed, and any
backend failures. To exercise the shim on its own:

```bash
node -e 'require("./patches/linux-active-window.js");
         globalThis.__prometheeLinuxActiveWindow().then(r => console.log(r))'
```

## Layout

```
build.sh                              orchestration
scripts/extract-resources.py          pulls resources/ out of the release package
scripts/apply-patches.mjs             bundle rewrites
scripts/update-check.sh               what the daily timer runs
patches/linux-active-window.js        the active-window shim
patches/promethee-control.js          the control socket
patches/linux-session-persistence.js  the login's crash-durable copy
patches/linux-overlay-windows.js      one name per window, for wm rules
wm/                                   those rules, for Hyprland and Sway
docs/protocol.md                      the socket's contract with its clients
clients/promethee-ctl                 the socket from a shell
clients/quickshell/                   bar widget and its installer
```

## Licence

Everything in this repository is **MIT**.

Promethee itself is **PolyForm Noncommercial 1.0.0**: personal use is fine,
redistribution is not. Nothing here ships Promethee: the build fetches the
official Windows release at build time, on your machine, and leaves the result
there. Don't publish the output.
