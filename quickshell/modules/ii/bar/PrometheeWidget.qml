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
 * Left click starts or ends the session, right click opens Promethee's own
 * dashboard. The popup is a tooltip and cannot take a click, so the actions
 * belong here.
 */
Item {
    id: root

    property color accent: {
        if (!Promethee.available)
            return Appearance.colors.colOnSurfaceVariant;
        if (Promethee.paused)
            return Appearance.colors.colOnSurfaceVariant;
        return Promethee.running ? Appearance.m3colors.m3primary : Appearance.colors.colOnLayer1;
    }

    readonly property string glyph: {
        if (!Promethee.available)
            return "bolt";
        if (Promethee.paused)
            return "pause_circle";
        return Promethee.running ? "local_fire_department" : "play_circle";
    }

    readonly property string value: {
        if (!Promethee.available)
            return Translation.tr("off");
        if (Promethee.session)
            return Promethee.formatDuration(Promethee.elapsed);
        return Promethee.formatShort(Promethee.todaySeconds);
    }

    implicitWidth: row.implicitWidth + 16
    implicitHeight: Appearance.sizes.barHeight

    Behavior on accent {
        animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
    }

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

        MaterialSymbol {
            id: glyphIcon
            Layout.alignment: Qt.AlignVCenter
            iconSize: Appearance.font.pixelSize.larger
            color: root.accent
            text: root.glyph

            // Slow breathing while the session runs: visible in peripheral
            // vision, quiet enough to work next to.
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
        acceptedButtons: Qt.LeftButton | Qt.RightButton

        onPressed: event => {
            if (event.button === Qt.LeftButton) {
                if (Promethee.available)
                    Promethee.toggle();
                else
                    Promethee.launch();
            } else {
                Promethee.activate();
            }
        }

        PrometheeWidgetPopup {
            hoverTarget: mouseArea
        }
    }
}
