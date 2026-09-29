pragma Singleton

import qs.modules.common
import QtQuick
import Quickshell

Singleton {
    id: root

    readonly property color card: "#262626"
    readonly property color inset: "#303030"
    readonly property color band: "#202020"
    readonly property color line: Qt.rgba(1, 1, 1, 0.07)
    readonly property color fg: "#f2f2f2"
    readonly property color muted: "#8f8f8f"
    readonly property color faint: "#6b6b6b"
    readonly property color fire: "#df633a"
    readonly property color online: "#3ecf6e"
    readonly property var appShades: [root.fire, "#a8a8a8", "#5e5e5e"]

    readonly property string family: dmSans.status === FontLoader.Ready ? dmSans.name : Appearance.font.family.main

    readonly property int levelStepXp: 100
    readonly property int xpPerMinute: 10

    FontLoader {
        id: dmSans
        source: "../../../assets/fonts/DMSans.ttf"
    }

    function levelFromXp(totalXp) {
        let level = 1;
        while (level < 1000 && root.xpAtLevelStart(level + 1) <= totalXp)
            level += 1;
        return level;
    }

    function xpAtLevelStart(level) {
        const completed = Math.max(1, level) - 1;
        return completed * (completed + 1) / 2 * root.levelStepXp;
    }

    function levelProgress(totalXp) {
        const xp = Math.max(0, totalXp ?? 0);
        const level = root.levelFromXp(xp);
        const into = xp - root.xpAtLevelStart(level);
        const span = level * root.levelStepXp;
        return {
            level: level,
            into: into,
            span: span,
            ratio: Math.min(1, into / span),
            minutesLeft: Math.max(1, Math.ceil(Math.max(0, span - into) / root.xpPerMinute))
        };
    }

    function hoursMinutes(seconds) {
        const total = Math.max(0, Math.floor(seconds));
        const h = Math.floor(total / 3600);
        const m = Math.floor((total % 3600) / 60);
        return h > 0 ? `${h}h ${m}m` : `${m}m`;
    }

    function grouped(value) {
        return Number(value ?? 0).toLocaleString(Qt.locale(), "f", 0);
    }
}
