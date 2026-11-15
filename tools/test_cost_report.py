#!/usr/bin/env python3
"""Tests for contents/scripts/cost_report.py. Run: python3 tools/test_cost_report.py"""

import datetime as dt
import glob
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "contents", "scripts", "cost_report.py")
sys.path.insert(0, os.path.dirname(SCRIPT))
sys.dont_write_bytecode = True
import cost_report  # noqa: E402


def run_script(folder, *args, cache_home=None):
    """Run cost_report.py with its cache in a temp folder, never the real one."""
    env = dict(os.environ)
    own = None
    if cache_home is None:
        own = tempfile.TemporaryDirectory()
        cache_home = own.name
    env["XDG_CACHE_HOME"] = cache_home
    try:
        out = subprocess.run([sys.executable, "-I", SCRIPT, *args, folder], env=env,
                             capture_output=True, text=True, check=True).stdout
    finally:
        if own:
            own.cleanup()
    return with_totals(json.loads(out))


def cache_files(cache_home):
    return sorted(glob.glob(os.path.join(cache_home, "claude-widget-kde", "cost", "*.json")))


def with_totals(data):
    """Add each period's totals, summed from the cells as the popup does."""
    for p in data.get("periods", []):
        inside = [c for c in data["cells"] if p["start_day"] <= c[0] <= p["end_day"]]
        types = data["types"]
        cost = sum(c[2] for c in inside)
        days = len({c[0] for c in inside})
        p.update({
            "cost": round(cost, 2), "tokens": sum(c[3] for c in inside), "replies": sum(c[4] for c in inside),
            "active_days": days, "per_active_day": round(cost / days, 2) if days else 0,
            "by_type": {k: round(sum(c[5][i] for c in inside), 2) for i, k in enumerate(types)},
            "by_hour": [round(sum(c[6][h] for c in inside), 4) for h in range(24)],
        })
    return data


def reply(ts, model, usage, msg_id="m1", req="r1"):
    # Same key order and compact form as Claude Code's own log lines
    return json.dumps({"parentUuid": "p", "message": {"model": model, "id": msg_id, "role": "assistant",
                                                      "content": [], "usage": usage},
                       "requestId": req, "type": "assistant", "timestamp": ts}, separators=(",", ":"))


def iso(d):
    return d.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


class CostTests(unittest.TestCase):
    def test_plain_price(self):
        # opus 5.5: 4 in, 20 out per million
        cost, tokens = cost_report.entry_cost(cost_report.price_for("claude-opus-5-5"),
                                              {"input_tokens": 1_000_000, "output_tokens": 1_000_000})
        self.assertAlmostEqual(cost, 24.0)
        self.assertEqual(tokens, 2_000_000)

    def test_cache_split_and_read(self):
        usage = {"input_tokens": 0, "output_tokens": 0, "cache_read_input_tokens": 1_000_000,
                 "cache_creation_input_tokens": 2_000_000,
                 "cache_creation": {"ephemeral_5m_input_tokens": 1_000_000,
                                    "ephemeral_1h_input_tokens": 1_000_000}}
        cost, _ = cost_report.entry_cost(cost_report.price_for("claude-opus-5-5"), usage)
        # read 0.2 + 5m write 5 + 1h write 2 x 4 = 13.2
        self.assertAlmostEqual(cost, 13.2)

    def test_fast_doubles(self):
        cost, _ = cost_report.entry_cost(cost_report.price_for("claude-opus-5-5"),
                                         {"input_tokens": 1_000_000, "speed": "fast"})
        self.assertAlmostEqual(cost, 8.0)

    def test_long_context_tier_bills_whole_request(self):
        price = cost_report.price_for("claude-haiku-5-5")
        under, _ = cost_report.entry_cost(price, {"input_tokens": 100_000, "output_tokens": 1_000_000})
        over, _ = cost_report.entry_cost(price, {"input_tokens": 100_001, "output_tokens": 1_000_000})
        self.assertAlmostEqual(under, 0.01 + 0.5)
        self.assertAlmostEqual(over, 100_001 * 0.5 / 1e6 + 2.5)

    def test_longest_prefix_and_dated_names(self):
        self.assertEqual(cost_report.price_for("claude-opus-4-1-20250805")[0], 15)
        self.assertEqual(cost_report.price_for("claude-opus-4-5-20251101")[0], 5)
        self.assertEqual(cost_report.price_for("claude-haiku-4-5-20251001")[0], 1)
        self.assertEqual(cost_report.price_for("claude-fable-5-1")[2], 0.25)
        self.assertIsNone(cost_report.price_for("claude-unknown-9"))


class ReportTests(unittest.TestCase):
    def run_report(self, lines_by_file):
        with tempfile.TemporaryDirectory() as tmp:
            for name, lines in lines_by_file.items():
                path = os.path.join(tmp, "projects", name)
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "w") as f:
                    f.write("\n".join(lines) + "\n")
            data = run_script(tmp)
        return data, {p["key"]: p for p in data["periods"]}

    def test_dedupe_periods_and_unpriced(self):
        now = dt.datetime.now().astimezone()
        week_start = (now - dt.timedelta(days=now.weekday())).replace(hour=0, minute=0, second=0, microsecond=0)
        one = {"input_tokens": 1_000_000}  # $4 on opus 5.5
        data, p = self.run_report({
            "a/s1.jsonl": [
                reply(iso(now), "claude-opus-5-5", one, "today", "r"),
                # same reply written again (next content block) and in a resumed
                # session file below: counted once
                reply(iso(now), "claude-opus-5-5", one, "today", "r"),
                reply(iso(week_start - dt.timedelta(days=3)), "claude-opus-5-5", one, "lastweek", "r"),
                reply(iso(now - dt.timedelta(days=60)), "claude-opus-5-5", one, "old", "r"),
                reply(iso(now), "<synthetic>", one, "syn", "r"),
                reply(iso(now), "claude-new-model", {"input_tokens": 5}, "new", "r"),
                "not json",
                json.dumps({"type": "user", "message": {"content": "hi"}}),
            ],
            "b/sub/s2.jsonl": [reply(iso(now), "claude-opus-5-5", one, "today", "r")],
        })
        self.assertAlmostEqual(p["today"]["cost"], 4.0)
        self.assertEqual(p["today"]["replies"], 2)  # opus + the unpriced one
        self.assertAlmostEqual(p["last_week"]["cost"], 4.0)
        self.assertAlmostEqual(p["last_30"]["cost"], 8.0)
        self.assertAlmostEqual(p["last_90"]["cost"], 12.0)
        self.assertAlmostEqual(p["all"]["cost"], 12.0)
        self.assertEqual(data["unpriced"], ["claude-new-model"])
        self.assertEqual(data["files"], 2)
        # The popup sums the cells for its numbers: they must add up to each period.
        for key, period in p.items():
            inside = [c for c in data["cells"] if period["start_day"] <= c[0] <= period["end_day"]]
            self.assertAlmostEqual(sum(c[2] for c in inside), period["cost"], places=2, msg=key)
            self.assertEqual(sum(c[4] for c in inside), period["replies"], key)
            self.assertEqual(sum(c[3] for c in inside), period["tokens"], key)

    def test_chart_numbers(self):
        now = dt.datetime.now().astimezone()
        usage = {"input_tokens": 1_000_000, "output_tokens": 1_000_000,
                 "cache_read_input_tokens": 1_000_000,
                 "cache_creation": {"ephemeral_5m_input_tokens": 1_000_000,
                                    "ephemeral_1h_input_tokens": 0}}
        data, p = self.run_report({"a/s.jsonl": [
            reply(iso(now), "claude-opus-5-5", usage, "a", "r"),
            reply(iso(now - dt.timedelta(days=2)), "claude-sonnet-5-5", {"output_tokens": 1_000_000}, "b", "r"),
        ]})
        today = p["today"]
        self.assertEqual(today["by_type"], {"input": 4.0, "output": 20.0, "cache_write": 5.0, "cache_read": 0.2})
        self.assertAlmostEqual(today["by_hour"][now.hour], 29.2)
        self.assertAlmostEqual(sum(today["by_hour"]), 29.2)
        day = now.date().isoformat()
        self.assertEqual((today["start_day"], today["end_day"]), (day, day))
        # One cell per day and model, which the popup sums for its filters
        self.assertEqual(data["types"], ["input", "output", "cache_write", "cache_read"])
        self.assertEqual(data["cells_from"], "")
        cells = {(c[0], c[1]): c for c in data["cells"]}
        opus = cells[(day, "claude-opus-5-5")]
        self.assertEqual(opus[2:5], [29.2, 4_000_000, 1])
        self.assertEqual(opus[5], [4.0, 20.0, 5.0, 0.2])
        self.assertAlmostEqual(opus[6][now.hour], 29.2)
        sonnet = cells[((now - dt.timedelta(days=2)).date().isoformat(), "claude-sonnet-5-5")]
        self.assertEqual(sonnet[2], 10.0)
        last30 = p["last_30"]
        # whole calendar days: today and the 29 before
        self.assertEqual(last30["start_day"], (now.date() - dt.timedelta(days=29)).isoformat())
        self.assertEqual(last30["end_day"], day)
        self.assertAlmostEqual(last30["cost"], 39.2)
        self.assertEqual(last30["active_days"], 2)
        self.assertAlmostEqual(last30["per_active_day"], 19.6)
        week = p["this_week"]
        self.assertEqual(week["start_day"], (now.date() - dt.timedelta(days=now.weekday())).isoformat())
        # a fast count of today holds the cells of the last 7 days
        with tempfile.TemporaryDirectory() as tmp:
            os.makedirs(os.path.join(tmp, "projects", "a"))
            with open(os.path.join(tmp, "projects", "a", "s.jsonl"), "w") as f:
                f.write(reply(iso(now - dt.timedelta(days=10)), "claude-opus-5-5", usage, "x", "r") + "\n")
                f.write(reply(iso(now - dt.timedelta(days=2)), "claude-sonnet-5-5", {"output_tokens": 1_000_000}, "b", "r") + "\n")
            part = run_script(tmp, "--period", "today")
        self.assertEqual(part["cells_from"], (now.date() - dt.timedelta(days=6)).isoformat())
        self.assertEqual([c[1] for c in part["cells"]], ["claude-sonnet-5-5"])

    def test_single_period_matches_full_count(self):
        now = dt.datetime.now().astimezone()
        lines = [reply(iso(now - dt.timedelta(days=d)), "claude-opus-5-5",
                       {"input_tokens": 1_000_000}, "m%d" % d, "r") for d in (0, 3, 20, 60)]
        with tempfile.TemporaryDirectory() as tmp:
            os.makedirs(os.path.join(tmp, "projects", "a"))
            old = os.path.join(tmp, "projects", "a", "old.jsonl")
            new = os.path.join(tmp, "projects", "a", "new.jsonl")
            with open(old, "w") as f:
                f.write(lines[3] + "\n")
            with open(new, "w") as f:
                f.write("\n".join(lines[:3]) + "\n")
            month_ago = (now - dt.timedelta(days=59)).timestamp()
            os.utime(old, (month_ago, month_ago))
            cache_home = os.path.join(tmp, "cache")
            run = lambda *a: run_script(tmp, *a, cache_home=cache_home)
            full = {p["key"]: p for p in run()["periods"]}
            for key in ("today", "this_week", "last_week", "this_month", "last_30", "last_90", "all"):
                part = run("--period", key)
                self.assertTrue(part["partial"])
                self.assertEqual([p["key"] for p in part["periods"]], [key])
                self.assertEqual(part["periods"][0], full[key], key)
            # the old file is skipped unread for short periods
            self.assertEqual(run("--period", "last_30")["files"], 1)
            self.assertEqual(run("--period", "all")["files"], 2)

    def test_cache_reads_only_new_lines(self):
        now = dt.datetime.now().astimezone()
        one = {"input_tokens": 1_000_000}
        with tempfile.TemporaryDirectory() as tmp:
            cache_home = os.path.join(tmp, "cache")
            os.makedirs(os.path.join(tmp, "projects", "a"))
            log = os.path.join(tmp, "projects", "a", "s.jsonl")
            with open(log, "w") as f:
                f.write(reply(iso(now), "claude-opus-5-5", one, "a", "r") + "\n")
                # a line still being written: not counted yet, not lost later
                f.write(reply(iso(now), "claude-opus-5-5", one, "b", "r")[:40])
            total = lambda: {p["key"]: p for p in run_script(tmp, cache_home=cache_home)["periods"]}["all"]["cost"]
            self.assertAlmostEqual(total(), 4.0)
            self.assertEqual(len(cache_files(cache_home)), 1)
            self.assertAlmostEqual(total(), 4.0)  # from the cache
            with open(log, "a") as f:
                f.write(reply(iso(now), "claude-opus-5-5", one, "b", "r")[40:] + "\n")
                f.write(reply(iso(now), "claude-sonnet-5-5", {"output_tokens": 1_000_000}, "c", "r") + "\n")
            self.assertAlmostEqual(total(), 18.0)  # 4 + 4 + 10
            # a rewritten (shorter) file is read again from the start
            with open(log, "w") as f:
                f.write(reply(iso(now), "claude-opus-5-5", one, "z", "r") + "\n")
            self.assertAlmostEqual(total(), 4.0)
            # with a cache, the result equals a fresh count
            self.assertEqual(run_script(tmp, cache_home=cache_home)["periods"], run_script(tmp)["periods"])

    def test_warm_fills_cache_fast_count_does_not_save_and_wipe_deletes(self):
        now = dt.datetime.now().astimezone()
        with tempfile.TemporaryDirectory() as tmp:
            cache_home = os.path.join(tmp, "cache")
            os.makedirs(os.path.join(tmp, "projects", "a"))
            with open(os.path.join(tmp, "projects", "a", "s.jsonl"), "w") as f:
                f.write(reply(iso(now), "claude-opus-5-5", {"input_tokens": 1_000_000}) + "\n")
            out = run_script(tmp, "--period", "today", cache_home=cache_home)
            self.assertAlmostEqual(out["periods"][0]["cost"], 4.0)
            self.assertEqual(cache_files(cache_home), [])
            self.assertEqual(run_script(tmp, "--warm", cache_home=cache_home), {"warm": True, "files": 1})
            self.assertEqual(len(cache_files(cache_home)), 1)
            self.assertEqual(run_script(tmp, "--wipe", cache_home=cache_home), {"wiped": True})
            self.assertEqual(cache_files(cache_home), [])
            self.assertEqual(run_script(tmp, "--wipe", cache_home=cache_home), {"wiped": True})

    def test_copy_with_most_output_counts(self):
        now = dt.datetime.now().astimezone()
        early = reply(iso(now), "claude-opus-5-5", {"output_tokens": 10}, "m", "r")
        final = reply(iso(now), "claude-opus-5-5", {"output_tokens": 1_000_000}, "m", "r")
        _, p = self.run_report({"a/s.jsonl": [early, final, early]})
        self.assertAlmostEqual(p["all"]["cost"], 20.0)
        self.assertEqual(p["all"]["replies"], 1)

    def test_each_folder_has_its_own_cache_and_wipe_wins_over_a_running_count(self):
        now = dt.datetime.now().astimezone()
        with tempfile.TemporaryDirectory() as tmp:
            cache_home = os.path.join(tmp, "cache")
            for name in ("one", "two"):
                os.makedirs(os.path.join(tmp, name, "projects", "a"))
                with open(os.path.join(tmp, name, "projects", "a", "s.jsonl"), "w") as f:
                    f.write(reply(iso(now), "claude-opus-5-5", {"input_tokens": 1_000_000}) + "\n")
                run_script(os.path.join(tmp, name), "--warm", cache_home=cache_home)
            self.assertEqual(len(cache_files(cache_home)), 2)
            # A count still running when the tab is turned off saves into a
            # folder that is gone, so nothing comes back.
            with mock.patch.dict(os.environ, {"XDG_CACHE_HOME": cache_home}):
                folder = os.path.join(tmp, "one")
                run_script(folder, "--wipe", cache_home=cache_home)
                cost_report.save_cache(folder, {"x": {}})
            self.assertFalse(os.path.exists(os.path.join(cache_home, "claude-widget-kde", "cost")))

    def test_fast_reader_matches_full_parse(self):
        line = json.dumps({"parentUuid": "x", "message": {
            "model": "claude-opus-5-5", "id": "msg_1", "type": "message", "role": "assistant",
            "content": [{"type": "tool_use", "input": {"model": "fake", "id": "fake", "usage": {"input_tokens": 9},
                                                        "timestamp": "1999-01-01T00:00:00Z"}},
                        {"type": "text", "text": "a \"usage\":{\"input_tokens\": 5} in text"}],
            "usage": {"input_tokens": 3, "output_tokens": 4, "cache_read_input_tokens": 5,
                      "cache_creation": {"ephemeral_5m_input_tokens": 6, "ephemeral_1h_input_tokens": 7},
                      "speed": "fast"}},
            "requestId": "req_1", "type": "assistant", "timestamp": "2026-11-15T07:00:00.000Z", "cwd": "/x"},
            separators=(",", ":"))  # compact, as Claude Code writes it
        self.assertEqual(cost_report.read_reply(line), cost_report._read_reply_slow(line))
        self.assertEqual(cost_report.read_reply(line),
                         ["msg_1", "req_1", "claude-opus-5-5", "2026-11-15T07:00:00.000Z", 3, 4, 5, 6, 7, 1])

    def test_empty_folder(self):
        data, p = self.run_report({})
        self.assertEqual(p["all"]["cost"], 0)
        self.assertEqual(data["first"], "")


if __name__ == "__main__":
    unittest.main()
