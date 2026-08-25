/**
 * Promethee-linux — active-window backend for Linux.
 *
 * Upstream's activeWindow() has branches for win32 (get-windows) and darwin
 * (NSWorkspace) only; everything else returns null, which silently kills the
 * activity tracking that the whole product is built on.
 *
 * This shim is injected at the top of the main bundle and exposed as
 * globalThis.__prometheeLinuxActiveWindow. The bundle's own dispatcher is
 * rewritten to call it when process.platform === "linux".
 *
 * It must return exactly the shape upstream builds from get-windows:
 *   { owner: { name, bundleId, processId, path }, title, source, frame }
 */
(() => {
	if (process.platform !== "linux") return;
	if (globalThis.__prometheeLinuxActiveWindow) return;

	const net = require("node:net");
	const fs = require("node:fs");
	const path = require("node:path");
	const os = require("node:os");
	const { execFile } = require("node:child_process");

	const IPC_TIMEOUT_MS = 1500;

	const log = (...a) => {
		if (process.env.PROMETHEE_LINUX_DEBUG) console.log("[promethee-linux]", ...a);
	};

	// ------------------------------------------------------------ helpers

	function run(cmd, args) {
		return new Promise((resolve) => {
			execFile(cmd, args, { timeout: IPC_TIMEOUT_MS }, (err, stdout) =>
				resolve(err ? null : String(stdout || "")),
			);
		});
	}

	function num(v) {
		return typeof v === "number" && Number.isFinite(v) ? v : null;
	}

	function frameFrom(x, y, width, height) {
		const vals = [num(x), num(y), num(width), num(height)];
		if (vals.some((v) => v === null)) return null;
		return { x: vals[0], y: vals[1], width: vals[2], height: vals[3] };
	}

	/** Resolve the real executable path of a pid, if the kernel lets us. */
	function exePathOf(pid) {
		if (!pid) return null;
		try {
			return fs.readlinkSync(`/proc/${pid}/exe`);
		} catch {
			return null;
		}
	}

	// ------------------------------------------- .desktop name resolution

	// Window classes are slugs ("code-oss", "org.gnome.Nautilus"). Users expect
	// the name they see in their launcher, so index the desktop entries once and
	// map class -> Name=. Falls back to a tidied-up class.

	let desktopIndex = null;

	function buildDesktopIndex() {
		const index = new Map();
		const dataDirs = [
			path.join(os.homedir(), ".local/share"),
			...(process.env.XDG_DATA_DIRS || "/usr/local/share:/usr/share").split(":"),
		].filter(Boolean);

		for (const dir of dataDirs) {
			const appsDir = path.join(dir, "applications");
			let entries;
			try {
				entries = fs.readdirSync(appsDir);
			} catch {
				continue;
			}
			for (const entry of entries) {
				if (!entry.endsWith(".desktop")) continue;
				let content;
				try {
					content = fs.readFileSync(path.join(appsDir, entry), "utf8");
				} catch {
					continue;
				}
				// Only the [Desktop Entry] group; actions may redefine Name.
				const main = content.split(/^\[/m)[1] || content;
				const name = /^Name=(.+)$/m.exec(main)?.[1]?.trim();
				if (!name) continue;
				const wmClass = /^StartupWMClass=(.+)$/m.exec(main)?.[1]?.trim();
				const basename = entry.slice(0, -".desktop".length);

				// StartupWMClass is authoritative; filename is the common fallback.
				if (wmClass) index.set(wmClass.toLowerCase(), name);
				if (!index.has(basename.toLowerCase())) index.set(basename.toLowerCase(), name);
				// "org.gnome.Nautilus" is also reachable as "nautilus"
				const short = basename.split(".").pop();
				if (short && !index.has(short.toLowerCase())) index.set(short.toLowerCase(), name);
			}
		}
		log(`indexed ${index.size} desktop entries`);
		return index;
	}

	function titleCase(slug) {
		return slug
			.replace(/[-_.]+/g, " ")
			.replace(/\s+/g, " ")
			.trim()
			.replace(/\b\w/g, (c) => c.toUpperCase());
	}

	function prettyName(wmClass, exePath) {
		if (!desktopIndex) desktopIndex = buildDesktopIndex();
		const candidates = [];
		if (wmClass) {
			candidates.push(wmClass, wmClass.split(".").pop());
		}
		if (exePath) candidates.push(path.basename(exePath));

		for (const candidate of candidates) {
			if (!candidate) continue;
			const hit = desktopIndex.get(String(candidate).toLowerCase());
			if (hit) return hit;
		}
		const fallback = wmClass || (exePath ? path.basename(exePath) : "");
		return fallback ? titleCase(fallback) : null;
	}

	function shape(source, { wmClass, title, pid, x, y, width, height }) {
		const exePath = exePathOf(pid);
		const name = prettyName(wmClass, exePath);
		if (!name) return null;
		return {
			owner: {
				name,
				bundleId: null,
				processId: pid || null,
				path: exePath,
			},
			title: title || null,
			source,
			frame: frameFrom(x, y, width, height),
		};
	}

	// ----------------------------------------------------------- Hyprland

	function hyprSocketPath() {
		const runtime = process.env.XDG_RUNTIME_DIR;
		const signature = process.env.HYPRLAND_INSTANCE_SIGNATURE;
		if (!runtime || !signature) return null;
		return path.join(runtime, "hypr", signature, ".socket.sock");
	}

	/** Talk to Hyprland's IPC socket directly — no process spawn per poll. */
	function hyprIPC(command) {
		return new Promise((resolve) => {
			const socketPath = hyprSocketPath();
			if (!socketPath) return resolve(null);

			let out = "";
			let settled = false;
			const finish = (value) => {
				if (settled) return;
				settled = true;
				try {
					socket.destroy();
				} catch {}
				resolve(value);
			};

			const socket = net.createConnection(socketPath);
			socket.setTimeout(IPC_TIMEOUT_MS, () => finish(null));
			socket.on("error", () => finish(null));
			socket.on("connect", () => socket.write(command));
			socket.on("data", (chunk) => {
				out += chunk;
			});
			socket.on("end", () => finish(out || null));
		});
	}

	async function fromHyprland() {
		if (!process.env.HYPRLAND_INSTANCE_SIGNATURE) return null;
		const raw = (await hyprIPC("j/activewindow")) ?? (await run("hyprctl", ["activewindow", "-j"]));
		if (!raw) return null;
		let win;
		try {
			win = JSON.parse(raw);
		} catch {
			return null;
		}
		if (!win?.class) return null;
		const [x, y] = Array.isArray(win.at) ? win.at : [null, null];
		const [width, height] = Array.isArray(win.size) ? win.size : [null, null];
		return shape("hyprland", {
			wmClass: win.initialClass || win.class,
			title: win.title,
			pid: win.pid,
			x,
			y,
			width,
			height,
		});
	}

	// --------------------------------------------------------------- Sway

	function findFocused(node) {
		if (!node || typeof node !== "object") return null;
		if (node.focused && node.pid) return node;
		for (const child of [...(node.nodes || []), ...(node.floating_nodes || [])]) {
			const hit = findFocused(child);
			if (hit) return hit;
		}
		return null;
	}

	async function fromSway() {
		if (!process.env.SWAYSOCK) return null;
		const raw = await run("swaymsg", ["-t", "get_tree", "-r"]);
		if (!raw) return null;
		let tree;
		try {
			tree = JSON.parse(raw);
		} catch {
			return null;
		}
		const win = findFocused(tree);
		if (!win) return null;
		const rect = win.rect || {};
		return shape("sway", {
			wmClass: win.app_id || win.window_properties?.class,
			title: win.name,
			pid: win.pid,
			x: rect.x,
			y: rect.y,
			width: rect.width,
			height: rect.height,
		});
	}

	// ---------------------------------------------------------------- X11

	async function fromX11() {
		if (!process.env.DISPLAY) return null;
		const raw = await run("xdotool", [
			"getactivewindow",
			"getwindowpid",
			"getwindowname",
			"getwindowgeometry",
			"--shell",
		]);
		if (!raw) return null;
		const lines = raw.split("\n");
		const pid = Number.parseInt(lines[0], 10);
		const title = lines[1];
		const geometry = Object.fromEntries(
			lines
				.slice(2)
				.map((line) => line.split("="))
				.filter((pair) => pair.length === 2),
		);

		// xdotool reports no class; read it from the process instead.
		const exePath = exePathOf(pid);
		return shape("x11", {
			wmClass: exePath ? path.basename(exePath) : null,
			title,
			pid: Number.isFinite(pid) ? pid : null,
			x: Number.parseInt(geometry.X, 10),
			y: Number.parseInt(geometry.Y, 10),
			width: Number.parseInt(geometry.WIDTH, 10),
			height: Number.parseInt(geometry.HEIGHT, 10),
		});
	}

	// ----------------------------------------------------------- dispatch

	const BACKENDS = [fromHyprland, fromSway, fromX11];

	// Upstream polls this every few seconds; mirror its own cache window so a
	// burst of callers doesn't fan out into a burst of IPC round-trips.
	const CACHE_MS = 900;
	let cached = null;
	let inflight = null;

	async function detect() {
		for (const backend of BACKENDS) {
			try {
				const result = await backend();
				if (result) return result;
			} catch (err) {
				log("backend failed:", err?.message || err);
			}
		}
		return null;
	}

	globalThis.__prometheeLinuxActiveWindow = function activeWindowLinux() {
		if (cached && Date.now() - cached.at <= CACHE_MS) {
			return Promise.resolve(cached.value);
		}
		if (inflight) return inflight;

		inflight = detect()
			.then((value) => {
				if (value) cached = { at: Date.now(), value };
				inflight = null;
				return value;
			})
			.catch(() => {
				inflight = null;
				return null;
			});
		return inflight;
	};

	log("active-window shim installed");
})();
