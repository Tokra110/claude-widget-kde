import QtQuick
import QtQuick.Layouts

import org.kde.kirigami as Kirigami

MouseArea {
    id: compactRep

    Layout.minimumWidth: styleLoader.item ? styleLoader.item.Layout.minimumWidth : Kirigami.Units.gridUnit
    Layout.minimumHeight: styleLoader.item ? styleLoader.item.Layout.minimumHeight : Kirigami.Units.gridUnit
    Layout.preferredWidth: styleLoader.item ? styleLoader.item.Layout.preferredWidth : Layout.minimumWidth
    Layout.preferredHeight: styleLoader.item ? styleLoader.item.Layout.preferredHeight : Layout.minimumHeight

    onClicked: root.expanded = !root.expanded

    Loader {
        id: styleLoader
        anchors.fill: parent
        source: {
            var style = plasmoid.configuration.compactStyle
            if (style === "gauge") return "GaugeRepresentation.qml"
            if (style === "text") return "TextRepresentation.qml"
            return "BarsRepresentation.qml"
        }
    }

    Kirigami.Icon {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        width: Kirigami.Units.iconSizes.small
        height: width
        source: "data-warning"
        visible: root.hasError
        color: Kirigami.Theme.negativeTextColor
    }
}
