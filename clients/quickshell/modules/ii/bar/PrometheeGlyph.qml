import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Effects
import QtQuick.Shapes

/**
 * The badge, shared by both bars.
 *
 * The mark is drawn on its own, tinted with the state colour — no filled disc
 * behind it. A disc turns a logo into a sticker: it fights the mark's own
 * silhouette and reads as a second, meaningless shape at bar size. The bar's
 * other icons are bare glyphs; this one is too.
 *
 * The ring around it sweeps the current minute. It is not information anyone
 * needs to the second — it is the proof the clock is running, which a static
 * timer cannot give.
 */
Item {
    id: root

    property real size: 22

    property color accent: {
        if (!Promethee.available)
            return Appearance.colors.colOnSurfaceVariant;
        if (Promethee.paused)
            return Appearance.m3colors.m3tertiary;
        return Promethee.running ? Appearance.m3colors.m3primary : Appearance.colors.colOnLayer1;
    }

    readonly property string glyph: {
        if (!Promethee.available)
            return "bolt";
        if (Promethee.paused)
            return "pause";
        return Promethee.running ? "local_fire_department" : "play_arrow";
    }

    /// Off, the mark recedes; running, it carries the bar.
    readonly property real markOpacity: {
        if (!Promethee.available)
            return 0.55;
        return Promethee.running ? 1 : 0.85;
    }

    implicitWidth: root.size
    implicitHeight: root.size

    Behavior on accent {
        animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
    }

    // A faint halo only while a session runs: it separates the mark from the
    // ring without becoming a shape of its own.
    Rectangle {
        anchors.centerIn: parent
        width: root.size
        height: width
        radius: width / 2
        color: root.accent
        opacity: Promethee.running ? 0.14 : 0
        Behavior on opacity {
            NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
        }
    }

    // Promethee's own mark, derived from the installed icon by install.sh.
    // The logo is not redistributable, so the file is absent until then —
    // hence the Material fallback below rather than a hard dependency.
    Image {
        id: mark
        anchors.centerIn: parent
        source: "../../../assets/promethee-mark.png"
        sourceSize.width: 128
        sourceSize.height: 128
        // Room for the ring to sit outside the mark without touching it.
        width: root.size - 7
        height: width
        smooth: true
        visible: false
    }

    MultiEffect {
        anchors.fill: mark
        source: mark
        visible: mark.status === Image.Ready
        opacity: root.markOpacity
        colorization: 1
        colorizationColor: root.accent
        brightness: 1

        Behavior on opacity {
            NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
        }
    }

    MaterialSymbol {
        anchors.centerIn: parent
        visible: mark.status !== Image.Ready
        fill: 1
        iconSize: root.size - 6
        opacity: root.markOpacity
        color: root.accent
        text: root.glyph
    }

    // One sweep per minute, drawn from the session's own elapsed seconds rather
    // than from a local animation, so it cannot drift away from the timer.
    Shape {
        anchors.fill: parent
        visible: Promethee.running
        asynchronous: true
        preferredRendererType: Shape.CurveRenderer

        // The track the sweep runs on: without it the arc floats, and a
        // quarter-full ring is unreadable as a fraction of anything.
        ShapePath {
            strokeColor: Qt.alpha(root.accent, 0.22)
            strokeWidth: 2
            fillColor: "transparent"

            PathAngleArc {
                centerX: root.size / 2
                centerY: root.size / 2
                radiusX: (root.size - 1.5) / 2
                radiusY: (root.size - 1.5) / 2
                startAngle: -90
                sweepAngle: 360
            }
        }

        ShapePath {
            strokeColor: root.accent
            strokeWidth: 2
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap

            PathAngleArc {
                centerX: root.size / 2
                centerY: root.size / 2
                radiusX: (root.size - 1.5) / 2
                radiusY: (root.size - 1.5) / 2
                startAngle: -90
                sweepAngle: (Promethee.elapsed % 60) / 60 * 360

                Behavior on sweepAngle {
                    // A wrap from 354° back to 0° must not run backwards
                    // through the whole circle.
                    enabled: !root.wrapping
                    NumberAnimation { duration: 400; easing.type: Easing.OutCubic }
                }
            }
        }
    }

    readonly property bool wrapping: Promethee.elapsed % 60 < 2
}
