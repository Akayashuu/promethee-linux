#!/usr/bin/env bash
#
# Reports a newer Promethee release to the desktop.
#
# Run from the systemd user timer that `build.sh --install` sets up.
# `build.sh --check` is the same comparison without the notification.
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --check exits 0 when the build matches the channel, 1 when a newer release is
# out, and 2 when it could not reach the channel at all. Only the middle case is
# worth interrupting someone over — a laptop that was asleep, or offline, is not
# news.
status=0
report="$("$REPO_DIR/build.sh" --check)" || status=$?

case "$status" in
	0) exit 0 ;;
	1) ;;
	*) printf '%s\n' "$report" >&2; exit 0 ;;
esac

if command -v notify-send >/dev/null; then
	notify-send --app-name=Promethee --icon=promethee \
		"$report" "Rebuild with $REPO_DIR/build.sh"
else
	printf '%s\nRebuild with %s/build.sh\n' "$report" "$REPO_DIR"
fi
