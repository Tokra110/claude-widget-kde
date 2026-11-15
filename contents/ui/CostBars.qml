import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2

import org.kde.kirigami as Kirigami

// A small bar chart drawn from plain rectangles, so it needs no chart module.
// series: [{ label, cost, parts: [[model, cost], ...] }]. A bar with parts is
// stacked by model (colorFor(model)); without parts it uses barColor.
// Every size is fixed by the caller, so nothing moves when the data changes.
// With clickable set, a click on a bar sends barClicked(index); the bar at
// selectedIndex stays bright and the others fade.
ColumnLayout {
    id: chart
    spacing: 2

    property bool clickable: false
    property int selectedIndex: -1
    signal barClicked(int index)

    property string title: ""
    property var series: []
    property real chartHeight: Kirigami.Units.gridUnit * 5
    property color barColor: "#D77757"
    property var colorFor: function (model) { return barColor }
    property var formatValue: function (v) { return "$" + v.toFixed(2) }
    property var formatLabel: function (label) { return label }
    // Which bar labels to print under the chart (index list); the rest show on hover.
    property var tickIndexes: series.length ? [0, series.length - 1] : []

    readonly property real maxValue: {
        var m = 0
        for (var i = 0; i < series.length; i++) m = Math.max(m, series[i].cost)
        return m
    }
    readonly property color mutedText: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                               Kirigami.Theme.textColor.b, 0.6)

    // Title on the left, the tallest bar's value on the right: it is the
    // value of the faint top line, so the scale reads without covering bars.
    RowLayout {
        Layout.fillWidth: true
        Kirigami.Heading {
            level: 5
            text: chart.title
            Layout.fillWidth: true
            elide: Text.ElideRight
        }
        QQC2.Label {
            text: chart.maxValue > 0 ? "top " + chart.formatValue(chart.maxValue) : ""
            font: Kirigami.Theme.smallFont
            color: chart.mutedText
        }
    }

    Item {
        Layout.fillWidth: true
        Layout.preferredHeight: chart.chartHeight

        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 1
            color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                           Kirigami.Theme.textColor.b, 0.12)
        }
        // Base line
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 1
            color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                           Kirigami.Theme.textColor.b, 0.25)
        }

        Row {
            id: bars
            anchors.fill: parent
            anchors.bottomMargin: 1
            readonly property real slot: chart.series.length ? width / chart.series.length : 0
            spacing: 0

            Repeater {
                model: chart.series
                Item {
                    width: bars.slot
                    height: bars.height
                    readonly property real share: chart.maxValue > 0 ? modelData.cost / chart.maxValue : 0

                    Column {
                        id: stack
                        opacity: chart.selectedIndex < 0 || chart.selectedIndex === index ? 1 : 0.35
                        anchors.bottom: parent.bottom
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: Math.max(1, Math.min(bars.slot * 0.75, Kirigami.Units.gridUnit * 1.2))
                        // Biggest model at the bottom of the stack
                        Repeater {
                            model: modelData.parts && modelData.parts.length
                                ? modelData.parts.slice().reverse() : [[null, modelData.cost]]
                            Rectangle {
                                width: stack.width
                                height: chart.maxValue > 0
                                    ? Math.max(0, (bars.height - 2) * modelData[1] / chart.maxValue) : 0
                                color: modelData[0] ? chart.colorFor(modelData[0]) : chart.barColor
                            }
                        }
                    }

                    MouseArea {
                        id: hover
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: chart.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: if (chart.clickable) chart.barClicked(index)
                    }
                    Rectangle {
                        anchors.fill: parent
                        color: Kirigami.Theme.highlightColor
                        opacity: hover.containsMouse ? (chart.clickable ? 0.25 : 0.15)
                            : chart.selectedIndex === index ? 0.12 : 0
                    }
                    QQC2.ToolTip.visible: hover.containsMouse
                    QQC2.ToolTip.delay: 0
                    QQC2.ToolTip.text: chart.formatLabel(modelData.label) + ": " + chart.formatValue(modelData.cost)
                        + (!chart.clickable ? "" : chart.selectedIndex === index ? " (click: show all)" : " (click: show only this)")
                }
            }
        }
    }

    // Labels under chosen bars, placed at the bar's centre and kept inside.
    Item {
        Layout.fillWidth: true
        Layout.preferredHeight: tickMetrics.height

        QQC2.Label {
            id: tickMetrics
            visible: false
            text: "0"
            font: Kirigami.Theme.smallFont
        }

        Repeater {
            model: chart.tickIndexes
            QQC2.Label {
                readonly property int idx: modelData
                readonly property real slot: chart.series.length ? parent.width / chart.series.length : 0
                text: chart.series[idx] ? chart.formatLabel(chart.series[idx].label) : ""
                font: Kirigami.Theme.smallFont
                color: chart.mutedText
                x: Math.max(0, Math.min(parent.width - width, slot * (idx + 0.5) - width / 2))
            }
        }
    }
}
