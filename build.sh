#!/usr/bin/env bash
#
# promethee-linux — build a native Linux Promethee.
#
# Fetches the official Windows build from Promethee's own release channel,
# patches it for Linux, and writes a runnable app to ./dist. No Promethee
# code is redistributed by this repository.
#
#   ./build.sh                             # download, patch, build
#   ./build.sh --install                   # also install a launcher and a
#                                          # daily check for new releases
#   ./build.sh --check                     # is a newer release out?
#   ./build.sh --source /path/to/resources # build from a local copy instead
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="$REPO_DIR/dist"
APP_DIR="$DIST_DIR/app"
CACHE_DIR="$REPO_DIR/.source"
SOURCE_DIR=""
DO_INSTALL=0
DO_CHECK=0

# Where promethee.io points its own Windows download button.
RELEASE_URL="https://github.com/promethee-io/Promethee-releases/releases/download/win-stable"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- arguments

# The header above is the help text; print it down to the first line of code so
# the two cannot drift apart.
usage() { awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"; }

while [[ $# -gt 0 ]]; do
	case "$1" in
		--source)  SOURCE_DIR="${2:-}"; shift 2 ;;
		--install) DO_INSTALL=1; shift ;;
		--check)   DO_CHECK=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown argument: $1" ;;
	esac
done

# ------------------------------------------------------------ prerequisites

for cmd in node npm python3 curl; do
	command -v "$cmd" >/dev/null || die "$cmd is required but not installed"
done

NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[[ "$NODE_MAJOR" -ge 20 ]] || die "node >= 20 required (found $(node -v))"

# ------------------------------------------------------- the release channel

CHANNEL_SHA=""
CHANNEL_PKG=""
CHANNEL_BYTES=""
CHANNEL_VERSION=""

# Squirrel's RELEASES file is the channel's index: one line, "<sha1> <package>
# <bytes>", naming the build currently being served. Reading it is what keeps
# this correct across upstream releases without a version pinned in the repo.
#
# Returns non-zero rather than dying, so --check can report an unreachable
# channel as its own outcome instead of as a build failure.
read_channel() {
	mkdir -p "$CACHE_DIR"
	curl -fsSL "$RELEASE_URL/RELEASES" -o "$CACHE_DIR/RELEASES" || return 1

	# Read via a here-string: the file ends without a newline, and `read` off a
	# pipe would report EOF as failure even having assigned every field. The
	# leading BOM has to go before the first field is usable.
	local entry
	entry="$(tr -d '\r\357\273\277' < "$CACHE_DIR/RELEASES" | head -1)"
	read -r CHANNEL_SHA CHANNEL_PKG CHANNEL_BYTES <<< "$entry"
	[[ "$CHANNEL_PKG" == *.nupkg && -n "$CHANNEL_BYTES" ]] || return 1

	# Promethee-1.3.26-full.nupkg -> 1.3.26
	CHANNEL_VERSION="${CHANNEL_PKG#Promethee-}"
	CHANNEL_VERSION="${CHANNEL_VERSION%-full.nupkg}"
}

# The version the last build produced, or nothing if there is no build here.
built_version() {
	[[ -f "$APP_DIR/package.json" ]] || return 1
	node -p "require('$APP_DIR/package.json').version" 2>/dev/null
}

# ------------------------------------------------------------- update check

# The app's own updater is switched off and there is no channel for it to watch,
# so nothing would otherwise announce a new release. Exit status is the whole
# interface here: 0 current, 1 a newer release is out, 2 the check failed.
if [[ "$DO_CHECK" -eq 1 ]]; then
	read_channel || { echo "cannot reach the release channel"; exit 2; }

	BUILT="$(built_version || true)"
	if [[ -z "$BUILT" ]]; then
		echo "nothing built yet; the channel has $CHANNEL_VERSION"
		exit 1
	fi
	if [[ "$BUILT" == "$CHANNEL_VERSION" ]]; then
		echo "up to date ($BUILT)"
		exit 0
	fi
	echo "Promethee $CHANNEL_VERSION is out (this build is $BUILT)"
	exit 1
fi

# --------------------------------------------------------- fetch the source

# What the build needs is the directory holding app.asar — Promethee's
# resources/. The release ships it inside a Squirrel .nupkg, which is a plain
# zip, so the whole thing comes down over HTTP and opens with no help.
#
# Sets SOURCE_DIR rather than echoing it: progress output would otherwise have
# to be kept off stdout for a command substitution to work.
fetch_source() {
	read_channel || die "cannot reach Promethee's release channel — check your connection"

	local archive="$CACHE_DIR/$CHANNEL_PKG"
	local stamp="$CACHE_DIR/.extracted"

	# An extraction that already matches this package is the whole job done.
	SOURCE_DIR="$CACHE_DIR/resources"
	if [[ -f "$SOURCE_DIR/app.asar" && "$(cat "$stamp" 2>/dev/null)" == "$CHANNEL_PKG" ]]; then
		say "source: $CHANNEL_PKG (cached)"
		return
	fi

	if [[ ! -f "$archive" || "$(stat -c%s "$archive")" != "$CHANNEL_BYTES" ]]; then
		say "downloading $CHANNEL_PKG ($((CHANNEL_BYTES / 1024 / 1024)) MiB)"
		# -C - resumes a partial file, so an interrupted build doesn't start over.
		curl -fL --progress-bar -C - "$RELEASE_URL/$CHANNEL_PKG" -o "$archive" \
			|| die "download failed — re-run to resume from where it stopped"
	fi

	say "verifying"
	local want got
	want="$(printf '%s' "$CHANNEL_SHA" | tr '[:upper:]' '[:lower:]')"
	got="$(sha1sum "$archive" | cut -d' ' -f1)"
	[[ "$want" == "$got" ]] || die "checksum mismatch on $CHANNEL_PKG — delete $CACHE_DIR and retry"

	say "extracting resources"
	rm -f "$stamp"
	rm -rf "${SOURCE_DIR:?}"
	python3 "$REPO_DIR/scripts/extract-resources.py" "$archive" "$SOURCE_DIR" \
		|| die "extraction failed"
	echo "$CHANNEL_PKG" > "$stamp"

	# The rest of the archive is Windows binaries we have no further use for;
	# resources/ is what a rebuild reads.
	rm -f "$archive"
}

if [[ -n "$SOURCE_DIR" ]]; then
	say "source: $SOURCE_DIR"
else
	fetch_source
fi

[[ -f "$SOURCE_DIR/app.asar" ]] || die "no app.asar in $SOURCE_DIR"

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

# better-sqlite3 and keytar ship as win32 .node files and have to be rebuilt
# against this Electron's ABI. win-vdesktop and get-windows are left alone —
# the bundle already guards both behind a platform check.

say "rebuilding native modules"
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

# ------------------------------------------------------------------ patches

say "applying linux patches"
node "$REPO_DIR/scripts/apply-patches.mjs" "$APP_DIR"

# ----------------------------------------------------------------- electron

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

# ---------------------------------------------------------- packaged layout

# Upstream branches on app.isPackaged in two places that matter: it resolves the
# tray icon from <resourcesPath>/assets, and it picks the userData directory
# ("Promethee" when packaged, "Promethee Dev" otherwise). Running
# `electron <dir>` leaves isPackaged false, so the tray falls back to
# nativeImage.createEmpty() — and since the app creates no window at startup,
# an invisible tray means no way at all to open it.
#
# Electron sets isPackaged from whether an app path was passed on the command
# line, so lay the build out the way a packaged app is: the app under
# resources/app, next to a renamed binary that is launched with no arguments.
ELECTRON_DIST="$(dirname "$ELECTRON_BIN")"
APP_BIN="$ELECTRON_DIST/promethee"
ln -sfn "$APP_DIR" "$ELECTRON_DIST/resources/app"

# Copy beside the target and rename over it. Writing to the path directly fails
# with ETXTBSY when a build runs while the last one is still open; a rename
# only swaps the directory entry, and the running process keeps the inode it
# already mapped.
cp "$ELECTRON_BIN" "$APP_BIN.new"
mv -f "$APP_BIN.new" "$APP_BIN"

# ------------------------------------------------------------------- assets

mkdir -p "$ELECTRON_DIST/resources/assets"
if [[ -d "$SOURCE_DIR/assets" ]]; then
	cp -r "$SOURCE_DIR/assets/." "$ELECTRON_DIST/resources/assets/"
fi
if [[ -f "$SOURCE_DIR/assets/icon.png" ]]; then
	cp "$SOURCE_DIR/assets/icon.png" "$DIST_DIR/promethee.png"
fi
# The tray reads assets/tray-icon.png specifically; fall back to the app icon so
# the tray is never empty (an empty tray icon is an unopenable app).
if [[ ! -f "$ELECTRON_DIST/resources/assets/tray-icon.png" && -f "$DIST_DIR/promethee.png" ]]; then
	cp "$DIST_DIR/promethee.png" "$ELECTRON_DIST/resources/assets/tray-icon.png"
fi

# ----------------------------------------------------------------- launcher

cat > "$DIST_DIR/promethee" <<EOF
#!/usr/bin/env bash
# Generated by promethee-linux build.sh — Promethee $VERSION
exec "$APP_BIN" "\$@"
EOF
chmod +x "$DIST_DIR/promethee"

say "built: $DIST_DIR/promethee"

# ------------------------------------------------------------------ install

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

	# Upstream releases land without warning, and this build has no way to hear
	# about them: the app's updater is off and its Windows channel would not
	# apply anyway. A daily check is the whole mechanism.
	if systemctl --user show-environment >/dev/null 2>&1; then
		UNITS_DIR="$HOME/.config/systemd/user"
		mkdir -p "$UNITS_DIR"

		cat > "$UNITS_DIR/promethee-update-check.service" <<EOF
[Unit]
Description=Check whether Promethee has a newer release
After=network-online.target

[Service]
Type=oneshot
ExecStart=$REPO_DIR/scripts/update-check.sh
EOF

		# Persistent so a machine that was off still checks once it comes back,
		# and randomised so every install does not hit the channel on the hour.
		cat > "$UNITS_DIR/promethee-update-check.timer" <<EOF
[Unit]
Description=Daily check for a newer Promethee release

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
EOF

		systemctl --user daemon-reload
		if systemctl --user enable --now promethee-update-check.timer >/dev/null 2>&1; then
			say "installed daily update check (systemctl --user list-timers)"
		else
			warn "could not enable promethee-update-check.timer"
		fi
	else
		warn "no systemd user session — skipping the update check timer"
	fi
fi

# ----------------------------------------------------------------- warnings

command -v hyprctl >/dev/null || command -v swaymsg >/dev/null || command -v xdotool >/dev/null || \
	warn "no supported window backend found (hyprland / sway / xdotool) — activity tracking will stay idle"

say "done — run: $DIST_DIR/promethee"
