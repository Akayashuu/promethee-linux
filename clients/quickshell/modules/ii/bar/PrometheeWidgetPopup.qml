import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets

LazyLoader {
    id: root

    property Item hoverTarget
    property ShellScreen barScreen
    readonly property int cardWidth: 300
    readonly property var topApps: Promethee.apps.slice(0, 3)
    readonly property var level: PrometheeStyle.levelProgress(Promethee.profile?.totalXp ?? 0)
    readonly property int focusShare: Promethee.trackedSeconds > 0
        ? Math.round(Promethee.todaySeconds / Promethee.trackedSeconds * 100)
        : 0

    active: root.hoverTarget !== null && root.hoverTarget.containsMouse

    readonly property string stateLabel: {
        if (!Promethee.available)
            return Translation.tr("Offline");
        if (Promethee.paused)
            return Translation.tr("Paused");
        return Promethee.session ? Translation.tr("In session") : Translation.tr("Not in session");
    }

    readonly property var facts: {
        const rows = [];
        if (Promethee.session) {
            rows.push({ icon: "wb_sunny", label: Translation.tr("Today"), value: PrometheeStyle.hoursMinutes(Promethee.todaySeconds) });
            rows.push({ icon: "stacks", label: Translation.tr("Sessions"), value: Translation.tr("%1 + 1 running").arg(Promethee.today?.sessions ?? 0) });
        } else {
            rows.push({ icon: "schedule", label: Translation.tr("Tracked"), value: PrometheeStyle.hoursMinutes(Promethee.trackedSeconds) });
        }
        if (Promethee.profile)
            rows.push({ icon: "local_fire_department", label: Translation.tr("Streak"), value: Translation.tr("%1 days").arg(Promethee.profile.streak ?? 0) });
        return rows;
    }

    component Label: StyledText {
        textFormat: Text.PlainText
        font.family: PrometheeStyle.family
        font.pixelSize: 13
        color: PrometheeStyle.fg
    }

    component Caps: Label {
        font.pixelSize: 11
        font.weight: Font.DemiBold
        font.letterSpacing: 0.6
        font.capitalization: Font.AllUppercase
        color: PrometheeStyle.muted
    }

    component Dot: Rectangle {
        implicitWidth: 3
        implicitHeight: 3
        radius: 1.5
        color: PrometheeStyle.faint
    }

    component: PanelWindow {
        id: popupWindow

        readonly property bool vertical: Config.options.bar.vertical
        readonly property point centered: root.hoverTarget?.mapToItem(null, (root.hoverTarget.width - card.implicitWidth) / 2, (root.hoverTarget.height - card.implicitHeight) / 2) ?? Qt.point(0, 0)

        function clamp(value, room) {
            return Math.max(0, Math.min(value, room));
        }

        screen: root.barScreen
        color: "transparent"
        anchors.left: !popupWindow.vertical || !Config.options.bar.bottom
        anchors.right: popupWindow.vertical && Config.options.bar.bottom
        anchors.top: popupWindow.vertical || !Config.options.bar.bottom
        anchors.bottom: !popupWindow.vertical && Config.options.bar.bottom
        implicitWidth: card.implicitWidth + Appearance.sizes.elevationMargin * 2
        implicitHeight: card.implicitHeight + Appearance.sizes.elevationMargin * 2
        exclusionMode: ExclusionMode.Ignore
        exclusiveZone: 0
        mask: Region {
            item: card
        }
        margins {
            left: popupWindow.vertical ? Appearance.sizes.verticalBarWidth : popupWindow.clamp(popupWindow.centered.x, (popupWindow.screen?.width ?? 0) - popupWindow.implicitWidth)
            right: Appearance.sizes.verticalBarWidth
            top: popupWindow.vertical ? popupWindow.clamp(popupWindow.centered.y, (popupWindow.screen?.height ?? 0) - popupWindow.implicitHeight) : Appearance.sizes.barHeight
            bottom: Appearance.sizes.barHeight
        }
        WlrLayershell.namespace: "quickshell:popup"
        WlrLayershell.layer: WlrLayer.Overlay

        StyledRectangularShadow {
            target: card
        }

        Rectangle {
            id: card
            anchors.fill: parent
            anchors.margins: Appearance.sizes.elevationMargin
            implicitWidth: root.cardWidth
            implicitHeight: content.implicitHeight
            radius: Appearance.rounding.small
            color: PrometheeStyle.card
            border.width: 1
            border.color: PrometheeStyle.line

            ColumnLayout {
                id: content
                anchors.fill: parent
                spacing: 0

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.margins: 14
                    Layout.bottomMargin: 12
                    spacing: 12

                    Rectangle {
                        implicitWidth: pill.implicitWidth + 20
                        implicitHeight: pill.implicitHeight + 10
                        radius: height / 2
                        color: PrometheeStyle.inset

                        Row {
                            id: pill
                            anchors.centerIn: parent
                            spacing: 7

                            Item {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 14
                                height: 14

                                Image {
                                    id: mark
                                    anchors.fill: parent
                                    source: "../../../assets/promethee-mark.png"
                                    sourceSize.width: 64
                                    sourceSize.height: 64
                                    smooth: true
                                    visible: false
                                }

                                MultiEffect {
                                    anchors.fill: mark
                                    source: mark
                                    visible: mark.status === Image.Ready
                                    colorization: 1
                                    colorizationColor: Promethee.running ? PrometheeStyle.fire : PrometheeStyle.muted
                                    brightness: 1
                                }

                                MaterialSymbol {
                                    anchors.centerIn: parent
                                    visible: mark.status !== Image.Ready
                                    fill: 1
                                    iconSize: 14
                                    color: Promethee.running ? PrometheeStyle.fire : PrometheeStyle.muted
                                    text: "local_fire_department"
                                }
                            }

                            Label {
                                anchors.verticalCenter: parent.verticalCenter
                                font.weight: Font.Medium
                                font.pixelSize: 13
                                color: Promethee.running ? PrometheeStyle.fg : PrometheeStyle.muted
                                text: root.stateLabel
                            }
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: Promethee.available
                        spacing: 3

                        Label {
                            font.pixelSize: 38
                            font.weight: Font.DemiBold
                            font.letterSpacing: -0.8
                            color: Promethee.paused ? PrometheeStyle.muted : PrometheeStyle.fg
                            text: Promethee.session
                                ? Promethee.formatDuration(Promethee.elapsed)
                                : PrometheeStyle.hoursMinutes(Promethee.todaySeconds)
                        }

                        Label {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            font.pixelSize: 14
                            font.weight: Font.Medium
                            text: {
                                if (!Promethee.session)
                                    return Translation.tr("of focus today");
                                const task = Promethee.session.task ?? "";
                                return task.length > 0 ? task : Translation.tr("Untitled session");
                            }
                        }

                        Row {
                            spacing: 6

                            MaterialSymbol {
                                anchors.verticalCenter: parent.verticalCenter
                                iconSize: 13
                                fill: 1
                                color: PrometheeStyle.fire
                                text: "schedule"
                            }

                            Label {
                                anchors.verticalCenter: parent.verticalCenter
                                font.pixelSize: 12
                                color: PrometheeStyle.fire
                                text: Promethee.session
                                    ? Translation.tr("since %1").arg(Qt.formatTime(new Date(Promethee.session.startedAt), "hh:mm"))
                                    : Translation.tr("%1 sessions").arg(Promethee.today?.sessions ?? 0)
                            }

                            Dot {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: secondary.text.length > 0
                            }

                            Label {
                                id: secondary
                                anchors.verticalCenter: parent.verticalCenter
                                font.pixelSize: 12
                                color: PrometheeStyle.muted
                                text: {
                                    if (Promethee.session) {
                                        const pausedMinutes = Math.floor((Promethee.session.pausedMs ?? 0) / 60000);
                                        return pausedMinutes > 0 ? Translation.tr("%1 min paused").arg(pausedMinutes) : "";
                                    }
                                    return Promethee.trackedSeconds > 0 ? Translation.tr("%1% of active time").arg(root.focusShare) : "";
                                }
                            }
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: Promethee.profile !== null
                        spacing: 6

                        Label {
                            font.pixelSize: 12
                            font.weight: Font.DemiBold
                            font.letterSpacing: 0.6
                            color: PrometheeStyle.fire
                            text: Translation.tr("LEVEL %1").arg(root.level.level)
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 3
                            radius: 1.5
                            color: PrometheeStyle.inset

                            Rectangle {
                                width: parent.width * root.level.ratio
                                height: parent.height
                                radius: parent.radius
                                color: PrometheeStyle.fire

                                Behavior on width {
                                    NumberAnimation { duration: 350; easing.type: Easing.OutCubic }
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true

                            Label {
                                Layout.fillWidth: true
                                font.pixelSize: 11
                                color: PrometheeStyle.faint
                                text: `${PrometheeStyle.grouped(root.level.into)} / ${PrometheeStyle.grouped(root.level.span)} XP`
                            }

                            Label {
                                font.pixelSize: 11
                                color: PrometheeStyle.faint
                                text: Translation.tr("~%1 MIN").arg(root.level.minutesLeft)
                            }
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: Promethee.available
                        spacing: 9

                        Repeater {
                            model: root.facts

                            RowLayout {
                                required property var modelData
                                Layout.fillWidth: true
                                spacing: 7

                                MaterialSymbol {
                                    iconSize: 13
                                    fill: 1
                                    color: PrometheeStyle.faint
                                    text: modelData.icon
                                }

                                Caps {
                                    Layout.fillWidth: true
                                    text: modelData.label
                                }

                                Caps {
                                    font.pixelSize: 12
                                    color: PrometheeStyle.fg
                                    text: modelData.value
                                }
                            }
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        visible: root.topApps.length > 0
                        implicitHeight: apps.implicitHeight + 20
                        radius: 10
                        color: PrometheeStyle.inset

                        ColumnLayout {
                            id: apps
                            anchors.fill: parent
                            anchors.margins: 10
                            anchors.leftMargin: 12
                            anchors.rightMargin: 12
                            spacing: 10

                            RowLayout {
                                Layout.fillWidth: true

                                Caps {
                                    Layout.fillWidth: true
                                    font.pixelSize: 10
                                    text: Translation.tr("Apps today")
                                }

                                Label {
                                    font.weight: Font.DemiBold
                                    text: PrometheeStyle.hoursMinutes(Promethee.trackedSeconds)
                                }
                            }

                            Row {
                                Layout.fillWidth: true
                                spacing: 2

                                Repeater {
                                    model: root.topApps

                                    Rectangle {
                                        required property var modelData
                                        required property int index
                                        readonly property real share: Promethee.trackedSeconds > 0 ? (modelData.seconds ?? 0) / Promethee.trackedSeconds : 0
                                        width: Math.max(2, (apps.width - 2 * (root.topApps.length - 1)) * share)
                                        height: 4
                                        radius: 1
                                        color: PrometheeStyle.appShades[index] ?? PrometheeStyle.faint
                                    }
                                }
                            }

                            Repeater {
                                model: root.topApps

                                RowLayout {
                                    id: appRow
                                    required property var modelData
                                    readonly property bool live: modelData.app === (Promethee.window?.app ?? "")
                                    readonly property string iconSource: Quickshell.iconPath(AppSearch.guessIcon(modelData.app ?? ""), true)
                                    Layout.fillWidth: true
                                    spacing: 10

                                    Item {
                                        implicitWidth: 26
                                        implicitHeight: 26

                                        IconImage {
                                            anchors.fill: parent
                                            visible: appRow.iconSource.length > 0
                                            source: appRow.iconSource
                                            implicitSize: 26
                                        }

                                        Rectangle {
                                            anchors.fill: parent
                                            visible: appRow.iconSource.length === 0
                                            radius: 7
                                            color: PrometheeStyle.band

                                            Label {
                                                anchors.centerIn: parent
                                                font.pixelSize: 12
                                                font.weight: Font.Bold
                                                text: (appRow.modelData.app ?? "?").slice(0, 1).toUpperCase()
                                            }
                                        }

                                        Rectangle {
                                            anchors.right: parent.right
                                            anchors.bottom: parent.bottom
                                            anchors.margins: -2
                                            visible: appRow.live
                                            width: 10
                                            height: 10
                                            radius: 5
                                            color: PrometheeStyle.online
                                            border.width: 2
                                            border.color: PrometheeStyle.inset
                                        }
                                    }

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 0

                                        Label {
                                            Layout.fillWidth: true
                                            elide: Text.ElideRight
                                            font.weight: Font.Medium
                                            text: appRow.modelData.app ?? ""
                                        }

                                        Label {
                                            Layout.fillWidth: true
                                            elide: Text.ElideRight
                                            font.pixelSize: 11
                                            color: appRow.live ? PrometheeStyle.online : PrometheeStyle.muted
                                            text: {
                                                const time = PrometheeStyle.hoursMinutes(appRow.modelData.seconds ?? 0);
                                                return appRow.live ? Translation.tr("in focus · %1").arg(time) : time;
                                            }
                                        }
                                    }

                                    Label {
                                        font.pixelSize: 12
                                        color: PrometheeStyle.muted
                                        text: Promethee.trackedSeconds > 0
                                            ? `${Math.round((appRow.modelData.seconds ?? 0) / Promethee.trackedSeconds * 100)} %`
                                            : ""
                                    }
                                }
                            }
                        }
                    }

                    Label {
                        Layout.fillWidth: true
                        visible: Promethee.available && Promethee.apps.length === 0
                        font.pixelSize: 12
                        color: PrometheeStyle.muted
                        text: Translation.tr("No app time tracked yet today")
                    }

                    Label {
                        Layout.fillWidth: true
                        visible: !Promethee.available
                        wrapMode: Text.WordWrap
                        font.pixelSize: 12
                        color: PrometheeStyle.muted
                        text: Translation.tr("Promethee is not running")
                    }

                    Label {
                        Layout.fillWidth: true
                        visible: Promethee.available && !Promethee.authenticated
                        wrapMode: Text.WordWrap
                        font.pixelSize: 12
                        color: Appearance.m3colors.m3error
                        text: Translation.tr("Not signed in. Open the dashboard to sign in")
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: footer.implicitHeight + 20
                    color: PrometheeStyle.band
                    bottomLeftRadius: card.radius
                    bottomRightRadius: card.radius

                    RowLayout {
                        id: footer
                        anchors.fill: parent
                        anchors.leftMargin: 14
                        anchors.rightMargin: 14
                        spacing: 10

                        Caps {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            font.pixelSize: 11
                            text: {
                                if (!Promethee.available)
                                    return Translation.tr("Click to launch");
                                if (!Promethee.session)
                                    return Translation.tr("Click to start");
                                return Promethee.paused
                                    ? Translation.tr("Click resume · Hold end")
                                    : Translation.tr("Click pause · Hold end");
                            }
                        }

                        Caps {
                            visible: Promethee.available
                            font.pixelSize: 11
                            text: Translation.tr("Dashboard →")
                        }
                    }
                }
            }
        }
    }
}
