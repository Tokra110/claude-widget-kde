import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2

import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as Plasma5Support

// The Cost tab. Its Loader is active while the popup is open, so the count
// (cost_report.py, under a second with its cache) runs when the popup opens,
// before the tab is clicked, and nothing of it stays in memory after the popup
// closes. One full count returns every period, so switching is instant.
//
// Layout rule: every block has a fixed height and keeps it while counting or
// when a period has no data, so switching periods never moves anything. Only
// the model list varies in length, and it is the last block inside a scroll
// area, so the popup itself never changes size.
ColumnLayout {
    id: costView
    spacing: Kirigami.Units.smallSpacing

    property var report: null
    property bool busy: false
    property string errorText: ""

    readonly property var periods: report && report.periods ? report.periods : []
    readonly property var current: {
        for (var i = 0; i < periods.length; i++) {
            if (periods[i].key === root.costPeriod) return periods[i]
        }
        return null
    }
    // Filters set by clicking a model row or a day bar; a second click on the
    // same one clears it. Both reset with the tab, and the day also with the period.
    property string filterModel: ""
    property string filterDay: ""
    readonly property bool filtered: filterModel !== "" || filterDay !== ""

    // One period of Today: the big chart shows its hours, the small one the
    // last 7 days around it, so Today never repeats the This week chart.
    readonly property bool oneDay: !!current && current.start_day === current.end_day

    readonly property var cells: report && report.cells ? report.cells : []
    function typeIndex(key) {
        var t = report && report.types ? report.types : ["input", "output", "cache_write", "cache_read"]
        return t.indexOf(key)
    }

    function isoDay(d) {
        return Qt.formatDate(d, "yyyy-MM-dd")
    }
    function addDays(iso, n) {
        var d = new Date(iso + "T12:00:00")
        d.setDate(d.getDate() + n)
        return isoDay(d)
    }
    function daysFrom(first, last) {
        var out = []
        for (var d = first; d <= last && out.length < 4000; d = addDays(d, 1)) out.push(d)
        return out
    }

    // Everything the tab shows for the period, the picked day and the picked
    // model, summed from the cells.
    readonly property var view: {
        var c = current
        if (!c) return null
        var v = { cost: 0, tokens: 0, replies: 0, days: {}, activeDays: 0,
                  byType: {}, hours: [] }
        for (var t = 0; t < typeChoices.length; t++) v.byType[typeChoices[t].key] = 0
        for (var h = 0; h < 24; h++) v.hours.push({})
        for (var i = 0; i < cells.length; i++) {
            var x = cells[i]
            if (x[0] < c.start_day || x[0] > c.end_day) continue
            if (filterDay && x[0] !== filterDay) continue
            if (filterModel && x[1] !== filterModel) continue
            v.cost += x[2]
            v.tokens += x[3]
            v.replies += x[4]
            if (!v.days[x[0]]) { v.days[x[0]] = true; v.activeDays++ }
            for (var k = 0; k < typeChoices.length; k++) {
                var ti = typeIndex(typeChoices[k].key)
                if (ti >= 0) v.byType[typeChoices[k].key] += x[5][ti]
            }
            for (var hh = 0; hh < 24; hh++) {
                if (x[6][hh] > 0) v.hours[hh][x[1]] = (v.hours[hh][x[1]] || 0) + x[6][hh]
            }
        }
        return v
    }

    // Model rows: the period and the picked day, all models, so another model
    // can be picked while one is.
    readonly property var modelRows: {
        var c = current
        if (!c) return []
        var by = {}
        for (var i = 0; i < cells.length; i++) {
            var x = cells[i]
            if (x[0] < c.start_day || x[0] > c.end_day) continue
            if (filterDay && x[0] !== filterDay) continue
            if (!by[x[1]]) by[x[1]] = { model: x[1], cost: 0, tokens: 0 }
            by[x[1]].cost += x[2]
            by[x[1]].tokens += x[3]
        }
        var out = []
        for (var m in by) out.push(by[m])
        out.sort(function (a, b) { return b.cost - a.cost })
        return out
    }
    readonly property real modelTotal: {
        var t = 0
        for (var i = 0; i < modelRows.length; i++) t += modelRows[i].cost
        return t
    }

    // Day bars, stacked by model; only the picked model when one is picked.
    function stacked(map) {
        var parts = []
        var total = 0
        for (var m in map) {
            parts.push([m, map[m]])
            total += map[m]
        }
        parts.sort(function (a, b) { return b[1] - a[1] })
        return { cost: total, parts: parts }
    }
    readonly property var dayList: {
        var c = current
        if (!c) return []
        return daysFrom(oneDay ? addDays(c.start_day, -6) : c.start_day, c.end_day)
    }
    readonly property var daySeries: {
        var by = {}
        for (var i = 0; i < cells.length; i++) {
            var x = cells[i]
            if (filterModel && x[1] !== filterModel) continue
            if (!by[x[0]]) by[x[0]] = {}
            by[x[0]][x[1]] = (by[x[0]][x[1]] || 0) + x[2]
        }
        var out = []
        for (var d = 0; d < dayList.length; d++) {
            var b = stacked(by[dayList[d]] || {})
            out.push({ label: dayList[d], cost: b.cost, parts: b.parts })
        }
        return out
    }
    readonly property var hourSeries: {
        var out = []
        for (var h = 0; h < 24; h++) {
            var b = stacked(view ? view.hours[h] : {})
            out.push({ label: (h < 10 ? "0" : "") + h, cost: b.cost, parts: b.parts })
        }
        return out
    }

    readonly property color mutedText: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                               Kirigami.Theme.textColor.b, 0.6)

    // Fixed list, so the period picker is filled before the first count ends.
    readonly property var periodChoices: [
        { key: "today", label: "Today" },
        { key: "this_week", label: "This week" },
        { key: "last_week", label: "Last week" },
        { key: "this_month", label: "This month" },
        { key: "last_30", label: "Last 30 days" },
        { key: "last_90", label: "Last 90 days" },
        { key: "all", label: "All time" }
    ]

    readonly property var typeChoices: [
        { key: "cache_read", label: "Cache read", color: "#5DB37E" },
        { key: "cache_write", label: "Cache write", color: "#E5C07B" },
        { key: "output", label: "Output", color: "#D77757" },
        { key: "input", label: "Input", color: "#4E9BD8" }
    ]

    // Two steps: first only the picked period (a fraction of a second, from
    // the cache and the files written in that period), then every period in
    // the background, so switching the period afterwards is instant.
    function command(period) {
        return root.pythonCommand("cost_report.py", period ? ["--period", period] : [])
    }

    function reload() {
        if (busy) return
        busy = true
        errorText = ""
        // A recount starts from the picked period again; the old numbers stay
        // on screen until the new ones arrive, so nothing blanks out.
        // "All time" needs every file anyway, so it goes straight to the full count.
        runner.connectSource(command(root.costPeriod === "all" ? "" : root.costPeriod))
    }

    function money(v) {
        v = v || 0
        if (v >= 1000) return "$" + Math.round(v).toLocaleString(Qt.locale("en_US"), "f", 0)
        return "$" + v.toFixed(2)
    }

    function shortMoney(v) {
        if (v >= 100) return "$" + Math.round(v)
        if (v >= 10) return "$" + v.toFixed(1)
        return "$" + v.toFixed(2)
    }

    function tokens(n) {
        if (n >= 1e9) return (n / 1e9).toFixed(2) + "B"
        if (n >= 1e6) return (n / 1e6).toFixed(1) + "M"
        if (n >= 1e3) return Math.round(n / 1e3) + "k"
        return String(n)
    }

    // claude-opus-5-5 -> Opus 5.5, claude-haiku-4-5-20251001 -> Haiku 4.5
    function modelName(id) {
        var m = /^claude-([a-z]+)-(\d+(?:-\d{1,2})?)(?:-\d{8})?/.exec(id)
        if (!m) return id
        return m[1].charAt(0).toUpperCase() + m[1].slice(1) + " " + m[2].replace("-", ".")
    }

    // One colour per model family, the same in every chart.
    function modelColor(id) {
        if (id.indexOf("opus") >= 0) return "#D77757"
        if (id.indexOf("fable") >= 0 || id.indexOf("mythos") >= 0) return "#9B7BD4"
        if (id.indexOf("sonnet") >= 0) return "#4E9BD8"
        if (id.indexOf("haiku") >= 0) return "#5DB37E"
        return "#9AA0A6"
    }

    function dayLabel(iso, format) {
        var d = new Date(iso + "T12:00:00")
        if (isNaN(d.getTime())) return iso
        return Qt.formatDate(d, format === true ? "ddd" : format ? format : "MMM d")
    }

    // Day charts: every day up to a week (as weekday names), else four evenly
    // spaced dates from the first bar to the last, so labels never touch.
    function dayTicks(series) {
        var n = series.length
        var t = []
        if (n <= 7) {
            for (var i = 0; i < n; i++) t.push(i)
            return t
        }
        for (var j = 0; j < 4; j++) t.push(Math.round(j * (n - 1) / 3))
        return t
    }

    Plasma5Support.DataSource {
        id: runner
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            disconnectSource(sourceName)
            var parsed = null
            try {
                parsed = JSON.parse(data["stdout"])
            } catch (e) {
                costView.errorText = "Could not count usage."
            }
            if (parsed && parsed.error) {
                costView.errorText = parsed.error
                parsed = null
            }
            if (!parsed) {
                costView.busy = false
                return
            }
            if (parsed.partial) {
                // Keep the other periods of an earlier full count, if any,
                // until the background count replaces them.
                var merged = parsed
                if (costView.report && !costView.report.partial) {
                    var old = costView.report
                    merged = { periods: old.periods.slice(), types: parsed.types, partial: true,
                               first: old.first, unpriced: parsed.unpriced, generated: parsed.generated,
                               cells: [] }
                    for (var i = 0; i < merged.periods.length; i++) {
                        if (merged.periods[i].key === parsed.periods[0].key) merged.periods[i] = parsed.periods[0]
                    }
                    // Old cells before the fast count's first day, then its own.
                    for (var j = 0; j < old.cells.length; j++) {
                        if (parsed.cells_from && old.cells[j][0] < parsed.cells_from) merged.cells.push(old.cells[j])
                    }
                    merged.cells = merged.cells.concat(parsed.cells)
                }
                costView.report = merged
                runner.connectSource(costView.command(""))
            } else {
                costView.report = parsed
                costView.busy = false
            }
        }
    }

    Component.onCompleted: reload()

    // First row: the total on the left, the period picker in the right third.
    RowLayout {
        id: topRow
        Layout.fillWidth: true
        Layout.preferredHeight: Kirigami.Units.gridUnit * 2.4
        spacing: Kirigami.Units.smallSpacing

        // Two thirds and one third, by stretch factor: a width bound to the
        // row's own width makes the layout loop.
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredWidth: 0
            Layout.horizontalStretchFactor: 2
            Kirigami.Heading {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                visible: !!costView.view
                text: costView.view ? costView.money(costView.view.cost) : ""
                level: 1
            }
            QQC2.BusyIndicator {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                height: parent.height
                width: height
                running: !costView.current && costView.errorText === ""
                visible: running
            }
            // Clears the model and day filters; inside the total's two
            // thirds, so the period picker keeps its width.
            QQC2.ToolButton {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                icon.name: "kt-remove-filters"
                width: Kirigami.Units.gridUnit * 1.8
                height: width
                visible: costView.filtered
                onClicked: {
                    costView.filterModel = ""
                    costView.filterDay = ""
                }
                QQC2.ToolTip.text: "Show all again"
                QQC2.ToolTip.visible: hovered
            }
        }

    QQC2.ComboBox {
        Layout.fillWidth: true
        Layout.preferredWidth: 0
        Layout.horizontalStretchFactor: 1
        model: costView.periodChoices
        textRole: "label"
        valueRole: "key"
        currentIndex: {
            for (var i = 0; i < costView.periodChoices.length; i++) {
                if (costView.periodChoices[i].key === root.costPeriod) return i
            }
            return 1
        }
        onActivated: {
            costView.filterDay = ""
            root.costPeriod = currentValue
        }
    }
    }

    // Second row: tokens, replies and the average on days with use; with a
    // filter on, it starts with what is picked (and drops the average). One
    // line of fixed height, so the charts below never move.
    RowLayout {
        Layout.fillWidth: true
        spacing: Kirigami.Units.smallSpacing
        QQC2.Label {
            Layout.fillWidth: true
            Layout.preferredWidth: 0
            text: {
                var v = costView.view
                if (!v) return ""
                var t = ""
                if (costView.filterModel) t += costView.modelName(costView.filterModel) + " · "
                if (costView.filterDay) t += costView.dayLabel(costView.filterDay, "ddd, MMM d") + " · "
                t += costView.tokens(v.tokens) + " tokens · " + v.replies + " replies"
                if (v.activeDays > 1 && !costView.filtered) t += " · " + costView.money(v.cost / v.activeDays) + "/day on " + v.activeDays + " days"
                return t
            }
            font: Kirigami.Theme.smallFont
            color: costView.filtered ? Kirigami.Theme.textColor : costView.mutedText
            elide: Text.ElideRight
        }
    }

    QQC2.Label {
        Layout.fillWidth: true
        visible: costView.errorText !== ""
        text: costView.errorText
        color: Kirigami.Theme.negativeTextColor
        wrapMode: Text.Wrap
    }

    QQC2.ScrollView {
        id: scroller
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.topMargin: fullRep.groupGap - Kirigami.Units.smallSpacing
        // The scroll bar sits in the popup's right margin, so the content ends
        // on the same right edge as the Limits tab. It always shows, so the
        // content width never changes when a period gets longer or shorter.
        Layout.rightMargin: -fullRep.sideMargin
        contentWidth: availableWidth
        QQC2.ScrollBar.horizontal.policy: QQC2.ScrollBar.AlwaysOff
        QQC2.ScrollBar.vertical.policy: QQC2.ScrollBar.AlwaysOn

        ColumnLayout {
            width: scroller.availableWidth - fullRep.sideMargin
            spacing: Kirigami.Units.smallSpacing

            // --- Big chart: days of the period (click one to pick it), or
            // the hours of Today ---
            CostBars {
                Layout.fillWidth: true
                title: costView.oneDay ? "Cost per hour" : "Cost per day"
                chartHeight: Kirigami.Units.gridUnit * 5
                series: costView.oneDay ? costView.hourSeries : costView.daySeries
                colorFor: costView.modelColor
                formatValue: costView.shortMoney
                formatLabel: costView.oneDay ? function (label) { return label + ":00" }
                    : function (label) { return costView.dayLabel(label, series.length <= 7) }
                tickIndexes: costView.oneDay ? [0, 6, 12, 18, 23] : costView.dayTicks(series)
                clickable: !costView.oneDay
                selectedIndex: costView.filterDay ? costView.dayList.indexOf(costView.filterDay) : -1
                onBarClicked: (i) => {
                    var d = costView.dayList[i]
                    costView.filterDay = costView.filterDay === d ? "" : d
                }
            }

            // --- What the money went on: token types ---
            Kirigami.Heading {
                level: 5
                Layout.topMargin: fullRep.groupGap - Kirigami.Units.smallSpacing
                text: "By token type"
            }
            Row {
                id: typeBar
                Layout.fillWidth: true
                Layout.preferredHeight: Kirigami.Units.gridUnit * 0.6
                readonly property real total: costView.view ? costView.view.cost : 0
                Repeater {
                    model: costView.typeChoices
                    Rectangle {
                        height: typeBar.height
                        width: typeBar.total > 0 && costView.view
                            ? typeBar.width * (costView.view.byType[modelData.key] || 0) / typeBar.total : 0
                        color: modelData.color
                    }
                }
                Rectangle {
                    // Empty track when there is nothing to split
                    visible: typeBar.total <= 0
                    width: typeBar.width
                    height: typeBar.height
                    color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                   Kirigami.Theme.textColor.b, 0.1)
                }
            }
            GridLayout {
                Layout.fillWidth: true
                columns: 2
                columnSpacing: Kirigami.Units.largeSpacing
                rowSpacing: 0
                Repeater {
                    model: costView.typeChoices
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.preferredWidth: 1
                        Rectangle {
                            width: Kirigami.Units.gridUnit * 0.5
                            height: width
                            color: modelData.color
                        }
                        QQC2.Label {
                            text: modelData.label
                            font: Kirigami.Theme.smallFont
                            Layout.fillWidth: true
                        }
                        QQC2.Label {
                            text: costView.view ? costView.money(costView.view.byType[modelData.key]) : "-"
                            font: Kirigami.Theme.smallFont
                            color: costView.mutedText
                        }
                    }
                }
            }

            // --- Small chart: hours of the day, or for Today the last 7 days ---
            CostBars {
                Layout.fillWidth: true
                Layout.topMargin: fullRep.groupGap - Kirigami.Units.smallSpacing
                title: costView.oneDay ? "Last 7 days" : "By hour of day"
                chartHeight: Kirigami.Units.gridUnit * 3
                series: costView.oneDay ? costView.daySeries : costView.hourSeries
                colorFor: costView.modelColor
                formatValue: costView.shortMoney
                formatLabel: costView.oneDay ? function (label) { return costView.dayLabel(label, true) }
                    : function (label) { return label + ":00" }
                tickIndexes: costView.oneDay ? costView.dayTicks(series) : [0, 6, 12, 18, 23]
                selectedIndex: costView.oneDay ? series.length - 1 : -1
            }

            // --- Model shares ---
            Kirigami.Heading {
                level: 5
                Layout.topMargin: fullRep.groupGap - Kirigami.Units.smallSpacing
                text: "By model"
            }
            Repeater {
                model: costView.modelRows
                Item {
                    id: modelRow
                    Layout.fillWidth: true
                    implicitHeight: rowColumn.implicitHeight + 4
                    readonly property real share: costView.modelTotal > 0 ? modelData.cost / costView.modelTotal : 0
                    readonly property bool picked: costView.filterModel === modelData.model

                    Rectangle {
                        anchors.fill: parent
                        radius: 3
                        color: Kirigami.Theme.highlightColor
                        opacity: rowHover.containsMouse ? 0.25 : modelRow.picked ? 0.12 : 0
                    }
                    ColumnLayout {
                        id: rowColumn
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: 2
                        anchors.rightMargin: 2
                        spacing: 1
                        opacity: costView.filterModel === "" || modelRow.picked ? 1 : 0.45
                        RowLayout {
                            Layout.fillWidth: true
                            Rectangle {
                                width: Kirigami.Units.gridUnit * 0.5
                                height: width
                                radius: width / 2
                                color: costView.modelColor(modelData.model)
                            }
                            QQC2.Label {
                                text: costView.modelName(modelData.model)
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                font.bold: modelRow.picked
                            }
                            QQC2.Label {
                                text: Math.round(modelRow.share * 100) + "%"
                                font: Kirigami.Theme.smallFont
                                color: costView.mutedText
                            }
                            QQC2.Label {
                                text: costView.money(modelData.cost)
                                horizontalAlignment: Text.AlignRight
                                Layout.preferredWidth: Kirigami.Units.gridUnit * 4
                            }
                        }
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 3
                            radius: 1.5
                            color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                           Kirigami.Theme.textColor.b, 0.1)
                            Rectangle {
                                height: parent.height
                                radius: parent.radius
                                width: parent.width * modelRow.share
                                color: costView.modelColor(modelData.model)
                            }
                        }
                    }
                    MouseArea {
                        id: rowHover
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: costView.filterModel = modelRow.picked ? "" : modelData.model
                    }
                    QQC2.ToolTip.visible: rowHover.containsMouse
                    QQC2.ToolTip.delay: 500
                    QQC2.ToolTip.text: modelRow.picked ? "Click: show all models" : "Click: show only " + costView.modelName(modelData.model)
                }
            }
            QQC2.Label {
                visible: !!costView.view && costView.view.replies === 0
                text: costView.filtered ? "No use for this filter." : "No Claude Code use in this period."
                color: costView.mutedText
            }
            QQC2.Label {
                Layout.fillWidth: true
                visible: !!costView.report && !!costView.report.unpriced && costView.report.unpriced.length > 0
                text: "No price known yet for " + (costView.report && costView.report.unpriced
                    ? costView.report.unpriced.join(", ") : "") + ", so its use counts as $0."
                font: Kirigami.Theme.smallFont
                color: costView.mutedText
                wrapMode: Text.Wrap
            }
        }
    }
}
