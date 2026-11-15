import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2

import org.kde.kirigami as Kirigami

import "peak.js" as Peak

// Root is a plain Item, not a Layout, to avoid KDE bug 489365:
// plasmashell crashes in QQuickLayout::effectiveSizePolicy_helper when the
// popup is first expanded if the fullRepresentation root is a QQuickLayout.
Item {
    id: fullRep

    // One fixed size for both tabs, so the popup never jumps when the tab,
    // the period or the data changes. The Cost tab scrolls inside it.
    readonly property real popupWidth: Kirigami.Units.gridUnit * 20
    readonly property real popupHeight: Kirigami.Units.gridUnit * 30
    // One margin for everything inside the popup, so text, bars and the
    // footer line up on the same left and right edges.
    readonly property real sideMargin: Math.round(Kirigami.Units.gridUnit * 0.75)
    // Space between groups (5-hour, weekly, peak hours); items inside a
    // group use smallSpacing. Space instead of separator lines.
    readonly property real groupGap: Kirigami.Units.gridUnit
    Layout.minimumWidth: popupWidth
    Layout.preferredWidth: popupWidth
    Layout.minimumHeight: popupHeight
    Layout.preferredHeight: popupHeight
    implicitWidth: popupWidth
    implicitHeight: popupHeight

    ColumnLayout {
        id: content
        anchors.fill: parent
        spacing: Kirigami.Units.smallSpacing

    // Two tab buttons that split the full width in equal halves. A plain row
    // instead of TabBar: TabBar sizes its buttons from their text in the
    // Breeze style, and pinning them to half its width makes a binding loop.
    RowLayout {
        id: tabs
        property int currentIndex: 0
        // With the Cost tab turned off there is nothing to switch to.
        visible: root.costTabEnabled
        onVisibleChanged: if (!visible) currentIndex = 0
        Layout.fillWidth: true
        spacing: 0
        QQC2.ButtonGroup { id: tabGroup }
        Repeater {
            model: ["Limits", "Cost"]
            QQC2.TabButton {
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                text: modelData
                checkable: true
                checked: tabs.currentIndex === index
                QQC2.ButtonGroup.group: tabGroup
                onClicked: tabs.currentIndex = index
            }
        }
    }

    // Limits tab
    ColumnLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        visible: tabs.currentIndex === 0
        spacing: Kirigami.Units.smallSpacing

        // Error display
        QQC2.Label {
            Layout.fillWidth: true
            Layout.leftMargin: fullRep.sideMargin
            Layout.rightMargin: fullRep.sideMargin
            visible: root.hasError
            text: root.errorMessage
            color: Kirigami.Theme.negativeTextColor
            wrapMode: Text.Wrap
        }

        // Fallback note: the numbers come from the Claude desktop app
        QQC2.Label {
            Layout.fillWidth: true
            Layout.leftMargin: fullRep.sideMargin
            Layout.rightMargin: fullRep.sideMargin
            visible: !root.hasError && root.dataSource === "desktop"
            text: "Numbers from the Claude desktop app. " + root.sourceNote
            font: Kirigami.Theme.smallFont
            wrapMode: Text.Wrap
        }

        // Loading indicator
        QQC2.BusyIndicator {
            Layout.alignment: Qt.AlignHCenter
            visible: root.loading && !root.hasError
            running: visible
        }

        // Usage bars
        ColumnLayout {
            Layout.fillWidth: true
            Layout.leftMargin: fullRep.sideMargin
            Layout.rightMargin: fullRep.sideMargin
            Layout.topMargin: Kirigami.Units.smallSpacing
            visible: root.hasData
            // The same gap between every limit, and before extra usage and
            // the peak hours below.
            spacing: fullRep.groupGap

            UsageBar {
                Layout.fillWidth: true
                visible: root.hasFiveHour && root.limitShown("five_hour")
                label: "5-hour"
                percentage: root.fiveHourUtil
                barColor: root.usageColor(root.fiveHourUtil)
                resetTime: root.formatResetTime(root.fiveHourResets)
                // No pace here: the window starts with the first message, so a
                // straight line through 5 hours says little about real use.
            }

            UsageBar {
                Layout.fillWidth: true
                visible: root.limitShown("seven_day")
                label: "Weekly · all models"
                percentage: root.sevenDayUtil
                barColor: root.usageColor(root.sevenDayUtil)
                resetTime: root.formatResetTime(root.sevenDayResets)
                segments: 7
                pace: root.paceFraction(root.sevenDayResets, root.weeklyWindowMs)
            }

            Repeater {
                // Counted, not array-backed. root.weeklyModels is rebuilt on every
                // poll, and a fresh array makes the Repeater destroy and recreate
                // its delegates, which restarted each bar's width animation from
                // zero. Binding on the length instead keeps the same UsageBar alive
                // whenever the set of limits is unchanged, so it animates from its
                // previous value to the new one like the fixed bars above.
                model: root.weeklyModels.length
                UsageBar {
                    readonly property var entry: root.weeklyModels[index] || null

                    Layout.fillWidth: true
                    visible: !entry || root.limitShown(entry.key)
                    label: entry ? entry.label : ""
                    percentage: entry ? entry.util : 0
                    barColor: root.usageColor(percentage)
                    resetTime: entry ? root.formatResetTime(entry.resets) : ""
                    segments: 7
                    pace: entry ? root.paceFraction(entry.resets, root.weeklyWindowMs) : -1
                }
            }
        }

        // Extra usage: a small grey note when it is off, a bar when it is on.
        QQC2.Label {
            Layout.fillWidth: true
            Layout.leftMargin: fullRep.sideMargin
            Layout.rightMargin: fullRep.sideMargin
            Layout.topMargin: fullRep.groupGap - Kirigami.Units.smallSpacing
            visible: root.hasExtraUsage && !root.extraUsageEnabled
            text: "Extra usage off"
            font: Kirigami.Theme.smallFont
            color: peakBox.mutedText
        }
        ColumnLayout {
            Layout.fillWidth: true
            Layout.leftMargin: fullRep.sideMargin
            Layout.rightMargin: fullRep.sideMargin
            Layout.topMargin: fullRep.groupGap - Kirigami.Units.smallSpacing
            visible: root.hasExtraUsage && root.extraUsageEnabled
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                QQC2.Label {
                    text: "Extra usage"
                    Layout.fillWidth: true
                }
                QQC2.Label {
                    text: root.extraUsageUsed + (root.extraUsageLimit ? " / " + root.extraUsageLimit : "")
                    font.bold: true
                    color: Kirigami.Theme.activeTextColor
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: Math.round(Kirigami.Units.gridUnit * 0.6)
                radius: height / 2
                color: Kirigami.Theme.backgroundColor
                border.color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.2)
                border.width: 1

                Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: parent.width * Math.min(root.extraUsageUtil / 100, 1.0)
                    radius: parent.radius
                    color: Kirigami.Theme.activeTextColor

                    Behavior on width {
                        NumberAnimation { duration: 300; easing.type: Easing.OutCubic }
                    }
                }
            }
        }

        // Peak hours clock: US time, and how fast the 5-hour limit drains
        // now (peak.js holds the rule, README "Peak hours" the sources).
        ColumnLayout {
            id: peakBox
            Layout.fillWidth: true
            visible: plasmoid.configuration.showPeakClock
            Layout.leftMargin: fullRep.sideMargin
            Layout.rightMargin: fullRep.sideMargin
            Layout.topMargin: fullRep.groupGap - Kirigami.Units.smallSpacing
            spacing: 2

            readonly property real nowMs: root.now.getTime()
            readonly property var state: Peak.status(nowMs)
            readonly property var window: Peak.nextPeakWindow(nowMs)
            // Fixed traffic-light colours: the theme's warning tones read as
            // orange and pink on some colour schemes.
            readonly property color levelColor: state.level === "peak" ? "#E5534B"
                : state.level === "busy" ? "#E5C07B" : "#5DB37E"
            readonly property color mutedText: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                                       Kirigami.Theme.textColor.b, 0.6)
            function levelName(level) {
                return level === "peak" ? "Peak hours" : level === "busy" ? "US working hours" : "Off-peak"
            }

            RowLayout {
                Layout.fillWidth: true
                Rectangle {
                    width: Kirigami.Units.gridUnit * 0.7
                    height: width
                    radius: width / 2
                    color: peakBox.levelColor
                }
                QQC2.Label {
                    text: peakBox.levelName(peakBox.state.level)
                    font.bold: true
                    Layout.fillWidth: true
                }
                QQC2.Label {
                    text: Peak.usClock(peakBox.nowMs) + " PT · " + Peak.usClock(peakBox.nowMs, true) + " ET"
                    font.features: { "tnum": 1 }
                }
            }
            QQC2.Label {
                Layout.fillWidth: true
                text: {
                    var w = peakBox.window
                    return Peak.countdown(peakBox.nowMs) + " · " + Qt.formatTime(w.start, "HH:mm") + "–" + Qt.formatTime(w.end, "HH:mm") + " here"
                }
                font: Kirigami.Theme.smallFont
                color: peakBox.mutedText
                elide: Text.ElideRight
            }
        }

        Item { Layout.fillHeight: true }
    }

    // Cost tab: loaded as soon as the popup opens, even on the Limits tab, so
    // switching tabs shows it at once with no counting. Plasma keeps the popup
    // alive after it closes, so it is unloaded on close: that frees its
    // charts, and the next open counts fresh numbers.
    Loader {
        id: costLoader
        Layout.fillWidth: true
        Layout.leftMargin: fullRep.sideMargin
        Layout.rightMargin: fullRep.sideMargin
        Layout.fillHeight: true
        active: root.expanded && root.costTabEnabled
        visible: active && tabs.currentIndex === 1
        source: "CostView.qml"
    }

    // Footer for both tabs: when the numbers are from, a spinner while
    // counting, and the refresh button in the bottom right corner.
    RowLayout {
        Layout.fillWidth: true
        Layout.leftMargin: fullRep.sideMargin
        Layout.preferredHeight: Kirigami.Units.gridUnit * 1.6
        readonly property var cost: tabs.currentIndex === 1 ? costLoader.item : null
        readonly property bool working: cost ? cost.busy : (root.loading || root.loginInFlight)

        QQC2.Label {
            Layout.fillWidth: true
            text: {
                // The Cost tab has no time line: its spinner shows while it counts.
                if (tabs.currentIndex === 1 || !root.hasData) return ""
                return (root.dataSource === "desktop" ? "Desktop app " : root.dataCached ? "Cached " : "Updated ")
                    + Qt.formatTime(root.lastUpdated, "hh:mm:ss")
            }
            font: Kirigami.Theme.smallFont
            elide: Text.ElideRight
            // Meta line, so it stays quiet, but lifted off disabledTextColor so it
            // is still legible on a dark panel.
            color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                           Kirigami.Theme.textColor.b, 0.55)
        }
        QQC2.BusyIndicator {
            Layout.preferredWidth: Kirigami.Units.gridUnit * 1.2
            Layout.preferredHeight: Kirigami.Units.gridUnit * 1.2
            running: parent.working
            // Keeps its place when idle, so the label never shifts.
            opacity: running ? 1 : 0
        }
        QQC2.ToolButton {
            icon.name: "view-refresh"
            onClicked: parent.cost ? parent.cost.reload() : root.heal()
            QQC2.ToolTip.text: tabs.currentIndex === 1 ? "Count again"
                : root.needsLogin ? "Sign in to Claude again" : "Refresh"
            QQC2.ToolTip.visible: hovered
            enabled: !parent.working && (tabs.currentIndex === 0 || !!parent.cost)
            implicitHeight: Kirigami.Units.gridUnit * 1.5
            implicitWidth: Kirigami.Units.gridUnit * 1.5
        }
    }
    }
}
