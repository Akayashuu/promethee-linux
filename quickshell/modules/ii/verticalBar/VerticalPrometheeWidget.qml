import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick

/**
 * Variant for the vertical bar. Forty pixels of width fit a glyph and one
 * number, so the timer keeps the width and the level is dropped: a running
 * clock is what the bar is for, the rest belongs in the dashboard.
 */
Item {
    id: root

    property color accent: Promethee.running && Promethee.available
        ? Appearance.m3colors.m3primary
        : Appearance.colors.colOnSurfaceVariant

    implicitWidth: Appearance.sizes.verticalBarWidth
    implicitHeight: column.implicitHeight

    Behavior on accent {
        animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
    }

    Column {
        id: column
        anchors.centerIn: parent
        spacing: 1

        MaterialSymbol {
            id: glyphIcon
            anchors.horizontalCenter: parent.horizontalCenter
            iconSize: Appearance.font.pixelSize.large
            color: root.accent
            text: {
                if (!Promethee.available)
                    return "bolt";
                if (Promethee.paused)
                    return "pause_circle";
                return Promethee.running ? "local_fire_department" : "play_circle";
            }

            SequentialAnimation on opacity {
                running: Promethee.running
                loops: Animation.Infinite
                NumberAnimation { to: 0.55; duration: 1400; easing.type: Easing.InOutSine }
                NumberAnimation { to: 1; duration: 1400; easing.type: Easing.InOutSine }
            }

            // The animation leaves opacity wherever it stopped; a session that
            // ends must not leave the glyph half faded.
            Connections {
                target: Promethee
                function onRunningChanged() {
                    if (!Promethee.running)
                        glyphIcon.opacity = 1;
                }
            }
        }

        // Minutes only: the second would not survive the width, and a vertical
        // bar is glanced at, not stared at.
        StyledText {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: Promethee.available
            textFormat: Text.PlainText
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: root.accent
            text: Math.floor((Promethee.session ? Promethee.elapsed : Promethee.todaySeconds) / 60)
        }
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton

        onPressed: event => {
            if (event.button === Qt.LeftButton && Promethee.available)
                Promethee.toggle();
            else
                Promethee.activate();
        }
    }
}
