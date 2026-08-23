#!/usr/bin/env node
/**
 * Rewrites Promethee's main-process bundles so the app works on Linux.
 *
 * Usage: node scripts/apply-patches.mjs <extracted-app-dir>
 *
 * The bundles are minified and their identifiers are regenerated on every
 * upstream build, so every patch anchors on a structural signature rather than
 * on a name. A required patch that matches nothing fails the run rather than
 * producing a half-working app.
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.join(here, "..");

const appDir = process.argv[2];
if (!appDir) {
	console.error("usage: apply-patches.mjs <extracted-app-dir>");
	process.exit(1);
}

const buildDir = path.join(appDir, ".vite", "build");
if (!fs.existsSync(buildDir)) {
	console.error(`no .vite/build in ${appDir} — is this an extracted app.asar?`);
	process.exit(1);
}

/** Bundle files, largest first: the main bundle is always the big index-*.js. */
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

const sources = new Map(
	bundles.map((f) => [f, fs.readFileSync(path.join(buildDir, f), "utf8")]),
);

let failed = false;

/**
 * @param name     human label, shown in the run log
 * @param files    bundle filenames to try
 * @param fn       (source) => [newSource, siteCount]
 * @param required whether a zero-match aborts the build
 */
function patch(name, files, fn, { required = true } = {}) {
	let total = 0;
	for (const file of files) {
		const before = sources.get(file);
		const [after, count] = fn(before);
		if (count > 0 && after !== before) {
			sources.set(file, after);
			total += count;
			console.log(`  ok    ${name} — ${count} site(s) in ${file}`);
		}
	}
	if (total === 0) {
		const level = required ? "FAIL " : "warn ";
		console.error(`  ${level} ${name}: no match — upstream layout changed`);
		if (required) failed = true;
	}
	return total;
}

console.log(`patching ${bundles.length} bundle(s) in ${path.relative(process.cwd(), buildDir)}`);

// ---------------------------------------------------------------------------
// 1. Inject the Linux active-window backend into the main bundle.

patch("inject active-window shim", [mainBundle], (src) => {
	if (src.includes("__prometheeLinuxActiveWindow")) return [src, 0];
	const shim = fs.readFileSync(path.join(repoRoot, "patches", "linux-active-window.js"), "utf8");
	return [`${shim}\n${src}`, 1];
});

// ---------------------------------------------------------------------------
// 2. Route the platform dispatcher through it.
//
// Upstream:
//   async function Aw(e={}){if(process.platform==="win32")return Iqe(e);
//                           if(process.platform!=="darwin")return null; ...}
// Identifiers vary per build; the two consecutive platform checks do not.

patch("linux branch in activeWindow dispatcher", [mainBundle], (src) => {
	const re =
		/(async function \w+\(\w+=\{\}\)\{if\(process\.platform==="win32"\)return \w+\(\w+\);)(if\(process\.platform!=="darwin"\)return null;)/g;
	let count = 0;
	const out = src.replace(re, (_m, head, tail) => {
		count += 1;
		return `${head}if(process.platform==="linux")return globalThis.__prometheeLinuxActiveWindow();${tail}`;
	});
	return [out, count];
});

// ---------------------------------------------------------------------------
// 3. Switch the auto-updater off.
//
// electron-updater's Linux path hard-requires an APPIMAGE env var and throws
// ERR_UPDATER_OLD_FILE_NOT_FOUND without one. There is no Linux release channel
// to update from anyway, so answer its own isUpdaterActive() guard with false.

patch(
	"disable auto-updater",
	bundles,
	(src) => {
		const re = /(isUpdaterActive\(\)\s*\{)/g;
		let count = 0;
		const out = src.replace(re, (_m, head) => {
			count += 1;
			return `${head}if(process.platform==="linux")return!1;`;
		});
		return [out, count];
	},
	{ required: false },
);

// ---------------------------------------------------------------------------

if (failed) {
	console.error("\naborted: a required patch did not apply — nothing written");
	process.exit(1);
}

for (const [file, src] of sources) {
	fs.writeFileSync(path.join(buildDir, file), src);
}

console.log("\npatches applied");
