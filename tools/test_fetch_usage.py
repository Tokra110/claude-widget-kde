#!/usr/bin/env python3
"""Tests for contents/scripts/fetch_usage.py. Run: python3 tools/test_fetch_usage.py

Every test runs in a temporary home folder with a fake network, so nothing
touches the real sign-in, the real cache or Anthropic's servers.
"""

import contextlib
import io
import json
import os
import stat
import sys
import tempfile
import time
import unittest
import urllib.error
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "contents", "scripts"))
sys.dont_write_bytecode = True
import fetch_usage as fu  # noqa: E402

USAGE = {"five_hour": {"utilization": 42, "resets_at": "2099-01-01T00:00:00Z"},
         "seven_day": {"utilization": 7, "resets_at": "2099-01-05T00:00:00Z"}}


class Reply(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def http_error(code):
    return urllib.error.HTTPError("u", code, "x", {}, io.BytesIO(b"{}"))


class FakeNet:
    """Answers by URL; records each request."""

    def __init__(self, usage=None, token=None):
        self.usage, self.token, self.requests = usage, token, []

    def __call__(self, req, timeout=None):
        self.requests.append(req)
        answer = self.usage if "oauth/usage" in req.full_url else self.token
        if isinstance(answer, Exception):
            raise answer
        return Reply(json.dumps(answer).encode())


class FetchTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = self.tmp.name
        self.patches = [
            mock.patch.dict(os.environ, {"HOME": self.home, "XDG_CACHE_HOME": "", "XDG_CONFIG_HOME": ""}),
        ]
        for p in self.patches:
            p.start()
        os.environ.pop("CLAUDE_CONFIG_DIR", None)
        os.environ.pop("CLAUDE_CODE_OAUTH_TOKEN", None)
        self.cache_file = fu.usage_cache(os.path.join(self.home, ".claude"))
        self.desktop = fu.desktop_history()

    def tearDown(self):
        for p in reversed(self.patches):
            p.stop()
        self.tmp.cleanup()

    def creds(self, folder=".claude", expired=False, refresh="rt-old", rt_expired=False):
        d = os.path.join(self.home, folder)
        os.makedirs(d, exist_ok=True)
        now = int(time.time() * 1000)
        oauth = {"accessToken": "at-old", "expiresAt": now - 1000 if expired else now + 3600_000}
        if refresh:
            oauth["refreshToken"] = refresh
        if rt_expired:
            oauth["refreshTokenExpiresAt"] = now - 1000
        path = os.path.join(d, ".credentials.json")
        with open(path, "w") as f:
            json.dump({"claudeAiOauth": oauth, "other": 1}, f)
        return path

    def run_fetch(self, *args, net=None):
        net = net or FakeNet()
        out = io.StringIO()
        with mock.patch("urllib.request.urlopen", net), contextlib.redirect_stdout(out):
            with mock.patch.object(sys, "argv", ["fetch_usage.py", *args]):
                fu.main()
        return json.loads(out.getvalue()), net

    def test_fresh_token_fetches_and_caches(self):
        self.creds()
        out, net = self.run_fetch(net=FakeNet(usage=USAGE))
        self.assertEqual(out["five_hour"]["utilization"], 42)
        req = net.requests[0]
        self.assertEqual(req.get_header("Authorization"), "Bearer at-old")
        self.assertIn("claude-widget-kde", req.get_header("User-agent"))
        self.assertTrue(os.path.exists(self.cache_file))

    def test_expired_token_is_refreshed_and_written_back(self):
        path = self.creds(expired=True)
        token = {"access_token": "at-new", "refresh_token": "rt-new", "expires_in": 100}
        out, net = self.run_fetch(net=FakeNet(usage=USAGE, token=token))
        self.assertNotIn("error", out)
        self.assertIn("claude-widget-kde", net.requests[0].get_header("User-agent"))
        self.assertEqual(net.requests[1].get_header("Authorization"), "Bearer at-new")
        with open(path) as f:
            saved = json.load(f)
        self.assertEqual(saved["claudeAiOauth"]["accessToken"], "at-new")
        self.assertEqual(saved["claudeAiOauth"]["refreshToken"], "rt-new")
        self.assertEqual(saved["other"], 1)
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)

    def test_refresh_race_with_the_cli_uses_its_new_token(self):
        path = self.creds(expired=True)

        class Race(FakeNet):
            def __call__(net, req, timeout=None):
                if "oauth/token" in req.full_url:
                    # Claude Code renewed first: our refresh token is spent.
                    with open(path) as f:
                        d = json.load(f)
                    d["claudeAiOauth"].update(accessToken="at-cli", expiresAt=int(time.time() * 1000) + 3600_000)
                    with open(path, "w") as f:
                        json.dump(d, f)
                    raise http_error(400)
                return FakeNet.__call__(net, req, timeout)

        out, net = self.run_fetch(net=Race(usage=USAGE))
        self.assertNotIn("error", out)
        self.assertEqual(net.requests[-1].get_header("Authorization"), "Bearer at-cli")

    def test_accounts_keep_separate_caches(self):
        self.creds(folder="a")
        self.creds(folder="b")
        self.run_fetch("~/a", net=FakeNet(usage=USAGE))
        out, _ = self.run_fetch("~/b", net=FakeNet(usage=http_error(429)))
        self.assertEqual(out["error"], "rate_limited")

    def test_refresh_keeps_a_linked_credentials_file(self):
        real = self.creds(folder="real", expired=True)
        os.makedirs(os.path.join(self.home, ".claude"))
        link = os.path.join(self.home, ".claude", ".credentials.json")
        os.symlink(real, link)
        token = {"access_token": "at-new", "expires_in": 100}
        out, _ = self.run_fetch(net=FakeNet(usage=USAGE, token=token))
        self.assertNotIn("error", out)
        self.assertTrue(os.path.islink(link))
        with open(real) as f:
            self.assertEqual(json.load(f)["claudeAiOauth"]["accessToken"], "at-new")

    def test_no_refresh_flag_reports_expired(self):
        self.creds(expired=True)
        out, net = self.run_fetch("--no-refresh")
        self.assertEqual(out["error"], "token_expired")
        self.assertEqual(net.requests, [])

    def test_dead_refresh_token_asks_for_sign_in(self):
        self.creds(expired=True)
        out, _ = self.run_fetch(net=FakeNet(token=http_error(400)))
        self.assertEqual(out["error"], "login_required")
        self.creds(expired=True, rt_expired=True)
        out, _ = self.run_fetch()
        self.assertEqual(out["error"], "login_required")

    def test_refresh_network_error_says_why(self):
        self.creds(expired=True)
        out, _ = self.run_fetch(net=FakeNet(token=OSError("down")))
        self.assertEqual(out["error"], "token_expired")
        self.assertIn("(network error)", out["message"])

    def test_rate_limit_uses_cache(self):
        self.creds()
        os.makedirs(os.path.dirname(self.cache_file))
        with open(self.cache_file, "w") as f:
            json.dump(USAGE, f)
        out, _ = self.run_fetch(net=FakeNet(usage=http_error(429)))
        self.assertTrue(out["cached"] and out["rate_limited"])
        os.remove(self.cache_file)
        out, _ = self.run_fetch(net=FakeNet(usage=http_error(429)))
        self.assertEqual(out["error"], "rate_limited")

    def test_rejected_sign_in_falls_back_to_desktop_numbers(self):
        self.creds()
        out, _ = self.run_fetch(net=FakeNet(usage=http_error(401)))
        self.assertEqual(out["error"], "login_required")
        os.makedirs(os.path.dirname(self.desktop))
        with open(self.desktop, "w") as f:
            json.dump({"samples": [{"t": time.time() * 1000, "u": {"fh": 55, "sd": 9}}]}, f)
        out, _ = self.run_fetch(net=FakeNet(usage=http_error(401)))
        self.assertEqual(out["source"], "desktop")
        self.assertEqual(out["five_hour"]["utilization"], 55)
        self.assertTrue(out["needs_login"])

    def test_other_http_and_network_errors(self):
        self.creds()
        out, _ = self.run_fetch(net=FakeNet(usage=http_error(500)))
        self.assertEqual(out["error"], "api_error")
        self.assertIn("HTTP 500", out["message"])
        out, _ = self.run_fetch(net=FakeNet(usage=OSError("down")))
        self.assertEqual(out["error"], "network_error")

    def test_no_credentials_names_the_folders(self):
        out, _ = self.run_fetch()
        self.assertEqual(out["error"], "no_credentials")
        self.assertIn("~/.claude", out["message"])

    def test_single_sibling_folder_is_used_and_two_are_not_guessed(self):
        self.creds(folder=".claude-work")
        out, _ = self.run_fetch(net=FakeNet(usage=USAGE))
        self.assertNotIn("error", out)
        self.creds(folder=".claude-home")
        out, _ = self.run_fetch()
        self.assertIn("Several Claude accounts found", out["message"])

    def test_explicit_folder_with_tilde(self):
        self.creds(folder="acct")
        out, _ = self.run_fetch("~/acct", net=FakeNet(usage=USAGE))
        self.assertNotIn("error", out)

    def test_env_token_rejected(self):
        os.environ["CLAUDE_CODE_OAUTH_TOKEN"] = "setup-token"
        out, _ = self.run_fetch(net=FakeNet(usage=http_error(403)))
        self.assertIn("cannot read usage", out["message"])

    def test_activity_prints_newest_log_time(self):
        self.creds()
        log = os.path.join(self.home, ".claude", "projects", "p", "s.jsonl")
        os.makedirs(os.path.dirname(log))
        open(log, "w").close()
        os.utime(log, (1_700_000_000, 1_700_000_000))
        out = io.StringIO()
        with contextlib.redirect_stdout(out), mock.patch.object(sys, "argv", ["x", "--activity"]):
            fu.main()
        self.assertEqual(out.getvalue().strip(), "1700000000")


if __name__ == "__main__":
    unittest.main()
