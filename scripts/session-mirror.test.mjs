#!/usr/bin/env node
/**
 * Exercises the session-persistence shim against a real directory.
 *
 *   node scripts/session-mirror.test.mjs
 *
 * The shim decides whether a missing session.bin means "the machine died" or
 * "you signed out", and it gets exactly one chance to be right: too eager and a
 * real sign-out comes back from the dead, too shy and a hard reboot costs you
 * your login. Both directions are worth a test, so the shim is loaded here with
 * a stub Electron and a scratch userData rather than tested by hand.
 */

import assert from "node:assert/strict";
import fs from "node:fs";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

if (process.platform !== "linux") {
	console.log("not linux, nothing to test");
	process.exit(0);
}

const here = path.dirname(fileURLToPath(import.meta.url));
const shimSource = fs.readFileSync(
	path.join(here, "..", "patches", "linux-session-persistence.js"),
	"utf8",
);
const nodeRequire = createRequire(import.meta.url);

const MIRROR = "linux-session-mirror.json";

/**
 * One app start. The shim runs its restore-or-save decision at load time, so
 * loading it again against the same directory is what a relaunch looks like.
 */
function start(userData) {
	// The shim refuses to install itself twice in one process, which is right in
	// the app and unhelpful here.
	delete globalThis.__prometheeSessionMirror;

	const handlers = {};
	const require = (id) =>
		id === "electron"
			? {
					app: {
						getPath: () => userData,
						on: (event, fn) => {
							handlers[event] = fn;
						},
					},
				}
			: nodeRequire(id);

	new Function("require", shimSource)(require);
	return { ...globalThis.__prometheeSessionMirror, handlers };
}

function scratch() {
	return fs.mkdtempSync(path.join(os.tmpdir(), "promethee-session-"));
}

/** What a logged-in userData looks like. session.bin is ciphertext, hence bytes. */
function signIn(dir) {
	fs.writeFileSync(path.join(dir, "session.bin"), Buffer.from([0x00, 0xff, 0x10, 0x00, 0x7f]));
	fs.writeFileSync(path.join(dir, "has-session.json"), '{"hasSession":true}');
	fs.writeFileSync(path.join(dir, "session-user.json"), '{"id":"u1"}');
}

function signOut(dir) {
	for (const name of ["session.bin", "has-session.json", "session-user.json"]) {
		fs.rmSync(path.join(dir, name), { force: true });
	}
}

let passed = 0;
let failed = 0;

function test(label, fn) {
	const dir = scratch();
	try {
		fn(dir);
		passed += 1;
		console.log(`  ok    ${label}`);
	} catch (err) {
		failed += 1;
		console.error(`  FAIL  ${label}\n        ${err.message}`);
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
}

// ---------------------------------------------------------------------------

console.log("mirroring");

test("mirrors a session that is already on disk", (dir) => {
	signIn(dir);
	const mirror = start(dir);
	assert.equal(mirror.restored, false, "nothing was missing, so nothing was restored");
	assert.ok(fs.existsSync(path.join(dir, MIRROR)));
});

test("writes nothing when there is no session to mirror", (dir) => {
	const mirror = start(dir);
	assert.equal(mirror.restored, false);
	assert.equal(fs.existsSync(path.join(dir, MIRROR)), false);
});

test("picks up a session that appears after start", (dir) => {
	const mirror = start(dir);
	signIn(dir);
	mirror.sync();
	assert.ok(fs.existsSync(path.join(dir, MIRROR)), "a login mid-run is still a login");
});

test("leaves no temp file behind", (dir) => {
	signIn(dir);
	start(dir);
	const leftovers = fs.readdirSync(dir).filter((f) => f.endsWith(".tmp"));
	assert.deepEqual(leftovers, []);
});

// ---------------------------------------------------------------------------

console.log("restoring");

test("puts back auth files lost to a crash", (dir) => {
	signIn(dir);
	const before = fs.readFileSync(path.join(dir, "session.bin"));
	start(dir);

	// What the reboot did: the files are gone and no process saw them go.
	signOut(dir);

	const mirror = start(dir);
	assert.equal(mirror.restored, true);
	assert.deepEqual(fs.readFileSync(path.join(dir, "session.bin")), before, "bytes survive intact");
	assert.equal(fs.readFileSync(path.join(dir, "has-session.json"), "utf8"), '{"hasSession":true}');
	assert.equal(fs.readFileSync(path.join(dir, "session-user.json"), "utf8"), '{"id":"u1"}');
});

test("restores the flag file even when the tokens survived", (dir) => {
	signIn(dir);
	start(dir);
	// has-session.json is the file the app checks first, so losing it alone is
	// enough to be told this is a new install, tokens or no tokens.
	fs.rmSync(path.join(dir, "has-session.json"));

	const mirror = start(dir);
	assert.equal(mirror.restored, false, "session.bin was never gone, so this is not a restore");
	assert.equal(fs.readFileSync(path.join(dir, "has-session.json"), "utf8"), '{"hasSession":true}');
});

test("a file briefly absent is not a file forgotten", (dir) => {
	signIn(dir);
	const mirror = start(dir);

	// Upstream writes the three separately, so a save can land in the gap.
	fs.rmSync(path.join(dir, "session-user.json"));
	mirror.save();
	fs.writeFileSync(path.join(dir, "session-user.json"), '{"id":"u1"}');

	signOut(dir);
	assert.equal(start(dir).restored, true);
	assert.equal(
		fs.readFileSync(path.join(dir, "session-user.json"), "utf8"),
		'{"id":"u1"}',
		"the copy outlived the gap",
	);
});

test("restores across as many restarts as it takes", (dir) => {
	signIn(dir);
	start(dir);
	for (let i = 0; i < 3; i += 1) {
		signOut(dir);
		assert.equal(start(dir).restored, true, `restart ${i + 1}`);
	}
});

// ---------------------------------------------------------------------------

console.log("forgetting");

test("drops the mirror when the app signs out", (dir) => {
	signIn(dir);
	const mirror = start(dir);

	// A sign-out, or a refresh token the server refused: the app deletes the
	// files itself, while this process is watching.
	signOut(dir);
	mirror.sync();

	assert.equal(fs.existsSync(path.join(dir, MIRROR)), false);
	assert.equal(start(dir).restored, false, "a session that ended stays ended");
});

test("keeps the mirror dropped after a later restart", (dir) => {
	signIn(dir);
	const mirror = start(dir);
	signOut(dir);
	mirror.sync();
	start(dir);
	assert.equal(fs.existsSync(path.join(dir, "session.bin")), false);
});

test("syncs on will-quit, so the last token rotation is not lost", (dir) => {
	const mirror = start(dir);
	assert.ok(typeof mirror.handlers["will-quit"] === "function", "will-quit is hooked");
	signIn(dir);
	mirror.handlers["will-quit"]();
	assert.ok(fs.existsSync(path.join(dir, MIRROR)));
});

// ---------------------------------------------------------------------------

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
