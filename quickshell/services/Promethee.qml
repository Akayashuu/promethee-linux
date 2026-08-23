pragma Singleton

import qs.modules.common
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

/**
 * Promethee's focus session, in the bar.
 *
 * The app itself is an Electron tray app whose every action sits behind an
 * ipcMain handler. The Linux patch set exposes those handlers on a Unix socket;
 * this service is the other end of it. The socket pushes state on its own, so
 * nothing here polls: the only timer is the one that ticks the elapsed second,
 * and the one that retries a connection after the app quits.
 *
 * A singleton, so several screens share one connection.
 */
Singleton {
    id: root

    /// Where the patched app listens. Overridable, mostly for a second profile.
    readonly property string socketPath: {
        const configured = Config.options.bar.promethee?.socket ?? "";
        if (configured.length > 0)
            return configured;
        const runtime = Quickshell.env("XDG_RUNTIME_DIR") || `/run/user/${Quickshell.env("UID")}`;
        return `${runtime}/promethee/control.sock`;
    }

    /// Command that starts the app when it is not running, for the bar's
    /// "launch" action. The build installs this launcher.
    readonly property string binary: {
        const configured = Config.options.bar.promethee?.binary ?? "";
        return configured.length > 0 ? configured : `${Quickshell.env("HOME")}/.local/bin/promethee`;
    }

    /// True while the socket is up, i.e. while Promethee is running. Answered
    /// by `live` rather than by `socket.connected`, which stays true after a
    /// failed connection attempt and so cannot tell a live app from a dead one.
    readonly property bool available: root.live
    /// True from the first line the server sends — it pushes a state event as
    /// soon as a client connects — until the socket drops.
    property bool live: false
    /// True once the app has reported a signed-in profile.
    property bool authenticated: false
    /// { displayName, level, totalXp, streak } or null.
    property var profile: null
    /// The open session, or null when none is running:
    /// { id, task, startedAt, pausedMs, pauseStartedAt }.
    property var session: null
    /// { sessions, seconds } for the current day, closed sessions included.
    property var today: ({ sessions: 0, seconds: 0 })
    /// The window Promethee currently attributes time to: { app, title }.
    property var window: null
    /// Focus minutes per day over the last seven days, oldest first:
    /// [{ date, minutes }]. Zero-filled, so it is always seven long.
    property var history: []
    /// Today's breakdown, most used first: [{ app, seconds }]. Top five.
    property var apps: []
    /// Everything the tracker attributed today, sessions or not.
    property int trackedSeconds: 0

    /// Just the minutes, for the histogram.
    readonly property var historyMinutes: root.history.map(day => day.minutes ?? 0)
    /// Focus over the whole week, in seconds.
    readonly property int weekSeconds: root.history.reduce((sum, day) => sum + (day.minutes ?? 0), 0) * 60

    /// True while a session is running and not paused.
    readonly property bool running: root.session !== null && !root.session.pauseStartedAt
    /// True while a session is running but paused.
    readonly property bool paused: root.session !== null && !!root.session.pauseStartedAt

    /// Seconds elapsed in the open session, pauses deducted. Recomputed on each
    /// tick rather than incremented, so it cannot drift away from the app's own
    /// count after a suspend.
    property int elapsed: 0

    /// Total focus time today, open session included.
    readonly property int todaySeconds: (root.today?.seconds ?? 0) + root.elapsed

    signal failed(string reason)

    // ------------------------------------------------------------- formatting

    /// "1:04:12" past the hour, "4:12" below it. The bar is narrow and a
    /// leading "0:" buys nothing.
    function formatDuration(seconds) {
        const total = Math.max(0, Math.floor(seconds));
        const h = Math.floor(total / 3600);
        const m = Math.floor((total % 3600) / 60);
        const s = total % 60;
        const pad = n => String(n).padStart(2, "0");
        return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${m}:${pad(s)}`;
    }

    /// "2 h 05" — for a daily total, where the second is noise.
    function formatShort(seconds) {
        const total = Math.max(0, Math.floor(seconds));
        const h = Math.floor(total / 3600);
        const m = Math.floor((total % 3600) / 60);
        return h > 0 ? `${h} h ${String(m).padStart(2, "0")}` : `${m} min`;
    }

    /// "45m", "2h05" — for a bar forty pixels wide, where "2 h 05" does not fit
    /// and a bare number does not say what it counts.
    function formatCompact(seconds) {
        const total = Math.max(0, Math.floor(seconds));
        const h = Math.floor(total / 3600);
        const m = Math.floor((total % 3600) / 60);
        return h > 0 ? `${h}h${String(m).padStart(2, "0")}` : `${m}m`;
    }

    function recomputeElapsed() {
        if (!root.session || !root.session.startedAt) {
            root.elapsed = 0;
            return;
        }
        // The server hands out epoch milliseconds, already normalised.
        const started = root.session.startedAt;
        // A paused session froze at the moment the pause began.
        const until = root.session.pauseStartedAt ?? Date.now();
        root.elapsed = Math.max(0, Math.floor((until - started - (root.session.pausedMs ?? 0)) / 1000));
    }

    // ------------------------------------------------------------------- wire

    /// Pending replies, keyed by request id, so a caller can react to its own
    /// call and not to whichever reply happens to arrive next.
    property var pending: ({})
    property int nextId: 1

    /// Calls one ipc channel. `callback(ok, data)` is optional.
    function call(channel, args, callback) {
        if (!root.live) {
            if (callback)
                callback(false, null);
            return;
        }
        const id = root.nextId++;
        if (callback)
            root.pending[id] = callback;
        root.socket.write(`${JSON.stringify({ id: id, channel: channel, args: args ?? [] })}\n`);
        root.socket.flush();
    }

    // The server guarantees one JSON object per line; a truncated one (app
    // killed mid-write) must never break the bar.
    function ingest(line) {
        const trimmed = line.trim();
        if (trimmed.length === 0)
            return;
        let payload;
        try {
            payload = JSON.parse(trimmed);
        } catch (e) {
            return; // Unusable line: keep the last known state.
        }
        root.live = true;

        if (payload.event === "state") {
            root.apply(payload.state);
            return;
        }

        const callback = root.pending[payload.id];
        if (callback) {
            delete root.pending[payload.id];
            callback(payload.ok === true, payload.data ?? null);
        }
        if (payload.ok === false && payload.error)
            root.failed(payload.error);
    }

    function apply(state) {
        if (!state)
            return;
        root.authenticated = state.authenticated ?? false;
        root.profile = state.profile ?? null;
        root.session = state.session ?? null;
        root.today = state.today ?? { sessions: 0, seconds: 0 };
        root.window = state.window ?? null;
        root.history = state.history ?? [];
        root.apps = state.apps ?? [];
        root.trackedSeconds = state.trackedSeconds ?? 0;
        root.recomputeElapsed();
    }

    function reset() {
        root.live = false;
        root.authenticated = false;
        root.profile = null;
        root.session = null;
        root.today = { sessions: 0, seconds: 0 };
        root.window = null;
        root.history = [];
        root.apps = [];
        root.trackedSeconds = 0;
        root.elapsed = 0;
        root.pending = {};
    }

    // ---------------------------------------------------------------- actions

    /// Starts a session. An empty task lets the app fall back to its default.
    function start(task) {
        root.call("session:start", [task && task.length > 0 ? task : null]);
    }

    /**
     * Ends the session for good. Deliberate by design — see toggle().
     *
     * `session:end` only writes the session; it does not show anything. The
     * recap window — where the session gets its message — is a second call the
     * app's own renderer makes with the payload `session:end` just returned.
     * Ending from the bar has to make that same call, or the session is filed
     * away with no chance to say what it was.
     */
    function stop() {
        root.call("session:end", [], (ok, data) => {
            const session = ok ? (data?.session ?? null) : null;
            if (!session)
                return;
            root.call("window:openSessionComplete", [{
                task: session.task || "Session",
                durationSeconds: session.durationSeconds || 0,
                xpEarned: session.xpEarned || 0,
                multiplier: session.multiplier,
                streakBonus: session.streakBonus,
                depthBonus: session.depthBonus,
                currentStreak: session.currentStreak,
                sessionId: session.id,
                sessionInsight: session.sessionInsight,
                signalSummary: session.signalSummary,
                endReason: session.endReason,
                idleTimeoutSec: session.idleTimeoutSec
            }]);
            // Same reason as showDashboard(): the window is created, but a
            // compositor will not hand focus to an app that asks for it.
            root.focusAttempts = 0;
            focusTimer.restart();
        });
    }

    function pause() {
        root.call("session:pause", []);
    }

    function resume() {
        root.call("session:resume", []);
    }

    /**
     * One click, whichever state the session is in — and it never ends a
     * session. Ending is destructive: the session is written, the timer is
     * gone, and a misclick costs the whole block. Pausing is not, so the
     * cheap gesture does the reversible thing and ending gets its own.
     */
    function toggle() {
        if (!root.session)
            root.start("");
        else if (root.paused)
            root.resume();
        else
            root.pause();
    }

    /**
     * Brings up the app's own dashboard window.
     *
     * The channel alone is not enough. It does show the window, but a window
     * that already exists on another workspace is shown *there*, and the
     * compositor is right to ignore an app that asks for focus on its own —
     * that is how focus stealing works. So the raise is asked for twice: once
     * from the app, once from here, where it is the direct result of a click.
     */
    function showDashboard() {
        root.call("window:showDashboard", []);
        // The window may not exist yet — showDashboard creates one when the app
        // is sitting in the tray — so keep asking for a moment.
        focusAttempts = 0;
        focusTimer.restart();
    }

    property int focusAttempts: 0

    /**
     * Activation over the wlr foreign-toplevel protocol rather than a
     * compositor dispatch. Two reasons: it works on anything wlroots-based
     * rather than only Hyprland, and it does not go through hyprctl, whose
     * dispatch line is re-parsed as Lua under a Lua-configured Hyprland and
     * rejects `focuswindow class:promethee` outright.
     */
    function focusWindow() {
        for (const toplevel of ToplevelManager.toplevels.values) {
            if (toplevel.appId === "promethee") {
                toplevel.activate();
                return true;
            }
        }
        return false;
    }

    Timer {
        id: focusTimer
        interval: 120
        repeat: true
        onTriggered: {
            root.focusAttempts += 1;
            if (root.focusWindow() || root.focusAttempts > 12)
                focusTimer.stop();
        }
    }

    /// Starts the app itself, for when the socket is down. A second instance
    /// hands over to the first, so this is safe to call blind.
    function launch() {
        launchProc.command = [root.binary];
        launchProc.running = true;
    }

    /// Left click in the bar: open the dashboard, or start the app first.
    function activate() {
        if (root.available)
            root.showDashboard();
        else
            root.launch();
    }

    // A Socket that has failed to connect once will not try again, whatever is
    // written to `connected` afterwards — so reconnecting means building a new
    // one. The Loader is there to be able to throw the old one away.
    readonly property var socket: socketLoader.item

    Loader {
        id: socketLoader
        active: true
        sourceComponent: Component {
            Socket {
                path: root.socketPath
                connected: true

                parser: SplitParser {
                    splitMarker: "\n"
                    onRead: data => root.ingest(data)
                }

                onConnectionStateChanged: {
                    if (!connected)
                        root.reset();
                }
            }
        }
    }

    Timer {
        id: retryTimer
        // Driven by `live`, not by the socket's own `connected`, which stays
        // true after a refused attempt and so cannot tell a live app from a
        // dead one. The app is not always running, and it is not the bar's job
        // to keep it running: retry quietly rather than give up.
        running: !root.live
        interval: 3000
        repeat: true
        onTriggered: {
            socketLoader.active = false;
            socketLoader.active = true;
        }
    }

    Timer {
        // Only runs while there is something to count.
        running: root.running
        interval: 1000
        repeat: true
        onTriggered: root.recomputeElapsed()
    }

    Process {
        id: launchProc
    }

}
