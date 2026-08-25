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

## Requirements

- Node ≥ 20, npm, python3, curl
- A C++ toolchain: `base-devel` (Arch) / `build-essential` (Debian)
- `libsecret`, for keytar
- A window backend: **Hyprland**, **Sway**, or **X11 + xdotool**

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
5. Applies the five patches below
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

### 4. Auto-updater off

`electron-updater`'s Linux path hard-requires an `APPIMAGE` env var and throws
`ERR_UPDATER_OLD_FILE_NOT_FOUND` without one. There's no Linux release channel
anyway, so its own `isUpdaterActive()` guard is answered with `false`.

### 5. Opaque main window

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
build.sh                          orchestration
scripts/extract-resources.py      pulls resources/ out of the release package
scripts/apply-patches.mjs         bundle rewrites
scripts/update-check.sh           what the daily timer runs
patches/linux-active-window.js    the active-window shim
patches/promethee-control.js      the control socket
docs/protocol.md                  the socket's contract with its clients
clients/promethee-ctl             the socket from a shell
clients/quickshell/               bar widget and its installer
```

## Licence

Everything in this repository is **MIT**.

Promethee itself is **PolyForm Noncommercial 1.0.0**: personal use is fine,
redistribution is not. Nothing here ships Promethee: the build fetches the
official Windows release at build time, on your machine, and leaves the result
there. Don't publish the output.
