#!/usr/bin/env node
/**
 * Exercises the window-naming shim against a fake Electron.
 *
 *   node scripts/overlay-names.test.mjs
 *
 * The names are an interface: wm/hyprland.conf and wm/sway.conf match on them,
 * and so does anything a user writes. A window that silently stops being named
 * is a window their compositor starts tiling again, which is the whole bug.
 */

import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import fs from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const shimSource = fs.readFileSync(
	path.join(here, "..", "patches", "linux-overlay-windows.js"),
	"utf8",
);
const nodeRequire = createRequire(import.meta.url);

/** The renderer file, as the app loads it: one HTML entry, a mode per window. */
const RENDERER = "file:///opt/promethee/.vite/renderer/main_window/index.html";

/** Enough BrowserWindow for a shim that only reads a URL and sets a title. */
class FakeWindow extends EventEmitter {
	constructor(url) {
		super();
		this.url = url;
		this.title = "Promethee";
		this.webContents = new EventEmitter();
		this.webContents.getURL = () => this.url;
	}

	setTitle(title) {
		this.title = title;
	}

	/** The moment the compositor first sees the window, and its title. */
	show() {
		this.titleAtMap = this.title;
	}

	showInactive() {
		this.show();
	}

	/** The navigation the app's own loadFile() causes. */
	load() {
		this.webContents.emit("did-navigate", {}, this.url);
		this.webContents.emit("did-finish-load");
	}

	/** The renderer setting document.title, which Electron mirrors. */
	saysItsTitleIs(title) {
		let prevented = false;
		this.emit("page-title-updated", { preventDefault: () => (prevented = true) }, title);
		if (!prevented) this.title = title;
		return prevented;
	}
}

/** Loads a fresh copy of the shim and returns the window factory it installs. */
function start() {
	delete globalThis.__prometheeOverlayNames;
	let onCreated = null;
	let listeners = 0;
	const require = (id) =>
		id === "electron"
			? {
					app: {
						on(event, fn) {
							listeners += 1;
							if (event === "browser-window-created") onCreated = fn;
						},
					},
				}
			: nodeRequire(id);

	new Function("require", shimSource)(require);

	return {
		listeners: () => listeners,
		reload: () => new Function("require", shimSource)(require),
		/** Opens a window the way the app does: construct, then load. */
		openAt(url) {
			const win = new FakeWindow(url);
			onCreated({}, win);
			win.load();
			return win;
		},
		open(query) {
			return this.openAt(`${RENDERER}?${query}`);
		},
		/** A window whose navigation events never arrive, only ready-to-show. */
		openQuietly(query) {
			const win = new FakeWindow(`${RENDERER}?${query}`);
			onCreated({}, win);
			win.emit("ready-to-show");
			return win;
		},
		/** A window that reaches the compositor with no event firing at all. */
		openSilently(query, method = "show") {
			const win = new FakeWindow(`${RENDERER}?${query}`);
			onCreated({}, win);
			win[method]();
			return win;
		},
	};
}

let passed = 0;
let failed = 0;

function test(label, fn) {
	try {
		fn();
		passed += 1;
		console.log(`  ok    ${label}`);
	} catch (err) {
		failed += 1;
		console.error(`  FAIL  ${label}\n        ${err.message}`);
	}
}

// ---------------------------------------------------------------------------

console.log("naming");

test("names the collapsed chat panel, the window nobody can see", () => {
	const app = start();
	const win = app.open(
		"mode=panel-block&block=dm&direction=below&collapsed=1&ldir=up&lanchor=left",
	);
	assert.equal(win.title, "Promethee Panel dm");
});

test("tells one panel from another", () => {
	const app = start();
	assert.equal(app.open("mode=panel-block&block=quests").title, "Promethee Panel quests");
	assert.equal(app.open("mode=panel-block&block=planning").title, "Promethee Panel planning");
});

test("names the HUD pill", () => {
	assert.equal(start().open("mode=floating").title, "Promethee HUD");
});

test("names the rest of the overlays", () => {
	const app = start();
	assert.equal(app.open("mode=notification&direction=up").title, "Promethee Notifications");
	assert.equal(app.open("mode=session-complete").title, "Promethee Session Complete");
	assert.equal(app.open("mode=session-end-fx&autoplay=1").title, "Promethee Session End");
	assert.equal(app.open("mode=poster").title, "Promethee Poster");
});

test("leaves the dashboard as plain Promethee, which the rules depend on", () => {
	// Every rule floats `Promethee <something>`. The one window that must stay
	// tileable is the one that must stay unadorned.
	assert.equal(start().open("mode=full").title, "Promethee");
});

test("names a role upstream has not written yet", () => {
	// An overlay nobody thought to float is exactly this bug, again.
	assert.equal(start().open("mode=whatever-comes-next").title, "Promethee Overlay");
});

test("works against the dev server too", () => {
	// Upstream loads a URL instead of a file when it is running vite; the mode
	// rides in the query either way.
	const win = start().openAt("http://localhost:5173/?mode=floating");
	assert.equal(win.title, "Promethee HUD");
});

test("says nothing about a window with no mode", () => {
	const win = start().openAt("about:blank");
	assert.equal(win.title, "Promethee");
	assert.equal(win.saysItsTitleIs("Something Else"), false, "an unnamed window is upstream's");
	assert.equal(win.title, "Something Else");
});

// ---------------------------------------------------------------------------

console.log("keeping the name");

test("defends the name against the renderer's document title", () => {
	const app = start();
	const win = app.open("mode=panel-block&block=dm");
	assert.equal(win.saysItsTitleIs("Promethee"), true, "the update should be prevented");
	assert.equal(win.title, "Promethee Panel dm");
});

test("holds the dashboard to its own name as well", () => {
	const app = start();
	const win = app.open("mode=full");
	win.saysItsTitleIs("Promethee - Quests");
	assert.equal(win.title, "Promethee");
});

test("names a window that only ever reaches ready-to-show", () => {
	// The compositor reads the title when the window is mapped, and show() is
	// called from ready-to-show. This is the last moment that still counts.
	assert.equal(start().openQuietly("mode=notification").title, "Promethee Notifications");
});

test("is named before the compositor ever sees it", () => {
	// The one that matters. A compositor reads the title when the window is
	// mapped, and never re-runs `float` on a rename, so a name that arrives
	// after show() is a name that arrives too late.
	const win = start().openSilently("mode=panel-block&block=dm");
	assert.equal(win.titleAtMap, "Promethee Panel dm");
});

test("names a window shown without focus too", () => {
	const win = start().openSilently("mode=notification", "showInactive");
	assert.equal(win.titleAtMap, "Promethee Notifications");
});

test("still shows the window it named", () => {
	const app = start();
	const win = app.open("mode=full");
	win.show();
	assert.equal(win.titleAtMap, "Promethee", "show() must call through, not swallow");
});

test("does not install itself twice", () => {
	const app = start();
	const before = app.listeners();
	app.reload();
	assert.equal(app.listeners(), before);
});

// ---------------------------------------------------------------------------

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
