#!/usr/bin/env node
/**
 * Applies the Linux patches to an extracted Promethee app bundle.
 *
 *   node scripts/apply-patches.mjs <extracted-app-dir>
 *
 * The patch definitions live in patches.mjs; this file only locates the
 * bundles, runs the transforms and writes the result. A required patch that
 * matches nothing aborts before anything is written, because a loud failure
 * beats a half-working app.
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { PATCHES, TARGET } from "./patches.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.join(here, "..");

const appDir = process.argv[2];
if (!appDir) {
	console.error("usage: apply-patches.mjs <extracted-app-dir>");
	process.exit(1);
}

const buildDir = path.join(appDir, ".vite", "build");
if (!fs.existsSync(buildDir)) {
	console.error(`no .vite/build in ${appDir}: is this an extracted app.asar?`);
	process.exit(1);
}

// Largest first: the main-process bundle is always the big index-*.js.
const bundles = fs
	.readdirSync(buildDir)
	.filter((f) => f.endsWith(".js"))
	.map((f) => ({ file: f, size: fs.statSync(path.join(buildDir, f)).size }))
	.sort((a, b) => b.size - a.size)
	.map((entry) => entry.file);

const mainBundle = bundles.find((f) => /^index-.*\.js$/.test(f));
if (!mainBundle) {
	console.error("no index-*.js bundle found");
	process.exit(1);
}

const sources = new Map(bundles.map((f) => [f, fs.readFileSync(path.join(buildDir, f), "utf8")]));

const context = {
	shim: fs.readFileSync(path.join(repoRoot, "patches", "linux-active-window.js"), "utf8"),
	controlShim: fs.readFileSync(path.join(repoRoot, "patches", "promethee-control.js"), "utf8"),
};

console.log(`patching ${bundles.length} bundle(s) in ${path.relative(process.cwd(), buildDir)}`);

// The shim's global is the marker: if it's already there, this bundle has been
// through the patcher before.
const alreadyPatched = sources.get(mainBundle).includes("__prometheeLinuxActiveWindow");

let failed = false;

for (const patch of PATCHES) {
	const targets = patch.target === TARGET.MAIN ? [mainBundle] : bundles;
	let total = 0;

	for (const file of targets) {
		const before = sources.get(file);
		const [after, count] = patch.apply(before, context);
		if (count > 0 && after !== before) {
			sources.set(file, after);
			total += count;
			console.log(`  ok    ${patch.name}: ${count} site(s) in ${file}`);
		}
	}

	if (total === 0) {
		// Zero matches has two very different causes. Saying "upstream changed"
		// when the bundle is simply already patched sends people hunting a bug
		// that isn't there.
		const reason = alreadyPatched
			? "already patched, re-extract app.asar for a clean build"
			: "no match, upstream layout changed";
		console.error(`  ${patch.required ? "FAIL " : "warn "} ${patch.name}: ${reason}`);
		if (patch.required) failed = true;
	}
}

if (failed) {
	console.error("\naborted: a required patch did not apply. Nothing written");
	process.exit(1);
}

for (const [file, source] of sources) {
	fs.writeFileSync(path.join(buildDir, file), source);
}

console.log("\npatches applied");
