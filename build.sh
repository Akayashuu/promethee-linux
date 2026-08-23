#!/usr/bin/env bash
#
# promethee-linux — build a native Linux Promethee from a copy you already own.
#
# This script never downloads Promethee. It reads the app bundle from an
# existing install on this machine (a Wine prefix, or a directory you point it
# at), patches it for Linux, and writes a runnable build to ./dist.
#
#   ./build.sh                          # auto-detect a Wine install
#   ./build.sh --source /path/to/resources
#   ./build.sh --install                # also install a .desktop launcher
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="$REPO_DIR/dist"
APP_DIR="$DIST_DIR/app"
SOURCE_DIR=""
DO_INSTALL=0

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- arguments

while [[ $# -gt 0 ]]; do
	case "$1" in
		--source)  SOURCE_DIR="${2:-}"; shift 2 ;;
		--install) DO_INSTALL=1; shift ;;
		-h|--help) sed -n '2,12p' "$0" | sed 's/^# \?//'; exit 0 ;;
		*) die "unknown argument: $1" ;;
	esac
done

# ------------------------------------------------------------ prerequisites

for cmd in node npm python3; do
	command -v "$cmd" >/dev/null || die "$cmd is required but not installed"
done

NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[[ "$NODE_MAJOR" -ge 20 ]] || die "node >= 20 required (found $(node -v))"

# --------------------------------------------------------- locate the source
# We need the directory holding app.asar — i.e. Promethee's resources/ dir.

find_source() {
	[[ -n "$SOURCE_DIR" ]] && { echo "$SOURCE_DIR"; return; }

	local candidate
	while IFS= read -r candidate; do
		[[ -f "$candidate/app.asar" ]] && { echo "$candidate"; return; }
	done < <(
		find "$HOME" -maxdepth 12 -type d -path '*/Promethee/app-*/resources' 2>/dev/null | sort -Vr
	)
}

SOURCE_DIR="$(find_source)"
[[ -n "$SOURCE_DIR" ]] || die "no Promethee install found — pass --source /path/to/resources

Promethee is not distributed for Linux and this repo does not ship it. Install
the Windows build under Wine first, then re-run. The directory you want is the
one containing app.asar, e.g.
  ~/.wine-promethee/drive_c/users/\$USER/AppData/Local/Promethee/app-<version>/resources"

[[ -f "$SOURCE_DIR/app.asar" ]] || die "no app.asar in $SOURCE_DIR"
say "source: $SOURCE_DIR"

# ------------------------------------------------------------------ extract

rm -rf "$APP_DIR"
mkdir -p "$DIST_DIR"

say "extracting app.asar"
npx --yes @electron/asar extract "$SOURCE_DIR/app.asar" "$APP_DIR" >/dev/null

# Natives live outside the archive; copy them in so requires resolve, then
# replace the Windows .node binaries with Linux builds below.
if [[ -d "$SOURCE_DIR/app.asar.unpacked/node_modules" ]]; then
	mkdir -p "$APP_DIR/node_modules"
	cp -rn "$SOURCE_DIR/app.asar.unpacked/node_modules/." "$APP_DIR/node_modules/" 2>/dev/null || true
fi

VERSION="$(node -p "require('$APP_DIR/package.json').version")"
ELECTRON_VERSION="$(node -p "require('$APP_DIR/package.json').devDependencies.electron.replace(/^[^0-9]*/,'')")"
say "Promethee $VERSION (electron $ELECTRON_VERSION)"

# ---------------------------------------------------------- native rebuilds
# better-sqlite3 and keytar ship as win32 .node files. Rebuild both against
# this Electron's ABI. win-vdesktop and get-windows stay Windows-only — the
# bundle already guards those behind a platform check.

say "rebuilding native modules for linux"
BUILD_DIR="$DIST_DIR/.native"
mkdir -p "$BUILD_DIR"
cat > "$BUILD_DIR/package.json" <<EOF
{ "name": "promethee-linux-natives", "version": "1.0.0", "private": true,
  "dependencies": { "better-sqlite3": "^12.11.1", "keytar": "^7.9.0" } }
EOF

(
	cd "$BUILD_DIR"
	npm install --no-audit --no-fund --loglevel=error >/dev/null 2>&1 || true
	# npm >= 11 defers install scripts until approved; prebuilds need them.
	npm install-scripts approve better-sqlite3 keytar >/dev/null 2>&1 || true
	npm rebuild better-sqlite3 keytar --loglevel=error >/dev/null 2>&1
	npx --yes @electron/rebuild -v "$ELECTRON_VERSION" -o better-sqlite3,keytar >/dev/null
)

for mod in better-sqlite3 keytar; do
	# A present directory proves nothing — the compiled addon has to be there.
	if ! find "$BUILD_DIR/node_modules/$mod" -name '*.node' -print -quit | grep -q .; then
		die "failed to build $mod — no .node addon produced.
Native builds need a C++ toolchain: install base-devel / build-essential,
and libsecret (keytar) via libsecret / libsecret-1-dev."
	fi
	rm -rf "${APP_DIR:?}/node_modules/$mod"
	cp -r "$BUILD_DIR/node_modules/$mod" "$APP_DIR/node_modules/"
done

# ------------------------------------------------------------------- patches

say "applying linux patches"
node "$REPO_DIR/scripts/apply-patches.mjs" "$APP_DIR"

# ------------------------------------------------------------------ electron

say "fetching electron $ELECTRON_VERSION"
RUNTIME_DIR="$DIST_DIR/.runtime"
mkdir -p "$RUNTIME_DIR"
cat > "$RUNTIME_DIR/package.json" <<EOF
{ "name": "promethee-linux-runtime", "version": "1.0.0", "private": true,
  "dependencies": { "electron": "$ELECTRON_VERSION" } }
EOF
(
	cd "$RUNTIME_DIR"
	npm install --no-audit --no-fund --loglevel=error >/dev/null 2>&1 || true
	# electron's postinstall is what downloads the binary, and npm >= 11 defers
	# install scripts by default. Run it directly rather than fighting npm.
	[[ -x node_modules/electron/dist/electron ]] || node node_modules/electron/install.js
)
ELECTRON_BIN="$RUNTIME_DIR/node_modules/electron/dist/electron"
[[ -x "$ELECTRON_BIN" ]] || die "electron $ELECTRON_VERSION did not install"

# -------------------------------------------------------------------- assets

if [[ -f "$SOURCE_DIR/assets/icon.png" ]]; then
	cp "$SOURCE_DIR/assets/icon.png" "$DIST_DIR/promethee.png"
fi

# ------------------------------------------------------------------ launcher

cat > "$DIST_DIR/promethee" <<EOF
#!/usr/bin/env bash
# Generated by promethee-linux build.sh — Promethee $VERSION
exec "$ELECTRON_BIN" "$APP_DIR" "\$@"
EOF
chmod +x "$DIST_DIR/promethee"

say "built: $DIST_DIR/promethee"

# ------------------------------------------------------------------- install

if [[ "$DO_INSTALL" -eq 1 ]]; then
	APPS_DIR="$HOME/.local/share/applications"
	ICONS_DIR="$HOME/.local/share/icons/hicolor/512x512/apps"
	mkdir -p "$APPS_DIR" "$ICONS_DIR" "$HOME/.local/bin"

	[[ -f "$DIST_DIR/promethee.png" ]] && cp "$DIST_DIR/promethee.png" "$ICONS_DIR/promethee.png"
	ln -sf "$DIST_DIR/promethee" "$HOME/.local/bin/promethee"

	cat > "$APPS_DIR/promethee.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Promethee
Comment=Focus tracker and quest system
Exec=$DIST_DIR/promethee
Icon=promethee
Terminal=false
Categories=Utility;Office;
StartupWMClass=promethee
EOF
	update-desktop-database "$APPS_DIR" 2>/dev/null || true
	say "installed launcher (~/.local/bin/promethee + desktop entry)"
fi

# ----------------------------------------------------------------- warnings

command -v hyprctl >/dev/null || command -v swaymsg >/dev/null || command -v xdotool >/dev/null || \
	warn "no supported window backend found (hyprland / sway / xdotool) — activity tracking will stay idle"

say "done — run: $DIST_DIR/promethee"
