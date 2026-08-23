import qs.modules.common
import QtQuick

/**
 * Focus minutes over the last seven days, one bar per day.
 *
 * Bars rather than a curve: these are seven discrete daily totals, and a line
 * between them would draw a continuity that does not exist. Today is the last
 * bar and is drawn at full strength — it is the only one still moving.
 */
Canvas {
    id: root

    /// Minutes per day, oldest first. Seven entries, zero-filled by the server.
    property var series: []
    property color stroke: Appearance.colors.colOnLayer1
    property real gap: 2

    onSeriesChanged: root.requestPaint()
    onStrokeChanged: root.requestPaint()
    onWidthChanged: root.requestPaint()
    onHeightChanged: root.requestPaint()

    onPaint: {
        const ctx = root.getContext("2d");
        ctx.reset();
        const points = root.series;
        if (!points || points.length === 0)
            return;

        // Scaled against the week's own best day: an absolute scale would flatten
        // every bar on a quiet week, which is exactly the week worth reading.
        const peak = Math.max(1, ...points.map(v => v ?? 0));
        const slot = root.width / points.length;
        const barWidth = Math.max(1, slot - root.gap);
        const radius = Math.min(barWidth / 2, 2);

        for (let i = 0; i < points.length; i++) {
            const value = points[i] ?? 0;
            // A day with no focus still gets a stub, so the week reads as seven
            // days rather than as however many were productive.
            const height = value > 0 ? Math.max(2, (value / peak) * root.height) : 1.5;
            const x = i * slot;
            const y = root.height - height;

            ctx.beginPath();
            ctx.roundedRect(x, y, barWidth, height, radius, radius);
            ctx.fillStyle = Qt.alpha(root.stroke, i === points.length - 1 ? 1 : 0.4);
            ctx.fill();
        }
    }
}
