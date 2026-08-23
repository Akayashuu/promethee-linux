# promethee-linux

Run [Promethee](https://promethee.io) natively on Linux.

Promethee is an Electron app shipped only for Windows and macOS. The Electron
part is portable — what is missing is a Linux backend for the one thing the
product is built on: knowing which window you're looking at. This repo adds
that backend and builds a native Linux app from a copy you already own.

No Promethee code is redistributed here. `build.sh` reads the app bundle from
an install on your own machine.

```
./build.sh --install
promethee
```

## What it does

| Step | |
|---|---|
| 1 | Finds your existing install (Wine prefix, or `--source <dir>`) |
| 2 | Extracts `app.asar` |
| 3 | Rebuilds `better-sqlite3` and `keytar` as Linux addons for the right Electron ABI |
| 4 | Patches the main bundle (below) |
| 5 | Downloads the matching Electron and writes `dist/promethee` |
| 6 | `--install` adds a `.desktop` entry and `~/.local/bin/promethee` |

## The patches

Everything lives in `scripts/apply-patches.mjs`. The bundles are minified and
their identifiers change on every upstream build, so each patch anchors on a
structural signature rather than a name — and a required patch that matches
nothing aborts the build instead of shipping a half-working app.

**1. Linux active-window backend** (`patches/linux-active-window.js`)

Upstream's dispatcher:

```js
async function Aw(e = {}) {
  if (process.platform === "win32") return Iqe(e);   // get-windows
  if (process.platform !== "darwin") return null;    // ← Linux lands here
  ...
}
```

On Linux it returns `null`, silently, forever — no active app, no sessions, no
XP. The patch inserts a `linux` branch that calls an injected shim providing
the same shape upstream builds from `get-windows`:

```js
{ owner: { name, bundleId, processId, path }, title, source, frame }
```

Backends, tried in order:

| Backend | How | Requires |
|---|---|---|
| Hyprland | IPC socket directly, `hyprctl` fallback | `HYPRLAND_INSTANCE_SIGNATURE` |
| Sway | `swaymsg -t get_tree` | `SWAYSOCK` |
| X11 | `xdotool` | `DISPLAY` + `xdotool` |

Window classes are slugs (`code-oss`, `org.gnome.Nautilus`), so the shim indexes
your `.desktop` entries once and maps class → `Name=`, giving the app names you
actually see in your launcher. The executable path comes from `/proc/<pid>/exe`.
Results are cached for 900 ms so a burst of callers doesn't fan out into a burst
of IPC round-trips.

**2. Auto-updater off**

`electron-updater`'s Linux path hard-requires an `APPIMAGE` env var and throws
`ERR_UPDATER_OLD_FILE_NOT_FOUND` without one. There is no Linux release channel
anyway, so its own `isUpdaterActive()` guard is answered with `false`.

## What works

Everything the app does, including activity tracking, sessions, quests, XP,
leaderboards, and the HUD.

## What doesn't

- **App blocking.** The blocker enumerates and manipulates Windows windows
  (`blockerWindows-*.js`). It is not ported.
- **Launch at login.** Electron reports `unsupported-platform`; add a systemd
  user unit or an autostart entry yourself if you want it.
- **Virtual-desktop pinning.** `win-vdesktop` is Windows-only and already
  guarded upstream.

## Requirements

- Node ≥ 20, npm, python3
- A C++ toolchain for the native rebuilds — `base-devel` (Arch) or
  `build-essential` (Debian/Ubuntu)
- `libsecret` for keytar — `libsecret` (Arch) or `libsecret-1-dev` (Debian/Ubuntu)
- A window backend: Hyprland, Sway, or X11 with `xdotool`

## Getting a copy to build from

Promethee has no Linux download. Install the Windows build under Wine once —
you only need the files, not a working Wine run:

```bash
WINEPREFIX=~/.wine-promethee wine Promethee-x.y.z-Setup.exe
```

Then `build.sh` finds it automatically. Or point it anywhere with the app
bundle:

```bash
./build.sh --source /path/to/Promethee/app-1.3.26/resources
```

## Debugging

```bash
PROMETHEE_LINUX_DEBUG=1 ./dist/promethee
```

Logs which backend answered, how many desktop entries were indexed, and any
backend failures. To check the shim on its own:

```bash
node -e 'require("./patches/linux-active-window.js");
         globalThis.__prometheeLinuxActiveWindow().then(r => console.log(r))'
```

## Upstream compatibility

Tested against Promethee 1.3.26 / Electron 43.2.0. Later versions will keep
working as long as the anchors hold; if one breaks, the build fails loudly and
names the patch, which is the point.

## Licence

The patches and scripts in this repo are MIT.

Promethee itself is **PolyForm Noncommercial 1.0.0** — personal use is fine,
redistribution is not. That is why this repo builds from your own copy and
ships no binaries. Don't publish the output.
