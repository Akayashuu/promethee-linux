import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick
import qs.modules.ii.bar as Bar

/**
 * Variant for the vertical bar. Forty pixels of width fit a glyph and one
 * number, so the timer keeps the width and the level is dropped: a running
 * clock is what the bar is for, the rest belongs in the dashboard.
 */
Item {
    id: root

    readonly property color accent: badge.accent

    implicitWidth: Appearance.sizes.verticalBarWidth
    implicitHeight: column.implicitHeight


    Column {
        id: column
        anchors.centerIn: parent
        spacing: 1

        // The hold has to look like it is doing something, or it reads as a
        // click that did not register. It only shrinks when there is a session
        // to end: a gesture that promises an action it will not perform is
        // worse than no feedback at all.
        scale: (mouseArea.pressed && Promethee.session) ? 0.82 : 1
        Behavior on scale {
            NumberAnimation {
                duration: mouseArea.pressed ? mouseArea.pressAndHoldInterval : 160
                easing.type: Easing.OutCubic
            }
        }

        Bar.PrometheeGlyph {
            id: badge
            anchors.horizontalCenter: parent.horizontalCenter
            size: Appearance.font.pixelSize.large + 8
        }

        // Minutes only: the second would not survive the width, and a vertical
        // bar is glanced at, not stared at.
        StyledText {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: Promethee.available
            textFormat: Text.PlainText
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: root.accent
            text: Promethee.formatCompact(Promethee.session ? Promethee.elapsed : Promethee.todaySeconds)
        }
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: !Config.options.bar.tooltips.clickToShow
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        // Long enough that a slow click never trips it, short enough that the
        // hold does not feel like waiting.
        pressAndHoldInterval: 550

        /// Set when the hold already acted, so the release does not act again.
        property bool consumed: false

        onPressed: consumed = false

        /**
         * A trackpad has no middle button, so ending also lives on a long
         * press. Both routes to it are gestures you cannot make by accident,
         * which is the point: it is the only action here that cannot be undone.
         */
        onPressAndHold: event => {
            if (event.button !== Qt.LeftButton || !Promethee.available || !Promethee.session)
                return;
            consumed = true;
            Promethee.stop();
        }

        onReleased: event => {
            if (consumed)
                return;
            // Nothing to drive until the app is up; any button starts it.
            if (!Promethee.available) {
                Promethee.activate();
                return;
            }
            if (event.button === Qt.LeftButton)
                Promethee.toggle();
            else if (event.button === Qt.MiddleButton)
                Promethee.stop();
            else
                Promethee.showDashboard();
        }

        Bar.PrometheeWidgetPopup {
            hoverTarget: mouseArea
        }
    }
}
