import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Layouts

/**
 * Focus session in the horizontal bar.
 *
 * The bar shows the one number that matters at a glance: the running timer
 * while a session is open, the day's total otherwise. Everything else lives in
 * the popup, which has the room for it.
 *
 * Left click starts, pauses and resumes; a long press ends. Right click
 * opens Promethee's own dashboard. The popup is a tooltip, closing the
 * moment the pointer leaves the badge, so it cannot hold a button, and
 * every action has to be a gesture on the badge itself.
 */
Item {
    id: root

    readonly property color accent: badge.accent

    readonly property string value: {
        if (!Promethee.available)
            return Translation.tr("off");
        if (Promethee.session)
            return Promethee.formatDuration(Promethee.elapsed);
        return Promethee.formatShort(Promethee.todaySeconds);
    }

    implicitWidth: row.implicitWidth + 16
    implicitHeight: Appearance.sizes.barHeight


    // A running session tints the widget. That tint is the whole point of
    // putting this in the bar: knowing the clock is running without looking.
    Rectangle {
        anchors.fill: parent
        anchors.topMargin: 3
        anchors.bottomMargin: 3
        radius: Appearance.rounding.small
        color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, Promethee.running ? 0.14 : 0.06)

        Behavior on color {
            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
        }
    }

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: 5

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

        PrometheeGlyph {
            id: badge
            Layout.alignment: Qt.AlignVCenter
            size: Appearance.font.pixelSize.larger + 6
        }

        StyledText {
            Layout.alignment: Qt.AlignVCenter
            textFormat: Text.PlainText
            font.pixelSize: Appearance.font.pixelSize.small
            font.weight: Promethee.running ? Font.DemiBold : Font.Normal
            color: root.accent
            opacity: Promethee.available ? 1 : 0.6
            text: root.value
        }

        // The level only appears once the app has reported a profile; before
        // sign-in there is nothing truthful to put here.
        StyledText {
            Layout.alignment: Qt.AlignVCenter
            visible: Promethee.profile !== null
            textFormat: Text.PlainText
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colOnSurfaceVariant
            text: Translation.tr("lv %1").arg(Promethee.profile?.level ?? 0)
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

        PrometheeWidgetPopup {
            hoverTarget: mouseArea
        }
    }
}
