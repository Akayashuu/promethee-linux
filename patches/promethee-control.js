/**
 * Promethee-linux — control socket.
 *
 * Everything the app can do lives behind ipcMain handlers, reachable only from
 * its own renderer. A bar widget is not a renderer, so it has no way in.
 *
 * Rather than hunt for the minified session functions, this shim wraps
 * ipcMain.handle at registration time and keeps a reference to every handler it
 * sees. It is injected at the top of the main bundle, so it is in place before
 * the app registers anything — all ~370 channels end up reachable, and nothing
 * here depends on an identifier the next upstream build will rename.
 *
 * Those handlers are then served over a Unix socket, newline-delimited JSON:
 *
 *   -> {"id":1,"channel":"session:start","args":["Focus"]}
 *   <- {"id":1,"ok":true,"data":{...}}
 *
 * The server also pushes state on connect and on a timer, so a widget can
 * render a live timer without polling the socket itself:
 *
 *   <- {"event":"state","state":{...}}
 *
 * The socket is a full remote control for the app. It lives in the user's own
 * runtime directory, 0600, same trust boundary as the session bus.
 */
(() => {
	if (process.platform !== "linux") return;
	if (globalThis.__prometheeControl) return;

	const electron = require("electron");
	const net = require("node:net");
	const fs = require("node:fs");
	const path = require("node:path");
	const os = require("node:os");
	const url = require("node:url");

	/** Pushed to every client on this interval. Matches the app's own polling. */
	const STATE_INTERVAL_MS = 2000;
	/** A handler that never settles must not wedge the client. */
	const CALL_TIMEOUT_MS = 15000;
	/** History and per-app totals move by the day, not by the second. */
	const SLOW_TTL_MS = 30000;
	/** Refuse oversized lines rather than buffer without bound. */
	const MAX_LINE_CHARS = 64 * 1024;

	const log = (...a) => {
		if (process.env.PROMETHEE_LINUX_DEBUG) console.log("[promethee-control]", ...a);
	};

	// ---------------------------------------------------- handler capture

	/** channel -> handler, filled as the app registers its own IPC. */
	const handlers = new Map();

	const { ipcMain } = electron;
	const originalHandle = ipcMain.handle.bind(ipcMain);
	ipcMain.handle = (channel, listener) => {
		handlers.set(channel, listener);
		return originalHandle(channel, listener);
	};
	const originalRemove = ipcMain.removeHandler.bind(ipcMain);
	ipcMain.removeHandler = (channel) => {
		handlers.delete(channel);
		return originalRemove(channel);
	};

	/**
	 * The app wraps every handler in a sender guard: it reads event.senderFrame.url
	 * and refuses anything that is not the renderer's own index.html. That guard
	 * exists to keep a hijacked web page from driving the main process, and it is
	 * right to. This socket is not that: it is a Unix socket, 0600, in the user's
	 * own runtime directory, i.e. already inside the trust boundary the guard
	 * protects. So rather than disable the guard for everyone, answer it — the
	 * renderer's own file URL, computed the same way the app computes it.
	 */
	const rendererUrl = (() => {
		const candidates = [
			path.resolve(__dirname, "../renderer/main_window/index.html"),
			path.resolve(__dirname, "../../renderer/main_window/index.html"),
		];
		const found = candidates.find((candidate) => fs.existsSync(candidate));
		return found ? url.pathToFileURL(found).href : "";
	})();

	/** Handlers are written as (event, ...args); the ones this exposes ignore it. */
	function syntheticEvent() {
		return {
			senderFrame: { url: rendererUrl },
			sender: {
				getURL: () => rendererUrl,
				// A handler that tries to answer a renderer has no renderer here.
				send: () => {},
				isDestroyed: () => false,
			},
		};
	}

	function invoke(channel, args = []) {
		const handler = handlers.get(channel);
		if (!handler) return Promise.reject(new Error(`unknown channel: ${channel}`));

		const call = Promise.resolve().then(() => handler(syntheticEvent(), ...args));
		const timeout = new Promise((_resolve, reject) => {
			const timer = setTimeout(() => reject(new Error(`${channel} timed out`)), CALL_TIMEOUT_MS);
			// Do not hold the event loop open on the app's behalf.
			if (typeof timer.unref === "function") timer.unref();
		});
		return Promise.race([call, timeout]);
	}

	// -------------------------------------------------------------- state

	// One flat object, everything a bar needs in a single push. Each field is
	// read through the app's own channels, so it stays consistent with the UI.

	/**
	 * The daily history and the app breakdown are each a table scan, and neither
	 * changes between two pushes. Cache them apart from the rest of the state.
	 */
	let slowCache = null;
	let slowAt = 0;

	async function readSlow() {
		if (slowCache && Date.now() - slowAt < SLOW_TTL_MS) return slowCache;

		// { "2026-08-23": 125, ... } — minutes per day, most recent last.
		const history = await invoke("session:getFocusHistory", [7]).catch(() => null);
		const days = history?.history ?? {};

		// One row per day, each carrying a JSON list of apps by seconds.
		const usage = await invoke("tracking:getDailyAppUsage", [1]).catch(() => null);
		const rows = usage?.rows ?? [];
		const todayKey = new Date().toLocaleDateString("en-CA");
		const row = rows.find((entry) => entry.date === todayKey) ?? rows[0] ?? null;

		let apps = [];
		try {
			apps = JSON.parse(row?.top_apps ?? "[]");
		} catch {
			apps = [];
		}

		slowCache = {
			// Seven entries ending today, zero-filled: a bar chart with holes in
			// it lies about which day is which.
			history: lastSevenDays(days),
			apps: Array.isArray(apps) ? apps.slice(0, 5) : [],
			trackedSeconds: Number(row?.total_tracked_seconds) || 0,
		};
		slowAt = Date.now();
		return slowCache;
	}

	function lastSevenDays(byDay) {
		const out = [];
		for (let back = 6; back >= 0; back -= 1) {
			const day = new Date(Date.now() - back * 86400000);
			const key = day.toLocaleDateString("en-CA");
			out.push({ date: key, minutes: Number(byDay[key]) || 0 });
		}
		return out;
	}

	async function readState() {
		const state = {
			at: Date.now(),
			authenticated: false,
			profile: null,
			session: null,
			today: { sessions: 0, seconds: 0 },
		};

		const profile = await invoke("db:getUserProfile").catch(() => null);
		const row = profile?.profile ?? profile;
		if (row?.id) {
			state.authenticated = true;
			state.profile = {
				displayName: row.display_name ?? null,
				level: row.level ?? 0,
				totalXp: row.total_xp ?? 0,
				streak: row.current_streak ?? 0,
			};
		}

		// Channels are inconsistent about wrapping their rows; accept both shapes
		// rather than guess which one this build settled on.
		const today = await invoke("session:getToday").catch(() => null);
		const sessions = Array.isArray(today) ? today : (today?.sessions ?? []);
		if (Array.isArray(sessions)) {
			state.today.sessions = sessions.length;
			for (const session of sessions) {
				state.today.seconds += Number(session.duration_seconds) || 0;
			}
			// At most one session is open at a time; the app closes the previous
			// one before starting another.
			const open = sessions.find((s) => !s.ended_at);
			if (open) {
				state.session = {
					id: open.id,
					task: open.task ?? null,
					// The table stores epoch milliseconds as integers. Normalise
					// here so clients never have to guess between a number and an
					// ISO string.
					startedAt: epochMs(open.started_at),
					pausedMs: Number(open.total_pause_ms) || 0,
					pauseStartedAt: epochMs(open.pause_started_at),
				};
			}
		}

		const window = await activeWindow();
		if (window) state.window = window;

		const slow = await readSlow().catch(() => null);
		if (slow) {
			state.history = slow.history;
			state.apps = slow.apps;
			state.trackedSeconds = slow.trackedSeconds;
		}

		return state;
	}

	/** Epoch milliseconds, from either an integer column or an ISO string. */
	function epochMs(value) {
		if (value === null || value === undefined) return null;
		if (typeof value === "number") return value;
		const parsed = Date.parse(value);
		return Number.isNaN(parsed) ? null : parsed;
	}

	/** Reuses the active-window shim when it is present; absence is not an error. */
	function activeWindow() {
		const detect = globalThis.__prometheeLinuxActiveWindow;
		if (typeof detect !== "function") return Promise.resolve(null);
		return Promise.resolve()
			.then(() => detect())
			.then((win) => (win ? { app: win.owner?.name ?? null, title: win.title ?? null } : null))
			.catch(() => null);
	}

	// ------------------------------------------------------------- server

	const clients = new Set();

	function send(socket, payload) {
		if (socket.destroyed) return;
		socket.write(`${JSON.stringify(payload)}\n`);
	}

	function broadcast(payload) {
		for (const socket of clients) send(socket, payload);
	}

	async function pushState() {
		if (clients.size === 0) return;
		try {
			broadcast({ event: "state", state: await readState() });
		} catch (err) {
			log("state push failed:", err?.message || err);
		}
	}

	function handleLine(socket, line) {
		const trimmed = line.trim();
		if (trimmed.length === 0) return;

		let request;
		try {
			request = JSON.parse(trimmed);
		} catch {
			send(socket, { ok: false, error: "malformed JSON" });
			return;
		}

		const { id = null, channel, args = [] } = request;
		if (typeof channel !== "string") {
			send(socket, { id, ok: false, error: "missing channel" });
			return;
		}

		// `state` is synthesised here rather than proxied to a channel.
		if (channel === "state") {
			readState().then(
				(state) => send(socket, { id, ok: true, data: state }),
				(err) => send(socket, { id, ok: false, error: err?.message || String(err) }),
			);
			return;
		}
		if (channel === "channels") {
			send(socket, { id, ok: true, data: [...handlers.keys()].sort() });
			return;
		}

		invoke(channel, Array.isArray(args) ? args : []).then(
			(data) => {
				send(socket, { id, ok: true, data: data ?? null });
				// An action almost always moves the state; do not make clients wait
				// out the interval to see the result of their own call.
				pushState();
			},
			(err) => send(socket, { id, ok: false, error: err?.message || String(err) }),
		);
	}

	function socketPath() {
		const runtime =
			process.env.XDG_RUNTIME_DIR || path.join(os.tmpdir(), `run-${process.getuid()}`);
		return path.join(runtime, "promethee", "control.sock");
	}

	function listen() {
		const target = socketPath();
		fs.mkdirSync(path.dirname(target), { recursive: true, mode: 0o700 });
		// A crash leaves the node behind; nothing is listening on it any more.
		try {
			fs.unlinkSync(target);
		} catch {}

		const server = net.createServer((socket) => {
			clients.add(socket);
			socket.setEncoding("utf8");

			let buffer = "";
			socket.on("data", (chunk) => {
				buffer += chunk;
				if (buffer.length > MAX_LINE_CHARS) {
					send(socket, { ok: false, error: "line too long" });
					socket.destroy();
					return;
				}
				const lines = buffer.split("\n");
				buffer = lines.pop() ?? "";
				for (const line of lines) handleLine(socket, line);
			});

			const drop = () => clients.delete(socket);
			socket.on("close", drop);
			socket.on("error", drop);

			readState().then(
				(state) => send(socket, { event: "state", state }),
				() => {},
			);
		});

		server.on("error", (err) => log("server error:", err?.message || err));
		server.listen(target, () => {
			fs.chmodSync(target, 0o600);
			log(`listening on ${target}`);
		});

		const timer = setInterval(pushState, STATE_INTERVAL_MS);
		if (typeof timer.unref === "function") timer.unref();

		electron.app.on("will-quit", () => {
			clearInterval(timer);
			server.close();
			try {
				fs.unlinkSync(target);
			} catch {}
		});
	}

	// On disk rather than on stdout, and written unconditionally: the question it
	// exists to answer — was the app asked to stop, and did it get to finish? —
	// can only be read after the reboot that ended the process being asked.
	const shutdownLog = (line) => {
		try {
			const file = path.join(electron.app.getPath("userData"), "linux-shutdown.log");
			// Six reboots is plenty of history for a file nobody prunes.
			try {
				if (fs.statSync(file).size > 8192) fs.truncateSync(file, 0);
			} catch {}
			fs.appendFileSync(file, `${new Date().toISOString()} ${line}\n`);
		} catch {}
	};

	// Chromium picks its password store from XDG_CURRENT_DESKTOP, and on Hyprland
	// — on any compositor it has not heard of — it recognises nothing and
	// safeStorage.isEncryptionAvailable() comes back false. The app takes that at
	// its word and never writes session.bin at all, so the login lives in memory
	// and dies with the process: quitting the app logs you out.
	//
	// The Secret Service is there, it just has to be named. Set
	// PROMETHEE_PASSWORD_STORE to override — "basic" for a machine with no
	// keyring, where the alternative is not persisting at all.
	if (!process.argv.some((arg) => arg.startsWith("--password-store"))) {
		electron.app.commandLine.appendSwitch(
			"password-store",
			process.env.PROMETHEE_PASSWORD_STORE || "gnome-libsecret",
		);
	}

	// Whether the encrypted session survived the last stop is the one fact this
	// log exists to establish, and it has to be read before the app gets a
	// chance to wipe it.
	shutdownLog(
		`started pid ${process.pid}, session.bin ${
			fs.existsSync(path.join(electron.app.getPath("userData"), "session.bin"))
				? "present"
				: "MISSING"
		}`,
	);

	// Nothing asks a Windows tray app to stop; here everything does — systemd on
	// logout, the session manager on reboot, a plain `kill`. Being killed
	// mid-rotation would lose the login for good: the refresh token is rotated on
	// every use and only reaches disk when the app writes it, so the copy left in
	// session.bin would be one the server has already spent.
	//
	// The log says that is not what happens: SIGTERM reaches will-quit and exit 0
	// with this handler never firing, because Electron already stops cleanly on a
	// signal. It stays as a floor under that behaviour, not as a fix for it.
	let quitting = false;
	for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"]) {
		process.on(signal, () => {
			if (quitting) return;
			quitting = true;
			log(`${signal} — quitting`);
			shutdownLog(`${signal} received, quitting`);
			try {
				electron.app.quit();
			} catch {
				shutdownLog("app.quit() threw, exiting");
				process.exit(0);
			}
			// A hung renderer must not turn a clean stop into a hard kill.
			const bail = setTimeout(() => {
				shutdownLog("quit did not finish in 4s, exiting anyway");
				process.exit(0);
			}, 4000);
			if (typeof bail.unref === "function") bail.unref();
		});
	}

	electron.app.on("will-quit", () => shutdownLog("will-quit"));
	process.on("exit", (code) => shutdownLog(`exit ${code}`));

	globalThis.__prometheeControl = { invoke, readState, socketPath };

	// Logged next to the start line, because "the login did not persist" and
	// "encryption was unavailable" are the same event seen from two ends.
	electron.app.whenReady().then(() => {
		shutdownLog(
			`safeStorage ${electron.safeStorage.isEncryptionAvailable() ? "available" : "UNAVAILABLE"}` +
				` (backend ${electron.safeStorage.getSelectedStorageBackend?.() ?? "unknown"})`,
		);
	});

	// The socket is only useful once handlers are registered, and they register
	// during app startup.
	if (electron.app.isReady()) listen();
	else electron.app.once("ready", listen);
})();
