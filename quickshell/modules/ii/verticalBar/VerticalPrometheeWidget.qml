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
        acceptedButtons: Qt.LeftButton | Qt.RightButton

        onPressed: event => {
            if (event.button === Qt.LeftButton && Promethee.available)
                Promethee.toggle();
            else
                Promethee.activate();
        }

        Bar.PrometheeWidgetPopup {
            hoverTarget: mouseArea
        }
    }
}
