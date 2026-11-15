#!/usr/bin/env python3
"""What the Claude Code usage on this computer would cost at API prices.

Reads the session logs Claude Code writes to <claude-folder>/projects/**/*.jsonl
and prints one JSON object with a total for each period the widget offers
(today, this week, last week, this month, last 30 days, last 90 days, all time).
The widget runs this once in the background when it starts (--warm, to fill
the cache), and when its Cost tab is opened or refreshed; the process exits
when done, so nothing stays in memory between looks.

The counting rules follow ccusage (github.com/ryoppippi/ccusage, MIT License,
Copyright (c) 2025 ryoppippi), the most used tool for this job:
  - one assistant reply is written to the log several times (once per content
    block), so entries are de-duplicated on message.id + requestId. Unlike
    ccusage, the copy with the most output tokens counts: the early copies
    carry a partial output count;
  - cost = tokens x per-token price, with cache writes split into the 5-minute
    rate (cache_write) and the 1-hour rate (2 x input);
  - "speed": "fast" doubles the price (Anthropic's fast mode);
  - a model with a long-context tier bills the whole request at the tier rates
    once its context (input + cache write + cache read) passes the tier size.
Prices are first-party Anthropic list prices in USD per million tokens, taken
from ccusage's models.dev pricing snapshot of November 2026. A model that is not
in the table counts its tokens but no cost, and is listed under "unpriced".

Speed: the logs are hundreds of MB, nearly all of it reply content. Each
reply's few numbers are kept in a cache (~/.cache/claude-widget-kde/cost/, one file per Claude folder)
with each file's size and time; the logs are append-only, so a later run reads
only the lines added since. Only the first run ever reads everything.

Usage: cost_report.py [--warm | --period KEY] [claude-folder]
       cost_report.py --wipe
  --warm        fill the cache only; print {"warm": true, ...}
  --wipe        delete the cache (the Cost tab was turned off)
  --period KEY  count only that period (and the days its bar chart shows), for
                a fast first look; the widget then runs a full count in the
                background. Log files last written before the first day needed
                are skipped unread: a reply is never logged after the file's
                last write, so they cannot hold anything in range.
"""

import datetime as dt
import functools
import glob
import json
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from claude_folder import cache_dir, find_folder, folder_key  # noqa: E402

# model prefix -> (input, output, cache_read, cache_write_5m, tier)
# tier is (context_size, input, output, cache_read, cache_write_5m) or None.
# Longest prefix wins, so "claude-opus-4-1" beats "claude-opus-4".
PRICES = {
    "claude-fable-5-2": (8, 40, 0.2, 10, None),
    "claude-fable-5-1": (10, 50, 0.25, 12.5, None),
    "claude-fable-5": (10, 50, 1, 12.5, None),
    "claude-mythos-5": (10, 50, 1, 12.5, None),
    "claude-opus-5-5": (4, 20, 0.2, 5, None),
    "claude-opus-5": (5, 25, 0.5, 6.25, None),
    "claude-opus-4-8": (5, 25, 0.5, 6.25, None),
    "claude-opus-4-7": (5, 25, 0.5, 6.25, None),
    "claude-opus-4-6": (5, 25, 0.5, 6.25, None),
    "claude-opus-4-5": (5, 25, 0.5, 6.25, None),
    "claude-opus-4-1": (15, 75, 1.5, 18.75, None),
    "claude-opus-4": (15, 75, 1.5, 18.75, None),
    "claude-sonnet-5-5": (2, 10, 0.1, 2.5, None),
    "claude-sonnet-5": (2, 10, 0.2, 2.5, None),
    # Sonnet 4.6 bills its whole 1M window at the base rate (no long-context tier).
    "claude-sonnet-4-6": (3, 15, 0.3, 3.75, None),
    "claude-sonnet-4-5": (3, 15, 0.3, 3.75, (200_000, 6, 22.5, 0.6, 7.5)),
    "claude-sonnet-4": (3, 15, 0.3, 3.75, (200_000, 6, 22.5, 0.6, 7.5)),
    "claude-haiku-5-5": (0.1, 0.5, 0.01, 0.125, (100_000, 0.5, 2.5, 0.05, 0.625)),
    "claude-haiku-4-5": (1, 5, 0.1, 1.25, None),
    "claude-3-7-sonnet": (3, 15, 0.3, 3.75, None),
    "claude-3-5-haiku": (0.8, 4, 0.08, 1, None),
}
CACHE_1H_INPUT_MULTIPLIER = 2.0
FAST_MULTIPLIER = 2.0
_PREFIXES = sorted(PRICES, key=len, reverse=True)


@functools.lru_cache(maxsize=None)
def price_for(model):
    for prefix in _PREFIXES:
        if model == prefix or model.startswith(prefix + "-") or model.startswith(prefix + "@"):
            return PRICES[prefix]
    return None


# A reply as cached: message id, request id, model, timestamp text, then
# tokens: input, output, cache read, cache write 5m, cache write 1h, fast (0/1).
CACHE_VERSION = 1


def usage_tokens(usage):
    breakdown = usage.get("cache_creation")
    if isinstance(breakdown, dict):
        c5m = breakdown.get("ephemeral_5m_input_tokens") or 0
        c1h = breakdown.get("ephemeral_1h_input_tokens") or 0
    else:
        c5m, c1h = usage.get("cache_creation_input_tokens") or 0, 0
    return [usage.get("input_tokens") or 0, usage.get("output_tokens") or 0,
            usage.get("cache_read_input_tokens") or 0, c5m, c1h,
            1 if usage.get("speed") == "fast" else 0]


def token_parts(price, inp, out, cread, c5m, c1h, fast):
    """Cost of one reply split by token type, and its token count."""
    p_in, p_out, p_read, p_write = price[:4]
    tier = price[4]
    if tier and inp + c5m + c1h + cread > tier[0]:
        _, p_in, p_out, p_read, p_write = tier
    k = (FAST_MULTIPLIER if fast else 1.0) / 1_000_000
    parts = {
        "input": inp * p_in * k,
        "output": out * p_out * k,
        "cache_write": (c5m * p_write + c1h * p_in * CACHE_1H_INPUT_MULTIPLIER) * k,
        "cache_read": cread * p_read * k,
    }
    return parts, inp + out + cread + c5m + c1h


def entry_parts(price, usage):
    return token_parts(price, *usage_tokens(usage))


def entry_cost(price, usage):
    parts, tokens = entry_parts(price, usage)
    return sum(parts.values()), tokens


def periods(now):
    today = now.replace(hour=0, minute=0, second=0, microsecond=0)
    week = today - dt.timedelta(days=today.weekday())
    month = today.replace(day=1)
    far = dt.datetime.max.replace(tzinfo=now.tzinfo)
    # key, label, start (inclusive), end (exclusive)
    return [
        ("today", "Today", today, far),
        ("this_week", "This week", week, far),
        ("last_week", "Last week", week - dt.timedelta(days=7), week),
        ("this_month", "This month", month, far),
        # Whole days (today and the 29 before), so every period is a run of
        # calendar days and the popup can filter it by day.
        ("last_30", "Last 30 days", today - dt.timedelta(days=29), far),
        ("last_90", "Last 90 days", today - dt.timedelta(days=89), far),
        ("all", "All time", dt.datetime.min.replace(tzinfo=now.tzinfo), far),
    ]


TYPES = ("input", "output", "cache_write", "cache_read")
_DECODER = json.JSONDecoder()


def _str_after(line, marker, start=0, last=False):
    i = line.rfind(marker) if last else line.find(marker, start)
    if i < 0:
        return None
    i += len(marker)
    j = line.find('"', i)
    return line[i:j] if j > i else None


def read_reply(line):
    """The cached form of an assistant reply line, or None when it is not one.

    Most of a reply line is its content, so a full JSON parse of every line is
    what makes counting slow. Claude Code writes the record with a fixed shape:
    message.model and message.id first, the content, then message.usage, then
    the top-level requestId and timestamp. So the small fields are cut out
    directly and only the usage object is parsed. Strings inside the content
    have their quotes escaped, so these markers only match real keys. A line
    of another shape falls back to a full parse.
    """
    head = line.find('"message":{"model":"')
    usage_at = line.rfind('"usage":{"input_tokens"')
    if head < 0 or usage_at < 0:
        return _read_reply_slow(line)
    model = _str_after(line, '"message":{"model":"', head)
    msg_id = _str_after(line, '"id":"', head + 20)
    ts = _str_after(line, '"timestamp":"', last=True)
    req = _str_after(line, '"requestId":"', last=True)
    if not (model and msg_id and ts):
        return _read_reply_slow(line)
    try:
        usage = _DECODER.raw_decode(line, usage_at + len('"usage":'))[0]
    except ValueError:
        return _read_reply_slow(line)
    if not isinstance(usage, dict):
        return None
    return [msg_id, req, model, ts] + usage_tokens(usage)


def _read_reply_slow(line):
    try:
        rec = json.loads(line)
    except ValueError:
        return None
    msg = rec.get("message") if isinstance(rec, dict) else None
    if not isinstance(msg, dict) or not isinstance(msg.get("usage"), dict):
        return None
    ts = rec.get("timestamp")
    if not isinstance(ts, str):
        return None
    return [msg.get("id"), rec.get("requestId"), msg.get("model") or "", ts] + usage_tokens(msg["usage"])


def read_file(path, offset=0):
    """Replies in path from byte offset on, and the offset after the last full
    line (a line still being written is left for the next run)."""
    replies = []
    with open(path, "rb") as fh:
        fh.seek(offset)
        data = fh.read()
    end = data.rfind(b"\n") + 1
    for raw in data[:end].split(b"\n"):
        # Cheap filter first: most lines are tool output, not replies.
        if b'"usage"' not in raw or b'"assistant"' not in raw:
            continue
        reply = read_reply(raw.decode("utf-8", "replace"))
        if reply is not None:
            replies.append(reply)
    return replies, offset + end


def cost_dir():
    """All Cost tab cache files live here, one per Claude folder."""
    return os.path.join(cache_dir(), "cost")


def cache_path(folder):
    return os.path.join(cost_dir(), folder_key(folder) + ".json")


def load_cache(folder):
    try:
        with open(cache_path(folder)) as f:
            data = json.load(f)
        if data.get("version") == CACHE_VERSION and isinstance(data.get("files"), dict):
            return data["files"]
    except (OSError, ValueError, AttributeError):
        pass
    return {}


def save_cache(folder, files):
    """Save only into an existing cache folder. A count makes the folder when
    it starts, and turning the Cost tab off deletes it, so a count that was
    still running then cannot bring the cache back."""
    path = cache_path(folder)
    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".cost-entries.")
        # json.dumps uses the C encoder; json.dump to a file does not and is
        # about five times slower on a cache of tens of MB.
        with os.fdopen(fd, "w") as f:
            f.write(json.dumps({"version": CACHE_VERSION, "files": files}, separators=(",", ":")))
        os.replace(tmp, path)
    except OSError:
        if tmp:
            try:
                os.remove(tmp)
            except OSError:
                pass


def remove_old_cache():
    """The single cache file of earlier versions, shared by all accounts."""
    try:
        os.remove(os.path.join(cache_dir(), "cost-entries.json"))
    except OSError:
        pass


def wipe():
    """The Cost tab was turned off: delete every cache file it made."""
    shutil.rmtree(cost_dir(), ignore_errors=True)
    remove_old_cache()


def replies_by_file(files, cache):
    """Replies per file, from the cache where the file has not changed and by
    reading only the new tail where it has grown. Returns whether the cache
    changed."""
    changed = False
    out = []
    for path in files:
        try:
            st = os.stat(path)
        except OSError:
            continue
        c = cache.get(path)
        if c and c.get("size") == st.st_size and c.get("mtime") == st.st_mtime:
            out.append(c["replies"])
            continue
        try:
            if c and st.st_size > c.get("end", 0) and c.get("end", 0) > 0:
                more, end = read_file(path, c["end"])
                replies = c["replies"] + more
            else:
                replies, end = read_file(path)
        except OSError:
            continue
        cache[path] = {"size": st.st_size, "mtime": st.st_mtime, "end": end, "replies": replies}
        changed = True
        out.append(replies)
    return out, changed


def parse_time(ts):
    try:
        return dt.datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone()
    except ValueError:
        return None


def series_start(key, start):
    """First day the period's bar chart shows (None: from the first log day)."""
    if key == "all":
        return None
    if key == "today":  # today alone is one bar, so the chart shows a week
        return start - dt.timedelta(days=6)
    return start


def main():
    args = sys.argv[1:]
    if args[:1] == ["--wipe"]:
        wipe()
        json.dump({"wiped": True}, sys.stdout)
        return
    warm = args[:1] == ["--warm"]
    if warm:
        args = args[1:]
    only = None
    if len(args) >= 2 and args[0] == "--period":
        only = args[1]
        args = args[2:]
    # The same folder search as the limits, so both show the same account.
    folder = find_folder(args[0] if args else "")[0]
    os.makedirs(cost_dir(), exist_ok=True)
    remove_old_cache()
    files = sorted(glob.glob(os.path.join(folder, "projects", "**", "*.jsonl"), recursive=True))

    now = dt.datetime.now().astimezone()
    spans = periods(now)
    cutoff_dt = None
    cutoff_text = ""
    if only:
        spans = [s for s in spans if s[0] == only]
        if not spans:
            raise ValueError("unknown period " + only)
        scan_from = series_start(spans[0][0], spans[0][2])
        if scan_from is not None:
            cutoff_dt = scan_from
            cutoff_text = scan_from.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
            cutoff = scan_from.timestamp()
            kept = []
            for f in files:
                try:
                    if os.path.getmtime(f) >= cutoff:
                        kept.append(f)
                except OSError:
                    pass
            files = kept

    cache = load_cache(folder)
    per_file, changed = replies_by_file(files, cache)
    if not only:
        # Forget files that are gone, so the cache does not grow forever.
        alive = set(files)
        for path in list(cache):
            if path not in alive:
                del cache[path]
                changed = True
    # The fast count of one period does not save: the full count that the
    # Cost tab starts right after it saves once for both.
    if changed and not only:
        save_cache(folder, cache)
    if warm:
        # Background run at widget start: only fill the cache.
        json.dump({"warm": True, "files": len(files)}, sys.stdout)
        return

    # (date, model) -> [cost, tokens, replies, cost per type..., cost per hour...]:
    # the popup sums these for any day or model it is filtered to. Every period
    # is a run of whole days, so the period totals are sums of these cells too.
    cells = {}
    unpriced = set()
    first = None
    nt = len(TYPES)

    # Claude Code logs one reply once per content block, and the early copies
    # carry a partial output count, so keep the copy with the most output
    # tokens. (ccusage keeps the first copy, which counts output too low.)
    best = {}
    unkeyed = []
    for replies in per_file:
        for rep in replies:
            if not rep[0]:
                unkeyed.append(rep)
                continue
            key = (rep[0], rep[1])
            old = best.get(key)
            if old is None or rep[5] > old[5]:
                best[key] = rep

    for replies in (best.values(), unkeyed):
        for msg_id, req, model, ts, inp, out, cread, c5m, c1h, fast in replies:
            if model == "<synthetic>":
                continue
            # Out of range: skip early. Logged times are UTC ("...Z"), so the
            # text compares like the time itself.
            if cutoff_text and ts.endswith("Z") and ts < cutoff_text:
                continue
            when = parse_time(ts)
            if when is None or (cutoff_dt and when < cutoff_dt):
                continue
            price = price_for(model)
            if price is None:
                unpriced.add(model)
                parts = dict.fromkeys(TYPES, 0.0)
                tokens = inp + out + cread + c5m + c1h
            else:
                parts, tokens = token_parts(price, inp, out, cread, c5m, c1h, fast)
            cost = sum(parts.values())
            if first is None or when < first:
                first = when
            cell = cells.get((when.date(), model))
            if cell is None:
                cell = cells[(when.date(), model)] = [0.0, 0, 0] + [0.0] * (nt + 24)
            cell[0] += cost
            cell[1] += tokens
            cell[2] += 1
            for i, k in enumerate(TYPES):
                cell[3 + i] += parts[k]
            cell[3 + nt + when.hour] += cost

    out = []
    for key, label, start, end in spans:
        # The days the period's charts cover: from its first day ("all": the
        # first log day) to its last day, today at the latest. Fixed by the
        # period alone, so the fast and the full count draw the same bars.
        # The popup sums the cells for these days itself.
        d0 = start.date() if key != "all" else (first or now).date()
        d1 = min(end - dt.timedelta(microseconds=1), now).date()
        out.append({"key": key, "label": label, "start_day": d0.isoformat(), "end_day": d1.isoformat()})
    cell_list = [[d.isoformat(), m, round(c[0], 4), c[1], c[2],
                  [round(v, 4) for v in c[3:3 + nt]], [round(v, 4) for v in c[3 + nt:]]]
                 for (d, m), c in sorted(cells.items())]
    json.dump({
        "periods": out,
        # [day, model, cost, tokens, replies, [cost per type in "types" order],
        # [cost per hour]]; a fast count holds only the days from cells_from on.
        "cells": cell_list,
        "cells_from": cutoff_dt.date().isoformat() if cutoff_dt else "",
        "types": list(TYPES),
        "partial": bool(only),
        "first": first.strftime("%Y-%m-%d") if first and not only else "",
        "files": len(files),
        "unpriced": sorted(unpriced),
        "generated": int(now.timestamp()),
    }, sys.stdout)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # the widget shows this instead of a blank tab
        json.dump({"error": "Could not count usage: %s" % exc}, sys.stdout)
