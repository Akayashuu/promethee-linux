/**
 * Promethee-linux: durable session persistence.
 *
 * The whole logged-in state is three files in userData: session.bin (the
 * Supabase tokens, encrypted through safeStorage), has-session.json (the flag
 * restoreSession() checks before it will even read the tokens) and
 * session-user.json (the cached user, which is what keeps a start with no
 * network from logging you out).
 *
 * None of the three is written durably. session.bin gets an fsync of the file
 * but is opened with "w", so it is truncated in place and the directory entry
 * is never synced; the other two are a bare writeFileSync. A hard reboot can
 * therefore take all three, and it does: after one here, the app came back with
 * session.bin gone and restoreSession() reporting "new install". Nothing had
 * signed out, nothing had expired, the machine had simply stopped without
 * asking.
 *
 * So keep a copy that is written the way the originals should have been:
 * a temp file, fsync, rename, then fsync of the directory, which is what makes
 * the rename itself survive. On a start where session.bin is absent, put the
 * three files back and let the app carry on as if nothing had happened.
 *
 * The one case that must still log you out is a session that is genuinely over.
 * That case is distinguishable: signOut and the zombie path both delete the
 * three files while the app is running, so a disappearance this process
 * witnesses is deliberate and takes the copy with it. A disappearance that has
 * already happened by the time the process starts is the other thing entirely.
 */
(() => {
	if (process.platform !== "linux") return;
	if (globalThis.__prometheeSessionMirror) return;

	const electron = require("electron");
	const fs = require("node:fs");
	const path = require("node:path");

	/** In restore order. session.bin is the one whose absence means "logged out". */
	const AUTH_FILES = ["session.bin", "has-session.json", "session-user.json"];
	const MIRROR = "linux-session-mirror.json";
	/** A floor under inotify, which can be unavailable or miss under load. */
	const POLL_MS = 15000;
	/** Long enough to coalesce a token rotation's three writes, short enough to lose nothing. */
	const DEBOUNCE_MS = 250;

	const log = (...a) => {
		if (process.env.PROMETHEE_LINUX_DEBUG) console.log("[promethee-session]", ...a);
	};

	const dir = electron.app.getPath("userData");
	const at = (name) => path.join(dir, name);

	// ------------------------------------------------------------- durability

	/**
	 * A rename is a change to a directory, and is no more durable than the write
	 * that preceded it. Without this the entry can be missing after a crash even
	 * though the file's own contents were synced, which is the failure this whole
	 * shim exists to answer.
	 */
	function fsyncDir(target) {
		const fd = fs.openSync(path.dirname(target), "r");
		try {
			fs.fsyncSync(fd);
		} finally {
			fs.closeSync(fd);
		}
	}

	function writeDurable(target, data) {
		const tmp = `${target}.tmp`;
		const fd = fs.openSync(tmp, "w", 0o600);
		try {
			fs.writeSync(fd, data);
			fs.fsyncSync(fd);
		} finally {
			fs.closeSync(fd);
		}
		fs.renameSync(tmp, target);
		fsyncDir(target);
	}

	// ------------------------------------------------------------------ mirror

	/** Base64 rather than raw: session.bin is safeStorage ciphertext, not text. */
	function snapshot() {
		const out = {};
		for (const name of AUTH_FILES) {
			try {
				out[name] = fs.readFileSync(at(name)).toString("base64");
			} catch {}
		}
		return out;
	}

	/** A mirror without tokens is not a session, whatever else it holds. */
	function readMirror() {
		let stored;
		try {
			stored = JSON.parse(fs.readFileSync(at(MIRROR), "utf8"));
		} catch {
			return null;
		}
		return stored && typeof stored["session.bin"] === "string" ? stored : null;
	}

	/** What was last written, so an unchanged snapshot costs no fsyncs. */
	let mirrored = "";

	function save() {
		const shot = snapshot();
		// Without the tokens the rest is not a session worth restoring.
		if (typeof shot["session.bin"] !== "string") return;

		// Union, not replacement. Upstream writes the three files separately, so a
		// snapshot can catch a moment where one of them is briefly absent, and an
		// absence must never erase the copy that is the only reason the next start
		// can put that file back. Only a sign-out clears the mirror, and it clears
		// all of it at once.
		const body = JSON.stringify({ ...(readMirror() ?? {}), ...shot });
		if (body === mirrored) return;
		try {
			writeDurable(at(MIRROR), body);
			mirrored = body;
			log("mirror updated");
		} catch (err) {
			log("mirror write failed:", err?.message || err);
		}
	}

	function drop() {
		mirrored = "";
		try {
			fs.unlinkSync(at(MIRROR));
			fsyncDir(at(MIRROR));
			log("mirror dropped");
		} catch {}
	}

	/**
	 * Puts back every auth file the mirror has and the disk does not. Files that
	 * are present are left alone: the copy is a backstop, never an authority, and
	 * the app's own writes always win.
	 */
	function restoreMissing() {
		const stored = readMirror();
		if (!stored) return [];

		const back = [];
		for (const name of AUTH_FILES) {
			if (typeof stored[name] !== "string") continue;
			if (fs.existsSync(at(name))) continue;
			try {
				writeDurable(at(name), Buffer.from(stored[name], "base64"));
				back.push(name);
			} catch (err) {
				log(`restore of ${name} failed:`, err?.message || err);
			}
		}
		return back;
	}

	// ------------------------------------------------------------------- state

	/** Whether this process has seen a session on disk, which is what makes a later absence deliberate. */
	let held = fs.existsSync(at("session.bin"));

	// Startup only. A file missing here went missing with nobody watching, which
	// is the crash. From this point on a disappearance has an author and means
	// the opposite. has-session.json counts as much as the tokens do: the app
	// checks that flag first and calls a start without it a new install, so
	// losing that one file is a full logout with the tokens still sitting there.
	const back = restoreMissing();
	const restored = back.includes("session.bin");
	if (back.length) log("restored from mirror:", back.join(", "));
	if (restored) held = true;
	if (held) save();

	function sync() {
		if (fs.existsSync(at("session.bin"))) {
			held = true;
			save();
			return;
		}
		if (!held) return;
		// Signed out, or a refresh token the server refused. Both are a session
		// that is over, and a copy of it is the last thing anyone wants kept.
		held = false;
		drop();
	}

	let pending = null;
	function schedule() {
		if (pending) return;
		pending = setTimeout(() => {
			pending = null;
			sync();
		}, DEBOUNCE_MS);
		pending.unref?.();
	}

	// The tokens rotate on every refresh and only the newest one is still good,
	// so the copy has to follow within milliseconds, not on the next poll.
	try {
		fs.watch(dir, (_event, name) => {
			if (name && AUTH_FILES.includes(name)) schedule();
		}).unref?.();
	} catch (err) {
		log("watch unavailable, polling only:", err?.message || err);
	}

	const timer = setInterval(sync, POLL_MS);
	timer.unref?.();

	electron.app.on("will-quit", sync);

	globalThis.__prometheeSessionMirror = { restored, save, sync };
})();
