import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Layouts

/**
 * The day, read the way the crypto popup reads the market: the number that
 * matters in large type, then one table, one row per thing.
 *
 * The rows are the apps the tracker attributed time to today. That is the
 * honest answer to "where did the day go", and it is the one thing the bar
 * itself has no room for.
 */
StyledPopup {
    id: root

    // Fixed widths keep the columns aligned from row to row without a
    // GridLayout, whose Repeater delegate would be flattened.
    readonly property int barWidth: 44
    readonly property int nameWidth: 132
    readonly property int timeWidth: 66
    readonly property int shareWidth: 52
    readonly property int fullWidth: barWidth + nameWidth + timeWidth + shareWidth + 24

    readonly property color accent: {
        if (!Promethee.available)
            return Appearance.colors.colOnSurfaceVariant;
        if (Promethee.paused)
            return Appearance.m3colors.m3tertiary;
        return Promethee.running ? Appearance.m3colors.m3primary : Appearance.colors.colOnLayer1;
    }

    /// Seconds of the busiest app today, for the proportion bars.
    readonly property int busiest: {
        let peak = 0;
        for (const entry of Promethee.apps)
            peak = Math.max(peak, entry.seconds ?? 0);
        return Math.max(1, peak);
    }

    ColumnLayout {
        anchors.centerIn: parent
        spacing: 8

        StyledPopupHeaderRow {
            icon: Promethee.available ? (Promethee.session ? "local_fire_department" : "hourglass_empty") : "cloud_off"
            label: Translation.tr("Promethee")
        }

        // The headline: the running timer, or the day's total when idle. It
        // leads, because it is the one number the widget exists to show; the
        // table below is the breakdown of it.
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredWidth: root.fullWidth
            spacing: 10

            ColumnLayout {
                spacing: 0

                StyledText {
                    textFormat: Text.PlainText
                    font.pixelSize: Appearance.font.pixelSize.huge
                    font.weight: Font.DemiBold
                    color: root.accent
                    text: Promethee.session
                        ? Promethee.formatDuration(Promethee.elapsed)
                        : Promethee.formatShort(Promethee.todaySeconds)
                }

                StyledText {
                    Layout.maximumWidth: root.nameWidth + root.timeWidth
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colOnSurfaceVariant
                    text: {
                        const task = Promethee.session?.task ?? "";
                        if (task.length > 0)
                            return task;
                        if (!Promethee.available)
                            return Translation.tr("not running");
                        return Translation.tr("%1 session(s) today").arg(Promethee.today?.sessions ?? 0);
                    }
                }
            }

            Item { Layout.fillWidth: true }

            // The state, as a pill rather than another line of grey text: it is
            // the only part of the popup that changes on its own.
            Rectangle {
                Layout.alignment: Qt.AlignTop
                implicitWidth: stateLabel.implicitWidth + 16
                implicitHeight: stateLabel.implicitHeight + 8
                radius: height / 2
                color: Qt.alpha(root.accent, 0.15)

                StyledText {
                    id: stateLabel
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    font.weight: Font.DemiBold
                    color: root.accent
                    text: {
                        if (!Promethee.available)
                            return Translation.tr("offline");
                        if (Promethee.paused)
                            return Translation.tr("paused");
                        return Promethee.running ? Translation.tr("focusing") : Translation.tr("idle");
                    }
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 1
            color: Appearance.colors.colLayer0Border
        }

        // The week, as seven daily bars, and today's tracked total: the two
        // scales every row below is read against.
        Row {
            Layout.fillWidth: true
            visible: Promethee.history.length > 0
            spacing: 8

            PrometheeHistogram {
                anchors.verticalCenter: parent.verticalCenter
                width: root.barWidth
                height: 18
                series: Promethee.historyMinutes
                stroke: root.accent
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                width: root.nameWidth
                textFormat: Text.PlainText
                font.pixelSize: Appearance.font.pixelSize.smaller
                font.weight: Font.DemiBold
                color: Appearance.colors.colOnLayer1
                text: Translation.tr("Last 7 days")
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                width: root.timeWidth
                horizontalAlignment: Text.AlignRight
                textFormat: Text.PlainText
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colOnLayer1
                text: Promethee.formatShort(Promethee.weekSeconds)
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                width: root.shareWidth
                horizontalAlignment: Text.AlignRight
                textFormat: Text.PlainText
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colOnSurfaceVariant
                text: Translation.tr("%1/day").arg(Promethee.formatCompact(Promethee.weekSeconds / 7))
            }
        }

        Rectangle {
            Layout.fillWidth: true
            visible: Promethee.apps.length > 0
            implicitHeight: 1
            color: Appearance.colors.colLayer0Border
        }

        // The table's own caption. Without it the app rows read as a continuation
        // of the week row, which is a different unit entirely.
        Row {
            Layout.fillWidth: true
            visible: Promethee.apps.length > 0
            spacing: 8

            StyledText {
                width: root.barWidth + root.nameWidth + 8
                textFormat: Text.PlainText
                font.pixelSize: Appearance.font.pixelSize.smallest
                font.weight: Font.DemiBold
                color: Appearance.colors.colOnSurfaceVariant
                text: Translation.tr("TODAY BY APP")
            }

            StyledText {
                width: root.timeWidth
                horizontalAlignment: Text.AlignRight
                textFormat: Text.PlainText
                font.pixelSize: Appearance.font.pixelSize.smallest
                color: Appearance.colors.colOnSurfaceVariant
                text: Promethee.formatShort(Promethee.trackedSeconds)
            }

            StyledText {
                width: root.shareWidth
                horizontalAlignment: Text.AlignRight
                textFormat: Text.PlainText
                font.pixelSize: Appearance.font.pixelSize.smallest
                color: Appearance.colors.colOnSurfaceVariant
                text: Translation.tr("share")
            }
        }

        // One row per app, busiest first.
        Column {
            Layout.fillWidth: true
            visible: Promethee.apps.length > 0
            spacing: 4

            Repeater {
                model: Promethee.apps

                Row {
                    required property var modelData
                    /// The app the tracker is attributing time to right now.
                    readonly property bool live: modelData.app === (Promethee.window?.app ?? "")
                    spacing: 8

                    // Proportion bar, in place of the coin logo: it says at a
                    // glance which app ate the day.
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: root.barWidth
                        height: 6
                        radius: height / 2
                        color: Qt.alpha(Appearance.colors.colOnSurfaceVariant, 0.15)

                        Rectangle {
                            width: parent.width * Math.min(1, (modelData.seconds ?? 0) / root.busiest)
                            height: parent.height
                            radius: parent.radius
                            color: root.accent
                            opacity: live ? 1 : 0.6

                            Behavior on width {
                                NumberAnimation { duration: 350; easing.type: Easing.OutCubic }
                            }
                        }
                    }

                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        width: root.nameWidth
                        spacing: 5

                        // A live dot beats bolding alone: the row is growing as
                        // you look at it, and nothing else on screen says so.
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: live
                            width: 5
                            height: 5
                            radius: 2.5
                            color: root.accent

                            SequentialAnimation on opacity {
                                running: live
                                loops: Animation.Infinite
                                NumberAnimation { to: 0.3; duration: 900; easing.type: Easing.InOutQuad }
                                NumberAnimation { to: 1; duration: 900; easing.type: Easing.InOutQuad }
                            }
                        }

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            width: root.nameWidth - (live ? 10 : 0)
                            elide: Text.ElideRight
                            textFormat: Text.PlainText
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            font.weight: live ? Font.DemiBold : Font.Normal
                            color: live ? Appearance.colors.colOnLayer1 : Appearance.colors.colOnSurfaceVariant
                            text: modelData.app ?? ""
                        }
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        width: root.timeWidth
                        horizontalAlignment: Text.AlignRight
                        textFormat: Text.PlainText
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colOnLayer1
                        text: Promethee.formatShort(modelData.seconds ?? 0)
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        width: root.shareWidth
                        horizontalAlignment: Text.AlignRight
                        textFormat: Text.PlainText
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colOnSurfaceVariant
                        text: Promethee.trackedSeconds > 0
                            ? `${Math.round((modelData.seconds ?? 0) / Promethee.trackedSeconds * 100)} %`
                            : ""
                    }
                }
            }
        }

        // Nothing tracked yet is a state, not an empty table.
        StyledText {
            Layout.fillWidth: true
            visible: Promethee.available && Promethee.apps.length === 0
            textFormat: Text.PlainText
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colOnSurfaceVariant
            text: Translation.tr("No app time tracked yet today")
        }

        Rectangle {
            Layout.fillWidth: true
            visible: Promethee.profile !== null
            implicitHeight: 1
            color: Appearance.colors.colLayer0Border
        }

        // The profile line, only once the app has reported one. Chips rather
        // than a grey run-on: three unrelated numbers should not read as a
        // sentence.
        Row {
            Layout.fillWidth: true
            visible: Promethee.profile !== null
            spacing: 6

            Repeater {
                model: [
                    { icon: "military_tech", text: Translation.tr("Level %1").arg(Promethee.profile?.level ?? 0), show: true },
                    { icon: "stars", text: Translation.tr("%1 XP").arg(Promethee.profile?.totalXp ?? 0), show: true },
                    { icon: "local_fire_department", text: Translation.tr("%1 d").arg(Promethee.profile?.streak ?? 0), show: (Promethee.profile?.streak ?? 0) > 0 }
                ]

                Rectangle {
                    required property var modelData
                    visible: modelData.show
                    implicitWidth: chip.implicitWidth + 14
                    implicitHeight: chip.implicitHeight + 6
                    radius: height / 2
                    color: Appearance.colors.colLayer2

                    Row {
                        id: chip
                        anchors.centerIn: parent
                        spacing: 4

                        MaterialSymbol {
                            anchors.verticalCenter: parent.verticalCenter
                            iconSize: Appearance.font.pixelSize.smaller
                            color: Appearance.colors.colOnSurfaceVariant
                            text: modelData.icon
                        }

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            textFormat: Text.PlainText
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            color: Appearance.colors.colOnLayer1
                            text: modelData.text
                        }
                    }
                }
            }
        }

        StyledText {
            Layout.fillWidth: true
            visible: Promethee.available && !Promethee.authenticated
            textFormat: Text.PlainText
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.m3colors.m3error
            text: Translation.tr("Not signed in — open the dashboard to sign in")
        }

        StyledText {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            font.pixelSize: Appearance.font.pixelSize.smallest
            opacity: 0.7
            color: Appearance.colors.colOnSurfaceVariant
            text: {
                if (!Promethee.available)
                    return Translation.tr("Click: launch Promethee");
                if (!Promethee.session)
                    return Translation.tr("Click: start · Right click: dashboard");
                // Ending is on the middle button on purpose: it is the one
                // gesture here that cannot be undone.
                return Promethee.paused
                    ? Translation.tr("Click: resume · Middle: end · Right click: dashboard")
                    : Translation.tr("Click: pause · Middle: end · Right click: dashboard");
            }
        }
    }
}
