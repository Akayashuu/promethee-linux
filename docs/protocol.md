# The control protocol

Promethee is a tray app: everything it can do sits behind an `ipcMain` handler,
and those answer its own renderer only. The control-socket patch wraps
`ipcMain.handle` as the app registers its handlers and serves them over a Unix
socket, so anything on the machine can read the app's state and drive it.

This page is the contract between the app and a client. The bar widget in
`clients/quickshell` is one client written against it; `clients/promethee-ctl`
is another. Nothing here is specific to either.

## The socket

```
$XDG_RUNTIME_DIR/promethee/control.sock
```

Mode 0600, in the user's own runtime directory, and it is a full remote control
for the app — the same trust boundary as the session bus. Without
`XDG_RUNTIME_DIR`, the path falls back to `$TMPDIR/run-<uid>/promethee/control.sock`.

The socket exists only while the app runs. It is created once the app is ready,
and removed on `will-quit`; a stale node left by a crash is unlinked at the next
start. **A connection refused, or no socket at all, means Promethee is not
running** — that is the only way to ask, and a client should treat it as a
state to render rather than an error to report.

## Framing

One JSON object per line, `\n`-terminated, UTF-8, in both directions. Lines
longer than 64 KiB are refused and the connection is closed rather than buffered
without bound.

Requests may be sent back to back without waiting: replies carry the `id` they
answer, and are not otherwise ordered.

## Calling a channel

```json
{"id": 1, "channel": "session:start", "args": ["Focus"]}
```

| Field | | |
| --- | --- | --- |
| `id` | optional | Echoed back on the reply. Any JSON value; omit it if you never need to match a reply to a call. |
| `channel` | required | The handler to call. |
| `args` | optional | Positional arguments, as the renderer would pass them. Defaults to `[]`. |

The reply is one of:

```json
{"id": 1, "ok": true,  "data": {"success": true}}
{"id": 1, "ok": false, "error": "unknown channel: session:strat"}
```

`data` is whatever the handler returned, `null` if it returned nothing. `ok` is
always present, so `ok` is the only thing worth branching on.

A call that has not settled after 15 seconds is answered with a timeout error.
That bounds the client's wait; it does not cancel the handler.

## Events

State is pushed on connect, every two seconds, and again after every call — an
action almost always moves the state, and a client should not have to wait out
the interval to see the result of its own call. So a bar renders a live timer
without polling.

```json
{"event": "state", "state": {"…": "…"}}
```

Events carry `event` and never `id`; replies carry `ok`. Dispatch on which one
is present.

Pushes only happen while a client is connected. Stay connected and read.

## The state object

```json
{
  "at": 1756108800000,
  "authenticated": true,
  "profile": {"displayName": "…", "level": 7, "totalXp": 4210, "streak": 3},
  "session": {"id": "f5d0383b-…", "task": "Focus", "startedAt": 1756105200000,
              "pausedMs": 0, "pauseStartedAt": null},
  "today": {"sessions": 4, "seconds": 7380},
  "window": {"app": "kitty", "title": "~"},
  "history": [{"date": "2026-08-19", "minutes": 0}, "…"],
  "apps": [{"app": "Code", "seconds": 5400}, "…"],
  "trackedSeconds": 20740
}
```

| Field | |
| --- | --- |
| `at` | When the state was read, epoch ms. |
| `authenticated` | Whether a user profile could be read at all. Everything below is empty when this is `false`. |
| `profile` | `null` when signed out. |
| `session` | The open session, or `null` when none is running. |
| `session.startedAt`, `session.pauseStartedAt` | Epoch ms, normalised — the app's own columns are inconsistent about integers versus ISO strings, so a client never has to guess. `pauseStartedAt` is non-null exactly when the session is paused. |
| `session.pausedMs` | Total paused time so far, excluding the pause in progress. |
| `today` | Sessions closed today and their total seconds. |
| `window` | The focused window, from the active-window shim. Absent if that patch is not installed. |
| `history` | Seven entries ending today, zero-filled. A bar chart with holes in it lies about which day is which. |
| `apps` | Today's five busiest applications. |
| `trackedSeconds` | Everything the tracker attributed to an app today, `apps` included. |

Fields are added over time; ignore what you do not recognise.

The elapsed time of a running session is the client's to compute, from
`startedAt`, `pausedMs` and `pauseStartedAt` — that is what makes a timer tick
between two pushes instead of stepping every two seconds.

## Channels served by the socket itself

| Channel | |
| --- | --- |
| `state` | Returns the same object the push carries, as a normal reply. For a one-shot client that asks and exits. |
| `channels` | Every channel the app has registered, sorted. Around 370 of them. |

Everything else is the app's own IPC, forwarded as-is. The ones a bar tends to
want:

| Channel | |
| --- | --- |
| `session:start` | `args: ["<task name>"]`, or `[null]` for an untitled session. |
| `session:pause`, `session:resume` | |
| `session:end` | Writes the session and returns its recap payload. |
| `window:openSessionComplete` | Opens the recap window, given that payload. |
| `window:showDashboard` | Opens the app's own window. |

`session:end` only writes the session. The app's own UI follows it with
`window:openSessionComplete`, carrying the payload the first call returned — the
recap is where a session gets its message, and a client that skips it ends
sessions silently. See `clients/quickshell/services/Promethee.qml` for the pair.

Ask `channels` for the rest. Names are stable across upstream builds in a way
the minified internals are not, but nothing guarantees them — a client should
survive `unknown channel`.

## Writing a client

Anything that speaks Unix sockets will do:

```bash
printf '{"id":1,"channel":"state"}\n' | socat - UNIX-CONNECT:"$XDG_RUNTIME_DIR/promethee/control.sock"
```

For bars that shell out rather than open sockets — Waybar, eww, polybar — use
the reference client, which does the connecting, framing and reconnection:

```bash
promethee-ctl state                       # one JSON object, then exit
promethee-ctl watch                       # one line per push, until interrupted
promethee-ctl call session:start Focus    # arguments are JSON, or plain strings
promethee-ctl channels
```

See [clients/README.md](../clients/README.md) for wiring that into a specific
bar.

Two things worth getting right in any client:

- **Reconnect on a loop.** The app stops and starts more often than the bar
  does; a client that gives up on the first refusal shows a dead widget until
  the session is restarted. Retry every couple of seconds, and render "not
  running" in the meantime.
- **Do not poll `state` on a timer.** The push already arrives every two
  seconds, and a one-shot connection per tick pays for a connect and a full
  state read each time.

## The sender guard

The app wraps every handler in a check on `event.senderFrame.url`, refusing
anything that is not its own `index.html`. That guard is there to keep a
hijacked web page from driving the main process, and it stays in place: the shim
answers it with that exact URL rather than removing it. The boundary the socket
relies on is the file mode, not the guard.
