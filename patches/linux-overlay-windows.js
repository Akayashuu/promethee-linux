/**
 * Names Promethee's windows, one name per role.
 *
 * The app is built around always-on-top overlays: the HUD pill, the chat and
 * quest panels, notifications, the end-of-session effect. Each one is a
 * frameless, transparent, `focusable: false` window that places itself over
 * whatever you are doing and paints only the few pixels it needs.
 *
 * None of that survives the trip to Wayland. `alwaysOnTop`, `skipTaskbar`,
 * `type` and the window's own x/y are all no-ops there, so a tiling compositor
 * treats an overlay as an ordinary window and hands it a tile. The chat panel
 * is the one you notice: collapsed, it draws a launcher bubble at the bottom
 * and leaves the rest of its surface transparent, so what lands on screen is a
 * large see-through rectangle holding half a workspace hostage. Its input
 * region is empty too, so it cannot even be clicked away.
 *
 * A compositor rule is the only thing that can put those windows back where
 * they belong, and a rule needs something to match on. Every Promethee window
 * is class `promethee` titled `Promethee`, which is nothing to match on. So
 * name them. The role a window loads with is already in its own query string;
 * this shim turns that into a title. `Promethee`, alone, stays the main
 * window. Every overlay becomes `Promethee <role>`, which is what the rules in
 * wm/ key off.
 */
(() => {
	if (process.platform !== "linux") return;
	if (globalThis.__prometheeOverlayNames) return;

	const electron = require("electron");

	/** Each window loads its renderer with ?mode=<role>. */
	const ROLES = {
		full: "", // the main window, and the only one that keeps the bare name
		floating: "HUD",
		notification: "Notifications",
		"panel-block": "Panel",
		"session-end-fx": "Session End",
		"session-complete": "Session Complete",
		poster: "Poster",
	};

	/**
	 * A role upstream may add after this was written still gets a name, because
	 * a new overlay nobody floats is the bug this shim exists to stop.
	 */
	const UNKNOWN = "Overlay";

	function nameFor(url) {
		let query;
		try {
			query = new URL(url).searchParams;
		} catch {
			return null;
		}
		const mode = query.get("mode");
		if (!mode) return null;

		const role = mode in ROLES ? ROLES[mode] : UNKNOWN;
		if (!role) return "Promethee";

		// The panels are one window each, and they are told apart by block id:
		// `dm` is the chat, `quests` the quest list. Worth carrying, so a rule
		// can put the chat somewhere other than the rest.
		const block = mode === "panel-block" ? query.get("block") : null;
		return block ? `Promethee ${role} ${block}` : `Promethee ${role}`;
	}

	electron.app.on("browser-window-created", (_event, win) => {
		let name = null;

		const apply = (url) => {
			const next = nameFor(url);
			if (!next || next === name) return;
			name = next;
			try {
				win.setTitle(next);
			} catch {}
		};

		const applyFromWindow = () => {
			try {
				apply(win.webContents.getURL());
			} catch {}
		};

		// Every renderer sets the same document title and Electron mirrors it
		// onto the window, so the name has to be defended, not just set once.
		win.on("page-title-updated", (event) => {
			if (!name) return;
			event.preventDefault();
			win.setTitle(name);
		});

		// A compositor reads the title once, when the window is mapped, and a
		// rule that missed its window does not get a second chance: Hyprland
		// re-evaluates opacity and blur on a rename, never float. So the name
		// has to be on before the map, and the map is show().
		win.webContents.on("did-navigate", (_e, url) => apply(url));
		win.webContents.on("did-finish-load", applyFromWindow);
		win.on("ready-to-show", applyFromWindow);

		// The three above all land before show() in the order upstream does
		// things today. This is the one that does not depend on that order:
		// whatever the app calls, the window is named on the way out.
		for (const method of ["show", "showInactive"]) {
			const original = win[method];
			if (typeof original !== "function") continue;
			win[method] = (...args) => {
				applyFromWindow();
				return original.apply(win, args);
			};
		}
	});

	globalThis.__prometheeOverlayNames = { nameFor };
})();
