#!/usr/bin/env node
/**
 * Exercises the patch anchors against synthetic fixtures.
 *
 *   node scripts/anchors.test.mjs
 *
 * Promethee's real bundle can't be committed, so the fixtures reproduce the
 * minified shapes the anchors target, including renamed identifiers, which is
 * exactly what changes between upstream builds. If a refactor makes an anchor
 * too strict (or too loose), this catches it without needing a copy of the app.
 */

import assert from "node:assert/strict";
import { PATCHES } from "./patches.mjs";

const patchByName = (name) => {
	const found = PATCHES.find((p) => p.name === name);
	assert.ok(found, `no patch named ${name}`);
	return found;
};

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

console.log("active-window dispatcher");

const dispatcher = patchByName("linux branch in activeWindow dispatcher");

// Minified exactly as upstream emits it, at 1.3.26.
const REAL_SHAPE =
	'async function Aw(e={}){if(process.platform==="win32")return Iqe(e);' +
	'if(process.platform!=="darwin")return null;const t=Cqe();if(!t)return null;}';

test("matches the upstream shape", () => {
	const [out, count] = dispatcher.apply(REAL_SHAPE);
	assert.equal(count, 1);
	assert.match(
		out,
		/if \(process\.platform === "linux"\) return globalThis\.__prometheeLinuxActiveWindow\(\);/,
	);
});

test("linux branch precedes the darwin fallthrough", () => {
	const [out] = dispatcher.apply(REAL_SHAPE);
	// Order matters: after the darwin check, `return null` already won.
	assert.ok(out.indexOf('"linux"') < out.indexOf('!=="darwin"'));
});

test("survives renamed identifiers", () => {
	const renamed = REAL_SHAPE.replace(/Aw/g, "Zq9")
		.replace(/Iqe/g, "b7X")
		.replace(/\be=/g, "n=")
		.replace(/\(e\)/g, "(n)");
	const [, count] = dispatcher.apply(renamed);
	assert.equal(count, 1);
});

test("ignores an unrelated platform check", () => {
	const unrelated = 'function f(){if(process.platform==="win32")return 1;return 2;}';
	const [, count] = dispatcher.apply(unrelated);
	assert.equal(count, 0);
});

test("is idempotent enough to not double-patch a patched bundle", () => {
	const [once] = dispatcher.apply(REAL_SHAPE);
	const [twice, count] = dispatcher.apply(once);
	assert.equal(count, 0, "already-patched source should no longer match");
	assert.equal(twice, once);
});

// ---------------------------------------------------------------------------

console.log("shim injection");

const inject = patchByName("inject active-window shim");

test("prepends the shim", () => {
	const [out, count] = inject.apply("const a=1;", { shim: "/*SHIM*/" });
	assert.equal(count, 1);
	assert.ok(out.startsWith("/*SHIM*/"));
});

test("refuses to inject twice", () => {
	const [once] = inject.apply("const a=1;", { shim: "globalThis.__prometheeLinuxActiveWindow=0;" });
	const [, count] = inject.apply(once, { shim: "globalThis.__prometheeLinuxActiveWindow=0;" });
	assert.equal(count, 0);
});

// ---------------------------------------------------------------------------

console.log("control socket injection");

const control = patchByName("inject control socket");

test("prepends the control shim", () => {
	const [out, count] = control.apply("const a=1;", { controlShim: "/*CONTROL*/" });
	assert.equal(count, 1);
	assert.ok(out.startsWith("/*CONTROL*/"));
});

test("stays ahead of the bundle so it can wrap ipcMain.handle", () => {
	const [out] = control.apply("ipcMain.handle('x',f);", { controlShim: "/*CONTROL*/" });
	assert.ok(out.indexOf("/*CONTROL*/") < out.indexOf("ipcMain.handle"));
});

test("refuses to inject twice", () => {
	const [once] = control.apply("const a=1;", { controlShim: "globalThis.__prometheeControl=0;" });
	const [, count] = control.apply(once, { controlShim: "globalThis.__prometheeControl=0;" });
	assert.equal(count, 0);
});

// ---------------------------------------------------------------------------

console.log("auto-updater");

const updater = patchByName("disable auto-updater");

test("guards isUpdaterActive", () => {
	const [out, count] = updater.apply("isUpdaterActive(){return this._isUpdaterActive}");
	assert.equal(count, 1);
	assert.match(out, /isUpdaterActive\(\)\{if \(process\.platform === "linux"\) return false;/);
});

test("does not stack a second guard on a patched bundle", () => {
	const [once] = updater.apply("isUpdaterActive(){return this._isUpdaterActive}");
	const [twice, count] = updater.apply(once);
	assert.equal(count, 0);
	assert.equal(twice, once);
});

test("is not required, upstream may drop the updater", () => {
	assert.equal(updater.required, false);
});

// ---------------------------------------------------------------------------

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
