# promethee-linux

Run [Promethee](https://promethee.io) natively on Linux.

Promethee ships for Windows and macOS only. The Electron app is portable — the
missing piece is a Linux backend for the one thing the product is built on:
knowing which window you're looking at.

This repo adds that backend and builds a native app from a copy you already
own. **No Promethee code is redistributed here.**

```bash
git clone https://github.com/Akayashuu/promethee-linux
cd promethee-linux
./build.sh --install
promethee
```

Verified on Promethee 1.3.26 / Electron 43.2.0 under Hyprland.

## Status

| | |
|---|---|
| Activity tracking, sessions, quests, XP, leaderboards, HUD | works |
| App blocking | not ported — the blocker is Win32-only |
| Launch at login | Electron reports `unsupported-platform` |
| Virtual-desktop pinning | Windows-only, already guarded upstream |

Live proof from the app's own database, tracking a real session:

```
window_events
  kitty     | kitty    | ~                                 | hyprland
  Discord   | discord  | #dev-coding | Agent Builder FR     | hyprland
  Promethee | electron | Promethee                         | hyprland
```

## Requirements

- Node ≥ 20, npm, python3
- A C++ toolchain — `base-devel` (Arch) / `build-essential` (Debian)
- `libsecret` — for keytar
- A window backend: **Hyprland**, **Sway**, or **X11 + xdotool**

## Getting a copy to build from

Promethee has no Linux download, so install the Windows build under Wine once.
You only need the files — it doesn't have to run well:

```bash
WINEPREFIX=~/.wine-promethee wine Promethee-x.y.z-Setup.exe
```

`build.sh` then finds it automatically. Or point it anywhere:

```bash
./build.sh --source /path/to/Promethee/app-1.3.26/resources
```

Once built, `dist/` is self-contained and the Wine prefix can be deleted.

## How it works

```
your install ──▶ extract app.asar ──▶ rebuild natives ──▶ patch ──▶ dist/
```

1. Finds your install (Wine prefix, or `--source`)
2. Extracts `app.asar`
3. Rebuilds `better-sqlite3` and `keytar` for the right Electron ABI
4. Applies the patches below
5. Downloads the matching Electron, writes `dist/promethee`
6. `--install` adds a `.desktop` entry and `~/.local/bin/promethee`

### The patches

The bundles are minified and their identifiers change on every upstream build,
so each patch anchors on a **structural signature** rather than a name. A
required patch that matches nothing aborts the build — a loud failure beats a
half-working app.

**1 — Linux active-window backend**

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
your `.desktop` entries once and maps class → `Name=` — you get the names your
launcher shows. Executable paths come from `/proc/<pid>/exe`. Results are cached
for 900 ms so a burst of callers doesn't become a burst of IPC round-trips.

**2 — Control socket**

The app is tray-first and everything it can do sits behind an `ipcMain`
handler, reachable from its own renderer only. A third patch prepends a shim
that wraps `ipcMain.handle` as those handlers register, then serves them over a
Unix socket, one JSON object per line — enough to drive a focus session from
outside the app. That is what the [Quickshell bar
widget](quickshell/README.md) talks to.

**3 — A shutdown log, and a signal handler behind it**

The app forgets the login across a reboot. Supabase rotates the refresh token
on every refresh and the new one only reaches `session.bin` when the app writes
it, so a process killed between the two leaves a token Supabase has already
spent: the next start presents it, is told `Already Used`, and the app wipes the
session and asks for the e-mail again — its own auth log calls this the *zombie*
state.

Being killed mid-rotation was the obvious suspect, since nothing asks a Windows
tray app to stop while on Linux everything does. It is not what happens here:
the shim writes `linux-shutdown.log` in `userData`, and a `SIGTERM` reaches
`will-quit` and `exit 0` with the handler below never firing — Electron already
stops cleanly on a signal. The handler stays as a floor under that behaviour,
not as a fix for it.

The log records each start with whether `session.bin` survived, which is the
one fact that has to be read before the app gets a chance to wipe it. The
question it leaves open is what the *start* does with a session that was stored
by a clean stop; `PROMETHEE_DEBUG=1` (below) answers that side.

**4 — Auto-updater off**

`electron-updater`'s Linux path hard-requires an `APPIMAGE` env var and throws
`ERR_UPDATER_OLD_FILE_NOT_FOUND` without one. There's no Linux release channel
anyway, so its own `isUpdaterActive()` guard is answered with `false`.

## Bar widget

The focus timer, and starting or ending a session, from the Quickshell bar
instead of a window:

```bash
./quickshell/install.sh
qs -c ii kill && qs -c ii -d
```

See [quickshell/README.md](quickshell/README.md) for the protocol, the config
block and manual wiring.

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
patches/linux-active-window.js    the active-window shim
patches/promethee-control.js      the control socket
scripts/apply-patches.mjs         bundle rewrites
quickshell/                       bar widget and its installer
```

## Licence

Patches and scripts here are **MIT**.

Promethee itself is **PolyForm Noncommercial 1.0.0** — personal use is fine,
redistribution is not. That's why this builds from your own copy and ships no
binaries. Don't publish the output.
