# Clients

Promethee is a tray app, and the patched build serves everything it can do over
a Unix socket. Anything that can read a socket, or run a command, can show the
running session and drive it.

| | |
| --- | --- |
| [`quickshell/`](quickshell/README.md) | Bar widget for [Quickshell](https://quickshell.outfoxxed.me/), for the `ii` configuration of dots-hyprland |
| [`promethee-ctl`](promethee-ctl) | The socket from a shell. For bars that run commands, and for looking around by hand |

[docs/protocol.md](../docs/protocol.md) is the contract. It is not specific to
either of these, and a new client is not a fork of one of them. It is a reader of
that page.

## promethee-ctl

```bash
promethee-ctl state                       # one JSON object, then exit
promethee-ctl watch                       # one per push, until interrupted
promethee-ctl call session:start Focus    # arguments are JSON, or plain strings
promethee-ctl channels                    # everything the app can be asked
```

`build.sh --install` links it into `~/.local/bin`.

Both `state` and `watch` print the state object with one field added, `running`.
A bar has to render "Promethee is not running" as readily as it renders a timer,
so the two are the same shape with a flag between them:

```json
{"running": true, "session": {"startedAt": 1756105200000, "…": "…"}, "…": "…"}
{"running": false}
```

`watch` never ends on its own. The app quitting is a line on the stream, not the
end of it, and the connection is retried until it comes back. A bar that has to
be restarted alongside the app is a bar that will be wrong at some point.

Exit status is `0` done, `1` the call failed, `3` Promethee is not running.

## Wiring a bar

The elapsed time of a running session is the client's to compute, from
`startedAt`, `pausedMs` and `pauseStartedAt`, and that is what makes a timer tick
smoothly rather than step every two seconds. One `jq` expression covers the
three states a bar has to show:

```bash
promethee-ctl watch | jq --unbuffered -c '
  if .running | not then     {text: "", class: "off"}
  elif .session == null then {text: "idle", class: "idle"}
  else
    (.session.pauseStartedAt // (now * 1000)) as $until
    | ((($until - .session.startedAt - .session.pausedMs) / 60000) | floor) as $min
    | {text: "\($min) min",
       class: (if .session.pauseStartedAt then "paused" else "running" end),
       tooltip: "Level \(.profile.level) · \(.today.sessions) sessions today"}
  end'
```

Save that as `~/.local/bin/promethee-bar` and it is a module in most bars:

**Waybar**: `custom/promethee`, a module that stays alive and streams:

```jsonc
"custom/promethee": {
    "exec": "~/.local/bin/promethee-bar",
    "return-type": "json",
    "on-click": "promethee-ctl call session:start Focus",
    "on-click-middle": "promethee-ctl call session:end",
    "on-click-right": "promethee-ctl call window:showDashboard"
}
```

**eww**: `deflisten` is the same idea:

```lisp
(deflisten promethee "~/.local/bin/promethee-bar")
(defwidget promethee-widget []
  (button :onclick "promethee-ctl call session:pause"
          :class {promethee.class}
          {promethee.text}))
```

**polybar**: `type = custom/script` with `tail = true`, formatting to plain text
rather than JSON.

Two things worth getting right whichever bar it is:

- Left click should not end a session. Ending is the one action that cannot be
  undone, so it deserves a deliberate gesture: a middle click, or a long press.
  Starting and pausing are cheap and reversible.
- `session:end` only writes the session. The recap window, where a session gets
  its message, is a second call to `window:openSessionComplete` with the payload
  the first returned. Skip it and sessions end silently.

## Writing a client properly

A bar that opens the socket itself gets the state pushed to it, and does not pay
for a connect and a full state read every time it wants to know the time. That
is what `quickshell/services/Promethee.qml` does, and it is the shape to copy:
one connection, held open, reconnected on a timer, with the widgets bound to the
last state received.

Read [docs/protocol.md](../docs/protocol.md) before starting. New clients are
welcome here.
