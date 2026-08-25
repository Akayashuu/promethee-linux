/**
 * Patch definitions for Promethee's main-process bundles.
 *
 * The bundles are minified and their identifiers are regenerated on every
 * upstream build, so every anchor matches on structure (the shape of a platform
 * check, the name of a public API method) and never on a local name.
 *
 * Each patch is a pure (source) => [source, siteCount] transform so the anchors
 * can be exercised against fixtures without a real bundle. See anchors.test.mjs.
 */

/** Where a patch should be applied. */
export const TARGET = {
	/** The single largest index-*.js, the main-process bundle. */
	MAIN: "main",
	/** Every .js in .vite/build. */
	ALL: "all",
};

/**
 * Injected snippets. Upstream's bundles are minified, but there is no reason for
 * our own additions to be: they stay readable in a devtools view of the shipped
 * app. Each is a single line so it can be spliced anywhere without ASI hazards.
 */
const LINUX_BRANCH =
	'if (process.platform === "linux") return globalThis.__prometheeLinuxActiveWindow();';
const UPDATER_GUARD = 'if (process.platform === "linux") return false;';
const OPAQUE_PLATFORMS = '(process.platform === "win32" || process.platform === "linux")';

export const PATCHES = [
	{
		name: "inject active-window shim",
		target: TARGET.MAIN,
		required: true,
		/**
		 * Prepends the shim. `shim` is injected by the caller so this module
		 * stays free of filesystem access and remains trivially testable.
		 */
		apply(source, { shim = "" } = {}) {
			if (source.includes("__prometheeLinuxActiveWindow")) return [source, 0];
			return [`${shim}\n${source}`, 1];
		},
	},

	{
		name: "inject control socket",
		target: TARGET.MAIN,
		required: true,
		/**
		 * Also a prepend, and it has to stay one: the shim wraps ipcMain.handle,
		 * so it is only useful if it runs before the bundle registers anything.
		 */
		apply(source, { controlShim = "" } = {}) {
			if (source.includes("__prometheeControl")) return [source, 0];
			return [`${controlShim}\n${source}`, 1];
		},
	},

	{
		name: "linux branch in activeWindow dispatcher",
		target: TARGET.MAIN,
		required: true,
		/**
		 * Upstream:
		 *   async function Aw(e={}){if(process.platform==="win32")return Iqe(e);
		 *                           if(process.platform!=="darwin")return null; ...}
		 *
		 * Two consecutive platform checks in that exact order are the signature;
		 * the identifiers around them are not.
		 */
		apply(source) {
			const re =
				/(async function \w+\(\w+=\{\}\)\{if\(process\.platform==="win32"\)return \w+\(\w+\);)(if\(process\.platform!=="darwin"\)return null;)/g;
			let count = 0;
			const out = source.replace(re, (_m, head, tail) => {
				count += 1;
				return `${head}${LINUX_BRANCH}${tail}`;
			});
			return [out, count];
		},
	},

	{
		name: "opaque main window",
		target: TARGET.MAIN,
		// The app still tracks, still runs sessions, still shows its HUD; only its
		// own window is unreadable. Not worth aborting a build over.
		required: false,
		/**
		 * Upstream:
		 *   ...process.platform==="win32"
		 *     ?{transparent:!1,backgroundColor:"#1D1D1D"}
		 *     :{transparent:!0,vibrancy:"under-window",visualEffectState:…}
		 *
		 * There are two branches for three platforms, so Linux takes the macOS one:
		 * a transparent window whose background is painted by the vibrancy layer.
		 * On Linux `vibrancy` is a silent no-op and the page paints no background
		 * of its own (`html,body,#root{background:0 0}`), so nothing fills the
		 * window and it comes up see-through.
		 *
		 * Widening the condition rather than rewriting the branch keeps macOS on
		 * the exact object upstream wrote, including whatever it becomes later.
		 * The vibrancy branch is the anchor: it is the one spread in the bundle
		 * that switches window translucency on platform.
		 */
		apply(source) {
			const re =
				/\.\.\.process\.platform==="win32"\?(\{transparent:!1,backgroundColor:"[^"]*"\}):(\{transparent:!0,vibrancy:"under-window")/g;
			let count = 0;
			const out = source.replace(re, (_m, opaque, translucent) => {
				count += 1;
				return `...${OPAQUE_PLATFORMS}?${opaque}:${translucent}`;
			});
			return [out, count];
		},
	},

	{
		name: "disable auto-updater",
		target: TARGET.ALL,
		// Cosmetic: without it the UI shows an update error, nothing breaks.
		required: false,
		/**
		 * electron-updater's Linux path hard-requires an APPIMAGE env var and
		 * throws ERR_UPDATER_OLD_FILE_NOT_FOUND without one. There is no Linux
		 * release channel anyway, so answer its own guard with false.
		 */
		apply(source) {
			const re = /(isUpdaterActive\(\)\s*\{)(?! ?if \(process\.platform === "linux"\))/g;
			let count = 0;
			const out = source.replace(re, (_m, head) => {
				count += 1;
				return `${head}${UPDATER_GUARD}`;
			});
			return [out, count];
		},
	},
];
