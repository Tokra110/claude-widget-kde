.pragma library

// Claude's peak hours, as a pure function of the time, for the clock on the
// Limits tab. Sources and how sure each part is: README "Peak hours".
//
//   peak  (red)    weekdays 05:00-11:00 Pacific. Official (Anthropic, 26 March
//                  2026): the 5-hour limit drains faster for Free, Pro and Max.
//                  Since 6 May 2026 not for Claude Code on Pro and Max; still
//                  assumed for Claude chat (web, desktop, mobile) and Free.
//   busy   (yellow) weekdays 04:00-05:00 and 11:00-17:00 Pacific: the rest of
//                  the US working day. No official extra drain; anecdotal
//                  reports of slow answers and errors, whose retries can cost usage.
//   calm   (green) every other hour, and all weekend.
//
// The window is fixed to Pacific wall time, so it moves by an hour against
// UTC when US clocks change. Qt's JavaScript has no time zone database, so
// the US daylight saving rule is written out here.

var PEAK_START = 5
var PEAK_END = 11
var BUSY_START = 4
var BUSY_END = 17

// US daylight saving: from the second Sunday of March, 02:00 standard time
// (10:00 UTC), to the first Sunday of November, 02:00 daylight time (09:00 UTC).
function nthSundayUtc(year, month, n) {
    var first = new Date(Date.UTC(year, month, 1)).getUTCDay()
    return 1 + (7 - first) % 7 + 7 * (n - 1)
}

// Both zones change at 02:00 local time, so Eastern changes 3 hours earlier
// in UTC than Pacific: the US clocks are not always 3 hours apart.
function usOffsetHours(utcMs, standard) {
    var year = new Date(utcMs).getUTCFullYear()
    var start = Date.UTC(year, 2, nthSundayUtc(year, 2, 2), 2 - standard)
    var end = Date.UTC(year, 10, nthSundayUtc(year, 10, 1), 1 - standard)
    return utcMs >= start && utcMs < end ? standard + 1 : standard
}

function pacificOffsetHours(utcMs) {
    return usOffsetHours(utcMs, -8)
}

// Pacific wall time as fields: { day (0 = Sunday), hour, minute }.
function pacific(utcMs) {
    var d = new Date(utcMs + pacificOffsetHours(utcMs) * 3600000)
    return { day: d.getUTCDay(), hour: d.getUTCHours(), minute: d.getUTCMinutes() }
}

function levelAt(utcMs) {
    var p = pacific(utcMs)
    if (p.day === 0 || p.day === 6) return "calm"
    if (p.hour >= PEAK_START && p.hour < PEAK_END) return "peak"
    if (p.hour >= BUSY_START && p.hour < BUSY_END) return "busy"
    return "calm"
}

// The level now, the next level and when it starts (ms). Every border is on
// a whole Pacific hour, so it steps to the next hour start, then by hours.
function status(utcMs) {
    var level = levelAt(utcMs)
    var hour = 3600000
    var t = Math.floor(utcMs / hour) * hour + hour
    for (var i = 0; i < 8 * 24; i++, t += hour) {
        var next = levelAt(t)
        if (next !== level) return { level: level, next: next, changesAt: t }
    }
    return { level: level, next: level, changesAt: 0 }
}

// The peak window of the current or next weekday, as two Date objects, so the
// popup can show it in the computer's own time.
function nextPeakWindow(utcMs) {
    var hour = 3600000
    var t = Math.floor(utcMs / hour) * hour
    if (levelAt(t) === "peak") {
        while (levelAt(t - hour) === "peak") t -= hour
    } else {
        while (levelAt(t) !== "peak") t += hour
    }
    var end = t
    while (levelAt(end) === "peak") end += hour
    return { start: new Date(t), end: new Date(end) }
}

// "Peak in 1d 3h" outside the peak, "Peak ends in 2h 10m" inside it.
function countdown(utcMs) {
    var w = nextPeakWindow(utcMs)
    if (w.start.getTime() <= utcMs) return "Peak ends in " + duration(w.end.getTime() - utcMs)
    return "Peak in " + duration(w.start.getTime() - utcMs)
}

// "07:05" in US Pacific, or in Eastern.
function usClock(utcMs, eastern) {
    var d = new Date(utcMs + usOffsetHours(utcMs, eastern ? -5 : -8) * 3600000)
    var h = d.getUTCHours()
    var m = d.getUTCMinutes()
    return (h < 10 ? "0" : "") + h + ":" + (m < 10 ? "0" : "") + m
}

// "3h 46m", "45m", "1d 3h"
function duration(ms) {
    var min = Math.max(0, Math.round(ms / 60000))
    var d = Math.floor(min / 1440)
    var h = Math.floor(min % 1440 / 60)
    var m = min % 60
    if (d > 0) return d + "d " + h + "h"
    if (h > 0) return h + "h " + m + "m"
    return m + "m"
}
