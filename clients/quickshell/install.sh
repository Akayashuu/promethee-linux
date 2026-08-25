#!/usr/bin/env bash
# Installs the Promethee Quickshell integration into a dots-hyprland ("ii")
# configuration.
#
# The widget files are copied as they are. The three upstream files
# (Config.qml, BarContent.qml, VerticalBarContent.qml) receive an idempotent
# addition: the script detects its own marker and applies it only once. A
# dots-hyprland update overwrites them: run this script again afterwards.
set -euo pipefail

QS_DIR="${QS_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/quickshell/ii}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARK="// promethee"

die() { printf '%s\n' "$*" >&2; exit 1; }

[ -d "$QS_DIR" ] || die "Quickshell configuration not found: $QS_DIR"
[ -f "$QS_DIR/modules/common/Config.qml" ] || die "$QS_DIR does not look like a dots-hyprland \"ii\" configuration."

backup() { cp -n "$1" "$1.bak-promethee" 2>/dev/null || true; }

install -Dm644 "$SRC/services/Promethee.qml" "$QS_DIR/services/Promethee.qml"
install -Dm644 "$SRC/modules/ii/bar/PrometheeGlyph.qml" "$QS_DIR/modules/ii/bar/PrometheeGlyph.qml"
install -Dm644 "$SRC/modules/ii/bar/PrometheeHistogram.qml" "$QS_DIR/modules/ii/bar/PrometheeHistogram.qml"
install -Dm644 "$SRC/modules/ii/bar/PrometheeWidget.qml" "$QS_DIR/modules/ii/bar/PrometheeWidget.qml"
install -Dm644 "$SRC/modules/ii/bar/PrometheeWidgetPopup.qml" "$QS_DIR/modules/ii/bar/PrometheeWidgetPopup.qml"
install -Dm644 "$SRC/modules/ii/verticalBar/VerticalPrometheeWidget.qml" "$QS_DIR/modules/ii/verticalBar/VerticalPrometheeWidget.qml"
echo "Widgets installed."

# The badge wears Promethee's own logo rather than a generic glyph. That logo is
# not redistributable, so it is never shipped here: it is derived from whatever
# is already installed on this machine, into the Quickshell config directory.
#
# The source is a white mark on an opaque black square, and what the widget
# needs is the mark alone: luminance becomes the alpha channel and the colour is
# discarded, so the widget can tint it to match the bar. Without an installed
# icon, or without Pillow, the widget falls back to a Material glyph.
ICON_SRC=""
for candidate in \
    "$HOME/.local/share/icons/hicolor/512x512/apps/promethee.png" \
    "$SRC/../../dist/promethee.png"
do
    [ -f "$candidate" ] && { ICON_SRC="$candidate"; break; }
done

if [ -n "$ICON_SRC" ] && python3 -c "import PIL" 2>/dev/null; then
    ICON_SRC="$ICON_SRC" OUT="$QS_DIR/assets/promethee-mark.png" python3 - <<'MARK'
import os
from PIL import Image

source, out = os.environ["ICON_SRC"], os.environ["OUT"]
os.makedirs(os.path.dirname(out), exist_ok=True)
image = Image.open(source).convert("RGBA")
# Trim the padding the icon ships with, so the mark fills the badge instead of
# floating in the middle of it.
box = image.getbbox()
if box:
    image = image.crop(box)
mark = Image.new("RGBA", image.size, (255, 255, 255, 255))
mark.putalpha(image.convert("L"))
mark.resize((128, 128), Image.LANCZOS).save(out)
MARK
    echo "Logo derived: assets/promethee-mark.png"
else
    echo "Logo not derived (no installed icon, or Pillow missing) - using a Material glyph."
fi

patch_file() {
    local file="$1" anchor="$2" addition="$3"
    [ -f "$file" ] || die "Missing file: $file"
    if grep -qF "$MARK" "$file"; then
        echo "Already wired: ${file#"$QS_DIR"/}"
        return
    fi
    grep -qF "$anchor" "$file" || die "Anchor point not found in ${file#"$QS_DIR"/}; wire it by hand (see quickshell/README.md)."
    backup "$file"
    ANCHOR="$anchor" ADDITION="$addition" python3 - "$file" <<'PY'
import os, sys
path = sys.argv[1]
anchor, addition = os.environ["ANCHOR"], os.environ["ADDITION"]
with open(path, encoding="utf-8") as handle:
    text = handle.read()
# A single occurrence: the anchor is picked to be unique in each upstream file.
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text.replace(anchor, anchor + addition, 1))
PY
    echo "Wired: ${file#"$QS_DIR"/}"
}

# This option is declared BEFORE its anchor: a unique case, handled apart.
if ! grep -qF "$MARK" "$QS_DIR/modules/common/Config.qml"; then
    backup "$QS_DIR/modules/common/Config.qml"
    python3 - "$QS_DIR/modules/common/Config.qml" <<'PY'
import sys
path = sys.argv[1]
anchor = "                property JsonObject indicators: JsonObject {"
addition = """                property JsonObject promethee: JsonObject { // promethee
                    property bool enable: true
                    property string socket: "" // Empty: $XDG_RUNTIME_DIR/promethee/control.sock
                    property string binary: "" // Empty: ~/.local/bin/promethee
                }
"""
with open(path, encoding="utf-8") as handle:
    text = handle.read()
if anchor not in text:
    sys.exit("Anchor point not found in Config.qml")
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text.replace(anchor, addition + anchor, 1))
PY
    echo "Wired: modules/common/Config.qml"
fi

patch_file "$QS_DIR/modules/ii/bar/BarContent.qml" \
'                sourceComponent: BarGroup {
                    WeatherBar {}
                }
            }' \
'

            // Focus session
            Loader { // promethee
                Layout.leftMargin: 4
                active: Config.options.bar.promethee?.enable ?? true

                sourceComponent: BarGroup {
                    PrometheeWidget {
                        Layout.alignment: Qt.AlignVCenter
                    }
                }
            }'

patch_file "$QS_DIR/modules/ii/verticalBar/VerticalBarContent.qml" \
'            BatteryIndicator {
                visible: Battery.available
                Layout.fillWidth: true
                Layout.fillHeight: false
            }' \
'

            HorizontalBarSeparator {
                visible: prometheeLoader.active
            }

            // Focus session
            Loader { // promethee
                id: prometheeLoader
                active: Config.options.bar.promethee?.enable ?? true
                Layout.fillWidth: true
                Layout.fillHeight: false
                sourceComponent: VerticalPrometheeWidget {}
            }'

echo
echo "Done. Restart Quickshell to load the widget:"
echo "    qs -c ii kill && qs -c ii -d"
