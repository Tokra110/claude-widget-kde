// Tests for contents/ui/peak.js (the peak-hours clock). Run: node tools/test_peak.js
"use strict"
const fs = require("fs")
const path = require("path")
const assert = require("assert")

const src = fs.readFileSync(path.join(__dirname, "../contents/ui/peak.js"), "utf8").replace(/^\.pragma library\s*/m, "")
const peak = new Function(src + "\nreturn { pacificOffsetHours, levelAt, status, nextPeakWindow, usClock, duration, countdown }")()
const utc = (s) => Date.parse(s + "Z")
let n = 0
function eq(actual, expected, what) { assert.deepStrictEqual(actual, expected, what); n++ }

// US clocks 2026: summer time from 8 March 10:00 UTC to 1 November 09:00 UTC
eq(peak.pacificOffsetHours(utc("2026-03-08T09:59:59")), -8, "before spring change")
eq(peak.pacificOffsetHours(utc("2026-03-08T10:00:00")), -7, "spring change")
eq(peak.pacificOffsetHours(utc("2026-11-01T08:59:59")), -7, "before autumn change")
eq(peak.pacificOffsetHours(utc("2026-11-01T09:00:00")), -8, "autumn change")
eq(peak.pacificOffsetHours(utc("2027-03-14T10:00:00")), -7, "2027 starts on 14 March")

// Winter (PST, UTC-8): peak is 13:00-19:00 UTC on Monday 16 November 2026
eq(peak.levelAt(utc("2026-11-16T11:59:00")), "calm", "03:59 PT")
eq(peak.levelAt(utc("2026-11-16T12:00:00")), "busy", "04:00 PT")
eq(peak.levelAt(utc("2026-11-16T12:59:59")), "busy", "04:59 PT")
eq(peak.levelAt(utc("2026-11-16T13:00:00")), "peak", "05:00 PT")
eq(peak.levelAt(utc("2026-11-16T18:59:59")), "peak", "10:59 PT")
eq(peak.levelAt(utc("2026-11-16T19:00:00")), "busy", "11:00 PT")
eq(peak.levelAt(utc("2026-11-17T00:59:59")), "busy", "16:59 PT")
eq(peak.levelAt(utc("2026-11-17T01:00:00")), "calm", "17:00 PT")

// Summer (PDT, UTC-7): one hour earlier against UTC
eq(peak.levelAt(utc("2026-07-15T11:59:00")), "busy", "04:59 PDT")
eq(peak.levelAt(utc("2026-07-15T12:00:00")), "peak", "05:00 PDT")
eq(peak.levelAt(utc("2026-07-15T17:59:00")), "peak", "10:59 PDT")
eq(peak.levelAt(utc("2026-07-15T18:00:00")), "busy", "11:00 PDT")

// Weekend: calm all day, by the Pacific weekday (Friday evening UTC is still Friday there)
eq(peak.levelAt(utc("2026-11-14T15:00:00")), "calm", "Saturday morning PT")
eq(peak.levelAt(utc("2026-11-14T00:59:00")), "busy", "Friday 16:59 PT")
eq(peak.levelAt(utc("2026-11-16T07:00:00")), "calm", "Sunday 23:00 PT")

// Status: next change and when
eq(peak.status(utc("2026-11-15T10:00:00")), { level: "calm", next: "busy", changesAt: utc("2026-11-16T12:00:00") }, "Sunday to Monday 04:00 PT")
eq(peak.status(utc("2026-11-16T14:30:00")), { level: "peak", next: "busy", changesAt: utc("2026-11-16T19:00:00") }, "in peak")
eq(peak.status(utc("2026-11-16T12:10:00")), { level: "busy", next: "peak", changesAt: utc("2026-11-16T13:00:00") }, "before peak")

// Peak window: during it, and the next one from a weekend
const w1 = peak.nextPeakWindow(utc("2026-11-16T15:20:00"))
eq([w1.start.getTime(), w1.end.getTime()], [utc("2026-11-16T13:00:00"), utc("2026-11-16T19:00:00")], "current window")
const w2 = peak.nextPeakWindow(utc("2026-11-14T12:00:00"))
eq([w2.start.getTime(), w2.end.getTime()], [utc("2026-11-16T13:00:00"), utc("2026-11-16T19:00:00")], "next window after the weekend")

// Clock text and durations
eq(peak.usClock(utc("2026-11-16T13:05:00")), "05:05", "PT in winter")
eq(peak.usClock(utc("2026-11-16T13:05:00"), true), "08:05", "ET in winter")
eq(peak.usClock(utc("2026-07-15T12:00:00")), "05:00", "PT in summer")
eq(peak.duration(45 * 60000), "45m", "minutes")
eq(peak.duration((3 * 60 + 46) * 60000), "3h 46m", "hours")
eq(peak.duration((27 * 60 + 10) * 60000), "1d 3h", "days")

// Eastern changes clocks 3 hours before Pacific (both at 02:00 local)
eq(peak.usClock(utc("2026-11-01T05:30:00"), true), "01:30", "ET still summer")
eq(peak.usClock(utc("2026-11-01T06:30:00"), true), "01:30", "ET back to winter")
eq(peak.usClock(utc("2026-11-01T06:30:00")), "23:30", "PT still summer")
eq(peak.usClock(utc("2026-03-08T07:30:00"), true), "03:30", "ET spring change")

// Countdown line: Monday 16 November 2026, peak 13:00-19:00 UTC
eq(peak.countdown(utc("2026-11-16T11:30:00")), "Peak in 1h 30m", "before the peak")
eq(peak.countdown(utc("2026-11-16T15:20:00")), "Peak ends in 3h 40m", "inside the peak")
eq(peak.countdown(utc("2026-11-16T19:00:00")), "Peak in 18h 0m", "right after the peak")
eq(peak.countdown(utc("2026-11-14T12:00:00")), "Peak in 2d 1h", "Saturday: Monday's peak")

console.log("peak.js: " + n + " checks OK")
