# Quickshell integration

Bar widget for [Quickshell](https://quickshell.outfoxxed.me/), designed for the
`ii` configuration of [dots-hyprland](https://github.com/end-4/dots-hyprland).
Both the horizontal and the vertical bar are supported.

The widget shows the running focus timer, starts and ends a session from the
bar, and opens Promethee's own dashboard. Promethee itself stays a tray app;
this only gives it a face in the bar.

## Requirements

The patched build from this repository. The plain Windows build has no control
socket, and the widget has nothing to talk to.

## Installation

```bash
./quickshell/install.sh          # into ~/.config/quickshell/ii
QS_DIR=/another/path ./quickshell/install.sh
qs -c ii kill && qs -c ii -d     # restart to load the widget
```

The script is idempotent: it looks for its own `// promethee` marker and never
wires anything twice. It backs up every upstream file it modifies as
`<file>.bak-promethee` before its first change.

> A dots-hyprland update overwrites `Config.qml`, `BarContent.qml` and
> `VerticalBarContent.qml`. Run the script again afterwards; the widgets
> themselves live in files that do not belong to upstream.

## Usage

| Action | Both bars |
| --- | --- |
| Left click | Start, then pause / resume |
| Long press | End the session |
| Middle click | End the session |
| Right click | Open the dashboard |
| Hover | Day, week, per-app breakdown, level, streak |

Left click never ends a session. Ending is the one gesture here that cannot be
undone — the session is written and the timer is gone — so the cheap gesture
does the reversible thing and ending gets a deliberate one. A trackpad has no
middle button, which is why the long press exists; both routes are gestures you
cannot make by accident. The badge shrinks while the press is held, so the
gesture is visible before it fires.

Ending also opens Promethee's session-complete window, the same one the
app's own UI brings up: the recap where the session gets its message. The
`session:end` channel only writes the session — the window is a second call
the renderer makes with the payload the first one returns, and the bar makes
it too. Without it a session ends silently and the message is lost.

When Promethee is not running, any click launches it.

Right click asks for the window twice: once through the app's own
`window:showDashboard`, once over the wlr foreign-toplevel protocol. The
channel alone shows a window that already exists *where it already is*, which
from another workspace looks like the click did nothing — and a compositor is
right to ignore an app that asks for focus on its own. Activating the toplevel
from the bar is a direct result of a click, so it is honoured. It is also done
over the protocol rather than through `hyprctl`, which keeps it working on any
wlroots compositor, and avoids Hyprland's dispatch line under a Lua-based
config, where `focuswindow class:promethee` is re-parsed as Lua and rejected.

## Configuration

`install.sh` adds a `bar.promethee` block to `Config.qml`:

```qml
property JsonObject promethee: JsonObject { // promethee
    property bool enable: true
    property string socket: "" // Empty: $XDG_RUNTIME_DIR/promethee/control.sock
    property string binary: "" // Empty: ~/.local/bin/promethee
}
```

## How it works

Everything Promethee can do sits behind an `ipcMain` handler, and those are
reachable from its renderer only — a bar widget is not a renderer. The
`patches/promethee-control.js` shim, injected at the top of the main bundle,
wraps `ipcMain.handle` as the app registers its handlers, then serves them over
a Unix socket at `$XDG_RUNTIME_DIR/promethee/control.sock`, one JSON object per
line:

```
-> {"id":1,"channel":"session:start","args":["Focus"]}
<- {"id":1,"ok":true,"data":{"success":true}}
<- {"event":"state","state":{"session":{...},"profile":{...},"today":{...}}}
```

State is pushed every two seconds and after every call, so the widget renders a
live timer without polling. Two pseudo-channels are served by the shim itself:
`state` returns the same object as the push, and `channels` lists every handler
the app registered.

The socket is 0600 in the user's own runtime directory. It is a full remote
control for the app, so treat it as you would the session bus.

The app also guards every handler against untrusted senders, by checking the
frame URL against the renderer's own `index.html`. That guard is there to keep
a hijacked web page from driving the main process, and it stays in place: the
shim answers it with that exact URL rather than removing it.

## Files

| File | Role |
| --- | --- |
| `services/Promethee.qml` | Singleton: the socket connection, state and actions |
| `modules/ii/bar/PrometheeWidget.qml` | Horizontal bar: glyph, timer, level |
| `modules/ii/bar/PrometheeWidgetPopup.qml` | Hover popup: session, day, profile, tracked app |
| `modules/ii/verticalBar/VerticalPrometheeWidget.qml` | Vertical bar: glyph and minutes |
| `install.sh` | Copies the widgets and wires the three upstream files |

## Wiring by hand

If `install.sh` cannot find an anchor — upstream moved it — copy the four QML
files into the matching directories of your config, add the `promethee` block
to `Config.qml`, and add a `Loader` in `BarContent.qml`:

```qml
Loader {
    Layout.leftMargin: 4
    active: Config.options.bar.promethee?.enable ?? true
    sourceComponent: BarGroup {
        PrometheeWidget {
            Layout.alignment: Qt.AlignVCenter
        }
    }
}
```
