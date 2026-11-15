import QtQuick
import QtQuick.Layouts

import org.kde.kirigami as Kirigami

// Plain panel text: the utilization percentage of the selected window and
// nothing else. No icon, no bars, no ring. The "%" is drawn separately at
// half the size of the number, sharing its baseline, so the digits stay the
// thing you read.
//
// Two deliberate steps keep the item from resizing itself in a loop. The
// System Tray sizes a cell from both dimensions, so a width that follows the
// font, which follows the height, can oscillate and make the item flicker.
// So the font size is quantized to even pixels, and the reserved width is
// measured from a fixed "100%" rather than from the current value. The item
// therefore keeps one width from 0% to 100% and only steps its font when the
// panel thickness really changes.
Item {
    id: textRep

    readonly property real utilization: root.compactUtil

    // Kirigami.Theme here is the tray's own, so the light/dark decision follows
    // the panel the text actually sits on, not the desktop wallpaper or popup.
    readonly property bool darkPanel: Kirigami.ColorUtils.brightnessForColor(Kirigami.Theme.backgroundColor) === Kirigami.ColorUtils.Dark
    readonly property color numberColor: {
        var mode = plasmoid.configuration.textColorMode
        if (mode === "theme") return Kirigami.Theme.textColor
        if (mode === "custom") {
            return textRep.darkPanel
                ? plasmoid.configuration.textColorDark
                : plasmoid.configuration.textColorLight
        }
        return root.compactColor
    }
    readonly property int numberSize: {
        var raw = Math.min(height, Kirigami.Units.gridUnit * 1.4) * 0.72
        return Math.max(8, Math.round(raw / 2) * 2)
    }
    readonly property int contentWidth: Math.ceil(numberMetrics.width + percentMetrics.width)

    TextMetrics {
        id: numberMetrics
        font: number.font
        text: "100"
    }

    TextMetrics {
        id: percentMetrics
        font: percent.font
        text: "%"
    }

    Layout.minimumWidth: textRep.contentWidth
    Layout.preferredWidth: textRep.contentWidth
    Layout.maximumWidth: textRep.contentWidth
    Layout.minimumHeight: Kirigami.Units.gridUnit
    Layout.preferredHeight: Kirigami.Units.gridUnit

    Row {
        anchors.centerIn: parent
        spacing: 0

        Text {
            id: number
            text: root.hasError ? "--" : Math.round(textRep.utilization)
            color: root.hasError ? Kirigami.Theme.textColor : textRep.numberColor
            font.family: Kirigami.Theme.defaultFont.family
            font.bold: true
            font.pixelSize: textRep.numberSize
        }

        Text {
            id: percent
            text: "%"
            visible: !root.hasError
            anchors.baseline: number.baseline
            color: number.color
            font.family: number.font.family
            font.bold: true
            font.pixelSize: Math.max(6, textRep.numberSize / 2)
        }

    }
}
