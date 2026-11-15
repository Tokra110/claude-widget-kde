import QtQuick
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as Plasma5Support

PlasmoidItem {
    id: root

    // --- Usage data properties ---
    property real fiveHourUtil: 0
    property string fiveHourResets: ""
    property real sevenDayUtil: 0
    property string sevenDayResets: ""
    // Scoped weekly limits, discovered dynamically from the API's `limits` array
    // (or the legacy `seven_day_*` fields it replaced), so a new plan tier shows
    // up without an update. Each entry: { key, name, label, util, resets }.
    property var weeklyModels: []
    property bool hasError: false
    property string errorMessage: ""
    // The stored sign-in is dead (refresh token expired or revoked), so only a
    // new `claude auth login` helps. The refresh button starts it in this state.
    property bool needsLogin: false
    // "desktop" when fetch_usage.py fell back to the numbers the Claude desktop
    // app records, because the CLI sign-in could not be used; sourceNote says why.
    property string dataSource: "api"
    property string sourceNote: ""
    // Period picked on the Cost tab. Each time the popup opens it starts on
    // Today, or on the last pick when the setting says so.
    property string costPeriod: "today"
    function startCostPeriod() {
        return plasmoid.configuration.costStartPeriod === "last"
            ? (plasmoid.configuration.lastCostPeriod || "today") : "today"
    }
    onCostPeriodChanged: plasmoid.configuration.lastCostPeriod = costPeriod
    onExpandedChanged: if (expanded) costPeriod = startCostPeriod()
    Component.onCompleted: costPeriod = startCostPeriod()
    property bool loginInFlight: false
    property bool loading: true
    property date lastUpdated: new Date(0)
    // True once a reply with numbers arrived; until then the popup shows no
    // bars (not a row of 0 %) and no "Updated" time.
    property bool hasData: false
    property bool hasFiveHour: true

    // --- Extra usage ---
    property bool hasExtraUsage: false
    property bool extraUsageEnabled: false
    property real extraUsageUtil: 0
    property string extraUsageLimit: ""
    property string extraUsageUsed: ""

    // --- Cache state ---
    property bool dataCached: false

    // --- Clock ---
    // Ticks so the countdowns and the pace marker keep up between polls: polls are
    // 15 minutes apart and resets_at does not change within a window, so before
    // this existed no binding on formatResetTime ever re-evaluated.
    property date now: new Date()

    readonly property int weeklyWindowMs: 7 * 24 * 60 * 60 * 1000

    // --- Activity monitor state ---
    property real lastActivityMtime: 0
    // Claude wrote to a session log since the last fetch.
    property bool activeSinceFetch: false
    // With no Claude work on this computer, the numbers change only from other
    // devices, so polls are this many intervals apart.
    readonly property int idlePollFactor: 3
    // Qt timers can fire a little early; this keeps a poll that is due from
    // being skipped as "too soon".
    readonly property int timerSlackMs: 5000

    // --- Rate limiting ---
    property real lastFetchTime: 0
    // The poll interval is also the smallest gap between automatic fetches,
    // so a 5-minute setting is never more than one fetch in 5 minutes.
    // Rate limiting doubles the gap, up to 4 intervals.
    property int backoffMultiplier: 1
    property int maxBackoffMultiplier: 4
    property bool fetchInFlight: false

    // --- Config ---
    readonly property int pollInterval: plasmoid.configuration.pollInterval * 1000
    // How often to look for new Claude Code activity on this computer.
    readonly property int activityCheckInterval: 30000
    readonly property int warningThreshold: plasmoid.configuration.warningThreshold
    readonly property int criticalThreshold: plasmoid.configuration.criticalThreshold
    readonly property string claudeFolder: plasmoid.configuration.claudeFolder
    readonly property bool costTabEnabled: plasmoid.configuration.showCostTab
    readonly property var hiddenLimits: plasmoid.configuration.hiddenLimits.split(",")
    function limitShown(key) {
        return root.hiddenLimits.indexOf(key) < 0
    }

    // --- Compact gauge computed properties ---
    readonly property string compactMetric: plasmoid.configuration.compactMetric
    // Picks the most-utilized active model-specific weekly, or an empty stub.
    readonly property var topWeeklyModel: {
        var top = { util: 0, resets: "" }
        for (var i = 0; i < weeklyModels.length; i++) {
            if (weeklyModels[i].util > top.util) top = weeklyModels[i]
        }
        return top
    }
    // Anything unrecognised, including a config value left over from an older
    // release, falls back to the 5-hour window.
    readonly property string outerMetric: (compactMetric === "seven_day" || compactMetric === "model_weekly")
        ? compactMetric : "five_hour"
    readonly property real compactUtil: metricUtil(outerMetric)
    readonly property string compactResets: metricResets(outerMetric)
    readonly property color compactColor: usageColor(compactUtil)

    // --- Inner gauge ring ---
    readonly property string innerMetric: plasmoid.configuration.gaugeInnerMetric
    readonly property real innerUtil: metricUtil(innerMetric)
    readonly property string innerResets: metricResets(innerMetric)
    readonly property color innerColor: usageColor(innerUtil)
    // Nothing to gain from drawing the same number twice, and the default metric
    // only exists for accounts that actually have a scoped weekly limit.
    readonly property bool hasInnerRing: innerMetric !== "none"
        && innerMetric !== outerMetric
        && metricHasData(innerMetric)

    // Metric resolution shared by both gauge rings.
    function metricUtil(metric) {
        if (metric === "five_hour") return fiveHourUtil
        if (metric === "seven_day") return sevenDayUtil
        if (metric === "model_weekly") return topWeeklyModel.util
        return 0
    }

    function metricResets(metric) {
        if (metric === "five_hour") return fiveHourResets
        if (metric === "seven_day") return sevenDayResets
        if (metric === "model_weekly") return topWeeklyModel.resets
        return ""
    }

    function metricHasData(metric) {
        return metricUtil(metric) > 0 || metricResets(metric) !== ""
    }

    // --- Executable DataSource ---
    Plasma5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            var stdout = data["stdout"]
            root.parseUsageData(stdout)
            disconnectSource(sourceName)
        }
        function exec(cmd) {
            if (cmd) connectSource(cmd)
        }
    }

    // The fetch script is what decides which Claude folder to read, so the
    // activity check runs through it too — otherwise an auto-detected folder
    // would fetch fine but never notice a new session.
    // The executable engine runs commands through /bin/sh, so every value is
    // put in single quotes: a folder setting with quotes, $ or backticks stays
    // one plain argument.
    function shellQuote(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'"
    }

    // "python3 -I '<widget>/contents/scripts/<name>' 'arg' ...", with the
    // Claude folder setting as the last argument when it is set.
    function pythonCommand(name, args) {
        var path = decodeURIComponent(Qt.resolvedUrl("../scripts/" + name).toString().replace(/^file:\/\//, ""))
        var all = (args || []).slice()
        var folder = root.claudeFolder.trim()
        if (folder) all.push(folder)
        var cmd = "python3 -I " + root.shellQuote(path)
        for (var i = 0; i < all.length; i++) cmd += " " + root.shellQuote(all[i])
        return cmd
    }

    function usageCommand(activity) {
        var args = []
        if (activity) args.push("--activity")
        if (!plasmoid.configuration.autoRefreshToken) args.push("--no-refresh")
        return root.pythonCommand("fetch_usage.py", args)
    }

    function fetchUsage() {
        root.fetchInFlight = true
        root.loading = true
        root.lastFetchTime = Date.now()
        root.activeSinceFetch = false
        fetchTimeoutTimer.restart()
        executable.exec(root.usageCommand(false))
    }

    // --- Cost tab cache ---
    // A while after start, count the session logs once in the background
    // (low priority), so the first look at the Cost tab reads only new lines.
    // Turning the Cost tab off deletes that cache, so nothing is left behind.
    Plasma5Support.DataSource {
        id: costCacheRunner
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => disconnectSource(sourceName)
    }

    function costCacheCommand(mode) {
        // Low priority: the first count reads every session log once.
        return "nice -n 10 " + root.pythonCommand("cost_report.py", [mode])
    }

    Timer {
        id: costWarmTimer
        interval: 20000
        running: root.costTabEnabled
        repeat: false
        onTriggered: costCacheRunner.connectSource(root.costCacheCommand("--warm"))
    }

    onCostTabEnabledChanged: {
        if (!costTabEnabled) costCacheRunner.connectSource(root.costCacheCommand("--wipe"))
        else costWarmTimer.restart()
    }

    // --- Sign-in DataSource ---
    // login.py opens a terminal with `claude auth login` and returns once that
    // window closes; then the widget fetches again with the new sign-in.
    Plasma5Support.DataSource {
        id: loginRunner
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            disconnectSource(sourceName)
            root.loginInFlight = false
            var reply = {}
            try { reply = JSON.parse(data["stdout"]) } catch (e) {}
            if (reply.error) {
                root.hasError = true
                root.errorMessage = reply.error
                return
            }
            root.requestFetch("manual")
        }
    }

    function startLogin() {
        if (root.loginInFlight) return
        var cmd = root.pythonCommand("login.py", [])
        root.loginInFlight = true
        root.errorMessage = "Finish the sign-in in the terminal window and the browser."
        loginRunner.connectSource(cmd)
    }

    // What the refresh button does: fetch again, or sign in again first when
    // the last fetch said the stored sign-in is dead.
    function heal() {
        if (root.needsLogin) root.startLogin()
        else root.requestFetch("manual")
    }

    function requestFetch(source) {
        if (root.fetchInFlight) return

        var bypass = (source === "startup" || source === "manual")
        if (!bypass) {
            var elapsed = Date.now() - root.lastFetchTime
            var gap = root.pollInterval * root.backoffMultiplier
            if (source === "poll" && !root.activeSinceFetch) gap = Math.max(gap, root.pollInterval * root.idlePollFactor)
            if (elapsed < gap - root.timerSlackMs) return
        }

        pollTimer.restart()
        root.fetchUsage()
    }

    function parseUsageData(stdout) {
        fetchTimeoutTimer.stop()
        root.fetchInFlight = false
        root.loading = false
        try {
            var data = JSON.parse(stdout)
            if (data.error) {
                root.hasError = true
                root.needsLogin = (data.error === "login_required")
                root.errorMessage = data.message || data.error
                return
            }
            root.hasError = false
            root.hasData = true
            root.needsLogin = !!data.needs_login
            root.errorMessage = ""
            root.dataSource = data.source || "api"
            root.sourceNote = data.source_note || ""

            var limits = Array.isArray(data.limits) ? data.limits : []

            // The fixed windows have their own top-level fields and are also
            // listed in `limits`. The dedicated fields keep float precision
            // (`limits[].percent` is a rounded int) so they win where present,
            // and `limits` only stands in if one of them goes away.
            var sessionLimit = root.findLimit(limits, "session")
            var weeklyAllLimit = root.findLimit(limits, "weekly_all")
            // Some plans (Ultra) have no 5-hour limit: then the bar goes away
            // instead of keeping an old number.
            root.hasFiveHour = !!(data.five_hour || sessionLimit)
            if (data.five_hour) {
                root.fiveHourUtil = data.five_hour.utilization || 0
                root.fiveHourResets = data.five_hour.resets_at || ""
            } else if (sessionLimit) {
                root.fiveHourUtil = sessionLimit.percent || 0
                root.fiveHourResets = sessionLimit.resets_at || ""
            } else {
                root.fiveHourUtil = 0
                root.fiveHourResets = ""
            }
            if (data.seven_day) {
                root.sevenDayUtil = data.seven_day.utilization || 0
                root.sevenDayResets = data.seven_day.resets_at || ""
            } else if (weeklyAllLimit) {
                root.sevenDayUtil = weeklyAllLimit.percent || 0
                root.sevenDayResets = weeklyAllLimit.resets_at || ""
            }

            var weeklies = []
            var seenKeys = {}

            // Every weekly that is not the all-models one is a scoped limit:
            // per model today (Fable), possibly per surface tomorrow.
            for (var i = 0; i < limits.length; i++) {
                var limit = limits[i]
                if (!limit || limit.group !== "weekly" || limit.kind === "weekly_all") continue
                // Deliberately not filtered on `is_active`: the API sets it on
                // the scoped entry while leaving it false on both fixed windows,
                // so it does not mean "this limit is live".
                var scopeName = root.scopeNameFor(limit.scope)
                var scopeUtil = limit.percent || 0
                var scopeResets = limit.resets_at || ""
                if (scopeUtil <= 0 && !scopeResets) continue
                var scopeKey = root.scopedKeyFor(scopeName)
                seenKeys[scopeKey] = true
                weeklies.push({
                    key: scopeKey,
                    name: scopeName,
                    // The API already supplies the right casing, so the label is
                    // built from the display name rather than from the key.
                    label: "Weekly · " + scopeName,
                    util: scopeUtil,
                    resets: scopeResets
                })
            }

            // Legacy per-model fields, all null since 2026-08 but cheap to keep
            // reading in case the shape moves again.
            for (var key in data) {
                if (key === "seven_day" || key.indexOf("seven_day_") !== 0) continue
                if (seenKeys[key]) continue
                var entry = data[key]
                if (!entry) continue
                var util = entry.utilization || 0
                var resets = entry.resets_at || ""
                if (util <= 0 && !resets) continue
                seenKeys[key] = true
                weeklies.push({
                    key: key,
                    name: root.weeklyNameFor(key),
                    label: root.weeklyLabelFor(key),
                    util: util,
                    resets: resets
                })
            }
            weeklies.sort(function (a, b) {
                if (b.util !== a.util) return b.util - a.util
                return a.key < b.key ? -1 : a.key > b.key ? 1 : 0
            })
            root.weeklyModels = weeklies
            // The settings page lists these, so they can be hidden one by one.
            var known = JSON.stringify(weeklies.map(function (w) { return { key: w.key, name: w.name } }))
            if (known !== plasmoid.configuration.knownWeeklyLimits) plasmoid.configuration.knownWeeklyLimits = known

            if (data.extra_usage) {
                root.hasExtraUsage = true
                var places = data.extra_usage.decimal_places != null ? data.extra_usage.decimal_places : 2
                var money = function (minor) {
                    return root.currencyText((minor || 0) / Math.pow(10, places), data.extra_usage.currency, places)
                }
                root.extraUsageEnabled = data.extra_usage.is_enabled || false
                root.extraUsageUtil = data.extra_usage.utilization || 0
                root.extraUsageLimit = data.extra_usage.monthly_limit != null ? money(data.extra_usage.monthly_limit) : ""
                root.extraUsageUsed = money(data.extra_usage.used_credits)
            } else {
                root.hasExtraUsage = false
                root.extraUsageEnabled = false
            }

            root.dataCached = !!data.cached
            if (data.rate_limited) {
                root.backoffMultiplier = Math.min(root.backoffMultiplier * 2, root.maxBackoffMultiplier)
            } else {
                root.backoffMultiplier = 1
            }

            if (data.cached && data._fetched_at) {
                root.lastUpdated = new Date(data._fetched_at * 1000)
            } else {
                root.lastUpdated = new Date()
            }
        } catch (e) {
            root.hasError = true
            root.errorMessage = "Failed to parse response"
        }
    }

    // --- Helper functions ---
    function weeklyNameFor(key) {
        var suffix = key.replace(/^seven_day_/, "")
        var parts = suffix.split("_")
        for (var i = 0; i < parts.length; i++) {
            parts[i] = parts[i].charAt(0).toUpperCase() + parts[i].slice(1)
        }
        return parts.join(" ")
    }

    function weeklyLabelFor(key) {
        return "Weekly · " + root.weeklyNameFor(key)
    }

    // Canonical key for a scoped limit, so `limits` entries dedupe against
    // legacy `seven_day_*` keys and sort with the same tiebreak.
    function scopedKeyFor(displayName) {
        return "seven_day_" + displayName.toLowerCase().replace(/[^a-z0-9]+/g, "_")
    }

    // What to call a scoped limit. `surface` comes as a bare string in some
    // responses and as an object shaped like `model` in others.
    function scopeNameFor(scope) {
        if (scope) {
            if (scope.model) {
                if (scope.model.display_name) return scope.model.display_name
                if (scope.model.id) return scope.model.id
            }
            if (scope.surface) {
                if (typeof scope.surface === "string") return scope.surface
                if (scope.surface.display_name) return scope.surface.display_name
                if (scope.surface.id) return scope.surface.id
            }
        }
        return "Scoped"
    }

    // First entry in the API's `limits` array of the given kind, or null.
    function findLimit(limits, kind) {
        for (var i = 0; i < limits.length; i++) {
            if (limits[i] && limits[i].kind === kind) return limits[i]
        }
        return null
    }

    function usageColor(percent) {
        if (percent >= root.criticalThreshold) {
            return Kirigami.Theme.negativeTextColor
        } else if (percent >= root.warningThreshold) {
            return plasmoid.configuration.warningColor || "#E5C07B"
        } else {
            // Normal bars carry a separate colour per theme, so white can stay on
            // a dark panel while a light panel gets a tint that is still visible.
            return root.normalColorForTheme
        }
    }

    // Whether the surface these bars sit on is dark. In the popup this is the
    // applet's own theme; the compact bars read their tray theme through the same
    // property because usageColor is always called on root.
    readonly property bool onDarkSurface: Kirigami.ColorUtils.brightnessForColor(
        Kirigami.Theme.backgroundColor) === Kirigami.ColorUtils.Dark
    readonly property color normalColorForTheme: root.onDarkSurface
        ? (plasmoid.configuration.normalColorDark || "#ffffff")
        : (plasmoid.configuration.normalColorLight || "#D77757")

    // "€12.50", "$3.00", or "12.50 CHF" for a currency without a short sign.
    function currencyText(amount, code, places) {
        var signs = { "USD": "$", "EUR": "€", "GBP": "£", "JPY": "¥" }
        var c = code ? String(code).toUpperCase() : "USD"
        var n = amount.toFixed(places)
        return signs[c] ? signs[c] + n : n + " " + c
    }

    // Empty without a time, "ended" once it has passed (until the next fetch
    // brings the new window), else "3h 46m", "45m" or "1d 3h".
    function formatResetTime(isoString) {
        if (!isoString) return ""
        var d = new Date(isoString)
        var now = root.now
        var diffMs = d.getTime() - now.getTime()
        if (diffMs <= 0) return "ended"
        var diffMin = Math.floor(diffMs / 60000)
        var diffHrs = Math.floor(diffMin / 60)
        var remainMin = diffMin % 60
        if (diffHrs >= 24) {
            var days = Math.floor(diffHrs / 24)
            var hrs = diffHrs % 24
            return days + "d " + hrs + "h"
        }
        if (diffHrs > 0) return diffHrs + "h " + remainMin + "m"
        return diffMin + "m"
    }

    // Fraction 0..1 of a window that has elapsed, or -1 when it cannot be known.
    // The API sends no window start, but both windows are a fixed length, so the
    // start is resets_at minus that length.
    function paceFraction(resetsAt, windowMs) {
        if (!resetsAt || !windowMs) return -1
        var end = new Date(resetsAt).getTime()
        if (isNaN(end)) return -1
        var elapsed = windowMs - (end - root.now.getTime())
        // Unknown, rather than pinned to an edge: over a window elapsed means the
        // reset is already past (stale payload, or no session in the last 5h), and
        // under zero means it is more than a whole window out (clock skew).
        if (elapsed < 0 || elapsed > windowMs) return -1
        return elapsed / windowMs
    }

    // --- Activity monitor DataSource ---
    Plasma5Support.DataSource {
        id: activityChecker
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            var stdout = data["stdout"].trim()
            var mtime = parseInt(stdout)
            if (!isNaN(mtime)) {
                if (root.lastActivityMtime > 0 && mtime > root.lastActivityMtime) {
                    root.activeSinceFetch = true
                    // Fetch soon only when the last fetch is a full interval
                    // old; otherwise the next poll picks the work up.
                    if (Date.now() - root.lastFetchTime >= root.pollInterval * root.backoffMultiplier - root.timerSlackMs)
                        fetchDelayTimer.restart()
                }
                root.lastActivityMtime = mtime
            }
            disconnectSource(sourceName)
        }
        function check() {
            connectSource(root.usageCommand(true))
        }
    }

    // --- Activity check timer ---
    Timer {
        id: activityTimer
        interval: root.activityCheckInterval
        running: true
        repeat: true
        onTriggered: activityChecker.check()
        Component.onCompleted: activityChecker.check()
    }

    // --- Fetch timeout recovery ---
    Timer {
        id: fetchTimeoutTimer
        interval: 30000
        running: false
        repeat: false
        onTriggered: {
            executable.disconnectSource(root.usageCommand(false))
            root.fetchInFlight = false
            root.loading = false
            root.hasError = true
            root.errorMessage = "Request timed out"
        }
    }

    // --- Delay before fetching after activity ---
    Timer {
        id: fetchDelayTimer
        interval: 15000
        running: false
        repeat: false
        onTriggered: root.requestFetch("activity")
    }

    // --- Clock tick ---
    // 30s is well under 1% of a 5-hour window and costs one date assignment.
    Timer {
        id: clockTimer
        interval: 30000
        running: true
        repeat: true
        onTriggered: root.now = new Date()
    }

    // --- Polling timer ---
    Timer {
        id: pollTimer
        interval: root.pollInterval
        running: true
        repeat: true
        onTriggered: root.requestFetch("poll")
        Component.onCompleted: root.requestFetch("startup")
    }

    // --- Widget setup ---
    switchWidth: Kirigami.Units.gridUnit * 12
    switchHeight: Kirigami.Units.gridUnit * 8

    // Short hover text: only the limits the panel item does not already show,
    // one per line. Plasma skips the tooltip when both texts are empty.
    readonly property var shownMetrics: {
        var style = plasmoid.configuration.compactStyle
        if (style === "bars") return ["five_hour", "seven_day"]
        if (style === "gauge" && root.hasInnerRing) return [root.outerMetric, root.innerMetric]
        return [root.outerMetric]
    }
    function tipLine(label, util, resets) {
        var line = label + ": " + Math.round(util) + "%"
        var left = root.formatResetTime(resets)
        if (left && left !== "ended") line += ", resets in " + left
        return line
    }
    readonly property var hiddenLines: {
        if (root.hasError) return []
        var lines = []
        var shown = root.shownMetrics
        if (shown.indexOf("five_hour") < 0)
            lines.push(root.tipLine("5-hour", root.fiveHourUtil, root.fiveHourResets))
        if (shown.indexOf("seven_day") < 0)
            lines.push(root.tipLine("Weekly", root.sevenDayUtil, root.sevenDayResets))
        // A scoped weekly is shown only when it is the one model_weekly picks.
        for (var i = 0; i < root.weeklyModels.length; i++) {
            var m = root.weeklyModels[i]
            if (shown.indexOf("model_weekly") >= 0 && m === root.topWeeklyModel) continue
            lines.push(root.tipLine(m.label, m.util, m.resets))
        }
        return lines
    }
    toolTipMainText: hiddenLines.length > 0 ? hiddenLines[0] : ""
    toolTipSubText: hiddenLines.slice(1).join("\n")

    compactRepresentation: CompactRepresentation {}
    fullRepresentation: FullRepresentation {}
}
