import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Layouts

/**
 * Everything the bar has no room for: the running task, the day's totals, the
 * profile, and what Promethee is currently attributing time to.
 */
StyledPopup {
    id: root

    readonly property string headerIcon: {
        if (!Promethee.available)
            return "cloud_off";
        return Promethee.session ? "local_fire_department" : "hourglass_empty";
    }

    readonly property string headerLabel: {
        if (!Promethee.available)
            return Translation.tr("Promethee — not running");
        if (Promethee.paused)
            return Translation.tr("Promethee — paused");
        return Promethee.session ? Translation.tr("Promethee — focusing") : Translation.tr("Promethee");
    }

    ColumnLayout {
        anchors.centerIn: parent
        spacing: 6

        StyledPopupHeaderRow {
            icon: root.headerIcon
            label: root.headerLabel
        }

        // The running task, on its own line: it is a free-text sentence and
        // would push the value column out of alignment in a value row.
        StyledText {
            Layout.fillWidth: true
            Layout.maximumWidth: 280
            visible: (Promethee.session?.task ?? "").length > 0
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.colors.colOnLayer1
            text: Promethee.session?.task ?? ""
        }

        StyledPopupValueRow {
            Layout.fillWidth: true
            visible: Promethee.session !== null
            icon: "timer"
            label: Translation.tr("Current session")
            value: Promethee.formatDuration(Promethee.elapsed)
        }

        StyledPopupValueRow {
            Layout.fillWidth: true
            icon: "today"
            label: Translation.tr("Today")
            value: Translation.tr("%1 in %2 session(s)")
                .arg(Promethee.formatShort(Promethee.todaySeconds))
                .arg(Promethee.today?.sessions ?? 0)
        }

        StyledPopupValueRow {
            Layout.fillWidth: true
            visible: Promethee.profile !== null
            icon: "trophy"
            label: Translation.tr("Level %1").arg(Promethee.profile?.level ?? 0)
            value: Translation.tr("%1 XP").arg(Promethee.profile?.totalXp ?? 0)
        }

        StyledPopupValueRow {
            Layout.fillWidth: true
            visible: (Promethee.profile?.streak ?? 0) > 0
            icon: "whatshot"
            label: Translation.tr("Streak")
            value: Translation.tr("%1 day(s)").arg(Promethee.profile?.streak ?? 0)
        }

        // What the tracker sees right now. This is the one line that says
        // whether the Linux window detection is actually working.
        StyledPopupValueRow {
            Layout.fillWidth: true
            visible: (Promethee.window?.app ?? "").length > 0
            icon: "visibility"
            label: Translation.tr("Tracking")
            value: Promethee.window?.app ?? ""
        }

        StyledPopupValueRow {
            Layout.fillWidth: true
            visible: Promethee.available && !Promethee.authenticated
            icon: "person_off"
            label: Translation.tr("Sign in from the dashboard")
            value: ""
        }

        StyledText {
            Layout.fillWidth: true
            Layout.topMargin: 2
            textFormat: Text.PlainText
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colOnSurfaceVariant
            text: Promethee.available
                ? (Promethee.session
                    ? Translation.tr("Click to end · Right click for the dashboard")
                    : Translation.tr("Click to start · Right click for the dashboard"))
                : Translation.tr("Click to launch Promethee")
        }
    }
}
