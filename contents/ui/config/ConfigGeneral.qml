import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM
import org.kde.kquickcontrols as KQC

// Settings in five sections: Panel, Popup, Warning levels, Colors, Account.
KCM.SimpleKCM {
    id: configGeneral

    property alias cfg_pollInterval: pollIntervalSpinBox.value
    property alias cfg_warningThreshold: warningSpinBox.value
    property alias cfg_criticalThreshold: criticalSpinBox.value
    property string cfg_compactStyle
    property string cfg_compactMetric
    property string cfg_gaugeInnerMetric
    property string cfg_gaugeLabel
    property alias cfg_showPace: paceCheck.checked
    property alias cfg_showPeakClock: peakCheck.checked
    property string cfg_hiddenLimits
    property string cfg_knownWeeklyLimits
    property string cfg_normalColorLight
    property string cfg_normalColorDark
    property string cfg_warningColor
    property string cfg_textColorMode
    property string cfg_textColorLight
    property string cfg_textColorDark
    property alias cfg_autoRefreshToken: autoRefreshCheck.checked
    property alias cfg_showCostTab: costTabCheck.checked
    property string cfg_costStartPeriod
    property string cfg_lastCostPeriod
    property string cfg_claudeFolder

    // Defaults injected by Plasma config system
    property var cfg_pollIntervalDefault
    property var cfg_warningThresholdDefault
    property var cfg_criticalThresholdDefault
    property var cfg_compactStyleDefault
    property var cfg_compactMetricDefault
    property var cfg_gaugeInnerMetricDefault
    property var cfg_gaugeLabelDefault
    property var cfg_showPaceDefault
    property var cfg_showPeakClockDefault
    property var cfg_hiddenLimitsDefault
    property var cfg_knownWeeklyLimitsDefault
    property var cfg_normalColorLightDefault
    property var cfg_normalColorDarkDefault
    property var cfg_warningColorDefault
    property var cfg_textColorModeDefault
    property var cfg_textColorLightDefault
    property var cfg_textColorDarkDefault
    property var cfg_autoRefreshTokenDefault
    property var cfg_showCostTabDefault
    property var cfg_costStartPeriodDefault
    property var cfg_lastCostPeriodDefault
    property var cfg_claudeFolderDefault

    readonly property var styleModel: [
        { value: "text", label: "Percentage only" },
        { value: "bars", label: "Bars" },
        { value: "gauge", label: "Gauge" }
    ]
    readonly property var gaugeLabelModel: [
        { value: "time", label: "Time until reset" },
        { value: "percent", label: "Percentage" },
        { value: "none", label: "No label" }
    ]
    readonly property var metricModel: [
        { value: "five_hour", label: "5-hour" },
        { value: "seven_day", label: "Weekly · all models" },
        { value: "model_weekly", label: "Weekly · top model" }
    ]
    readonly property var textColorModel: [
        { value: "usage", label: "By usage level" },
        { value: "theme", label: "Panel text color" },
        { value: "custom", label: "Custom" }
    ]
    readonly property var innerMetricModel: [
        { value: "none", label: "None" }
    ].concat(metricModel)
    readonly property var startPeriodModel: [
        { value: "today", label: "Today" },
        { value: "last", label: "Last used period" }
    ]

    // Every limit the popup can show: the two fixed ones, then the scoped
    // weekly limits the widget saw in its last reply.
    readonly property var limitChoices: {
        var out = [{ key: "five_hour", name: "5-hour" }, { key: "seven_day", name: "Weekly · all models" }]
        var known = []
        try { known = JSON.parse(cfg_knownWeeklyLimits || "[]") } catch (e) {}
        for (var i = 0; i < known.length; i++) out.push({ key: known[i].key, name: "Weekly · " + known[i].name })
        return out
    }
    readonly property var hiddenList: cfg_hiddenLimits ? cfg_hiddenLimits.split(",") : []
    function setHidden(key, hidden) {
        var list = hiddenList.filter(function (k) { return k && k !== key })
        if (hidden) list.push(key)
        cfg_hiddenLimits = list.join(",")
    }

    function indexOf(model, value) {
        for (var i = 0; i < model.length; i++) {
            if (model[i].value === value) return i
        }
        return 0
    }

    // A grey line under a setting that needs a word of explanation.
    component Hint: QQC2.Label {
        Layout.maximumWidth: Kirigami.Units.gridUnit * 18
        font: Kirigami.Theme.smallFont
        opacity: 0.7
        wrapMode: Text.Wrap
    }

    Kirigami.FormLayout {

        // --- Panel ---
        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: "Panel"
        }

        QQC2.ComboBox {
            Kirigami.FormData.label: "Style:"
            model: configGeneral.styleModel
            textRole: "label"
            currentIndex: configGeneral.indexOf(model, cfg_compactStyle)
            onActivated: cfg_compactStyle = model[currentIndex].value
        }

        QQC2.ComboBox {
            Kirigami.FormData.label: "Shows:"
            model: configGeneral.metricModel
            textRole: "label"
            visible: cfg_compactStyle === "gauge" || cfg_compactStyle === "text"
            currentIndex: configGeneral.indexOf(model, cfg_compactMetric)
            onActivated: cfg_compactMetric = model[currentIndex].value
        }

        QQC2.ComboBox {
            Kirigami.FormData.label: "Inner ring:"
            model: configGeneral.innerMetricModel
            textRole: "label"
            visible: cfg_compactStyle === "gauge"
            currentIndex: configGeneral.indexOf(model, cfg_gaugeInnerMetric)
            onActivated: cfg_gaugeInnerMetric = model[currentIndex].value
        }

        QQC2.ComboBox {
            Kirigami.FormData.label: "Gauge label:"
            model: configGeneral.gaugeLabelModel
            textRole: "label"
            visible: cfg_compactStyle === "gauge"
            currentIndex: configGeneral.indexOf(model, cfg_gaugeLabel)
            onActivated: cfg_gaugeLabel = model[currentIndex].value
        }

        QQC2.ComboBox {
            Kirigami.FormData.label: "Text color:"
            model: configGeneral.textColorModel
            textRole: "label"
            visible: cfg_compactStyle === "text"
            currentIndex: configGeneral.indexOf(model, cfg_textColorMode)
            onActivated: cfg_textColorMode = model[currentIndex].value
        }

        KQC.ColorButton {
            Kirigami.FormData.label: "On a dark panel:"
            visible: cfg_compactStyle === "text" && cfg_textColorMode === "custom"
            color: cfg_textColorDark
            onColorChanged: if (String(color) !== cfg_textColorDark) cfg_textColorDark = String(color)
        }

        KQC.ColorButton {
            Kirigami.FormData.label: "On a light panel:"
            visible: cfg_compactStyle === "text" && cfg_textColorMode === "custom"
            color: cfg_textColorLight
            onColorChanged: if (String(color) !== cfg_textColorLight) cfg_textColorLight = String(color)
        }

        // --- Popup ---
        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: "Popup"
        }

        Repeater {
            model: configGeneral.limitChoices
            QQC2.CheckBox {
                Kirigami.FormData.label: index === 0 ? "Limits:" : ""
                text: modelData.name
                checked: configGeneral.hiddenList.indexOf(modelData.key) < 0
                onToggled: configGeneral.setHidden(modelData.key, !checked)
            }
        }

        QQC2.CheckBox {
            id: paceCheck
            Kirigami.FormData.label: "Show:"
            text: "Pace against the weekly limits"
        }

        QQC2.CheckBox {
            id: peakCheck
            text: "Peak hours clock"
        }

        QQC2.CheckBox {
            id: costTabCheck
            text: "Cost tab"
        }
        Hint {
            visible: costTabCheck.checked
            text: "It keeps a cache of your session logs (tens of MB). Turning it off deletes the cache."
        }

        QQC2.ComboBox {
            Kirigami.FormData.label: "Cost tab opens on:"
            model: configGeneral.startPeriodModel
            textRole: "label"
            visible: costTabCheck.checked
            currentIndex: configGeneral.indexOf(model, cfg_costStartPeriod)
            onActivated: cfg_costStartPeriod = model[currentIndex].value
        }

        // --- Warning levels ---
        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: "Warning levels"
        }

        QQC2.SpinBox {
            id: warningSpinBox
            Kirigami.FormData.label: "Warning from (%):"
            from: 10
            to: criticalSpinBox.value
            stepSize: 5
        }

        QQC2.SpinBox {
            id: criticalSpinBox
            Kirigami.FormData.label: "Critical from (%):"
            from: warningSpinBox.value
            to: 100
            stepSize: 5
        }

        // --- Colors ---
        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: "Colors"
        }

        KQC.ColorButton {
            Kirigami.FormData.label: "Normal, dark panel:"
            color: cfg_normalColorDark
            onColorChanged: if (String(color) !== cfg_normalColorDark) cfg_normalColorDark = String(color)
        }

        KQC.ColorButton {
            Kirigami.FormData.label: "Normal, light panel:"
            color: cfg_normalColorLight
            onColorChanged: if (String(color) !== cfg_normalColorLight) cfg_normalColorLight = String(color)
        }

        KQC.ColorButton {
            Kirigami.FormData.label: "Warning:"
            color: cfg_warningColor
            onColorChanged: if (String(color) !== cfg_warningColor) cfg_warningColor = String(color)
        }
        Hint {
            text: "The widget picks the dark or light color to match the panel it sits on. Critical uses the theme's red."
        }

        // --- Account ---
        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: "Account"
        }

        QQC2.TextField {
            Kirigami.FormData.label: "Claude folder:"
            placeholderText: "~/.claude (default)"
            implicitWidth: Kirigami.Units.gridUnit * 18
            text: cfg_claudeFolder
            onTextChanged: cfg_claudeFolder = text
        }

        QQC2.CheckBox {
            id: autoRefreshCheck
            Kirigami.FormData.label: "Sign-in:"
            text: "Renew it automatically when it expires"
        }

        QQC2.SpinBox {
            id: pollIntervalSpinBox
            Kirigami.FormData.label: "Update at most every (s):"
            from: 30
            to: 3600
            stepSize: 30
        }
        Hint {
            text: "While Claude Code works on this computer, the widget updates once per gap; when it is idle, every third gap."
        }
    }
}
