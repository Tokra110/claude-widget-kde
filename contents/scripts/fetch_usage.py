#!/usr/bin/env python3
"""Fetch Claude Code usage from the Anthropic API and print it as JSON.

Always prints one JSON object and exits 0; errors are JSON too.

Usage: fetch_usage.py [--activity] [--no-refresh] [claude-folder]
  --activity    print the newest session log time in the resolved folder (or 0)
                instead of fetching, so activity polling follows the same
                folder resolution the fetch does.
  --no-refresh  never exchange the refresh token for a new access token; an
                expired token is reported as token_expired instead.
"""

import calendar
import glob
import json
import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from claude_folder import cache_dir, find_folder, folder_key, home, tildify  # noqa: E402

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
TOKEN_URL = "https://platform.claude.com/v1/oauth/token"
CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

# Cloudflare in front of both endpoints answers 403 (error 1010) to requests
# that carry no User-Agent or python-urllib's default one, so every call must
# name itself with a real agent string. Without this the token refresh fails
# after every access-token expiry and the panel sits on a 403.
USER_AGENT = "claude-widget-kde (KDE Plasma widget; +https://github.com/Tokra110/claude-widget-kde)"

DESKTOP_MAX_AGE_MIN = 45

SIGN_IN_AGAIN = "Your Claude sign-in has expired. Press the refresh button to sign in again."


class Done(Exception):
    """Carries the one JSON object to print."""

    def __init__(self, out):
        self.out = out


def error(code, message):
    raise Done({"error": code, "message": message})


def usage_cache(folder):
    """Last good reply, one file per Claude folder, so accounts never mix."""
    return os.path.join(cache_dir(), "usage-%s.json" % folder_key(folder))


def desktop_history():
    """The Claude desktop app writes its plan usage here about every 15 minutes."""
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(home(), ".config")
    return os.path.join(base, "Claude", "plan-usage-history.json")


def desktop_fallback(code, message, cache_file):
    """The desktop app's numbers when the CLI sign-in cannot be used.

    The app keeps its own sign-in in the system keyring, out of reach, but its
    usage samples are a plain file. Use the newest one when it is fresh enough,
    borrow still-valid reset times from our own last API reply, and say where
    the numbers came from. None when there is no usable sample.
    """
    try:
        with open(desktop_history()) as f:
            samples = json.load(f).get("samples") or []
        s = max(samples, key=lambda x: x.get("t", 0))
        u, t = s["u"], s["t"] / 1000
        if time.time() - t > DESKTOP_MAX_AGE_MIN * 60:
            return None
    except Exception:
        return None
    resets = {}
    try:
        with open(cache_file) as f:
            cache = json.load(f)
        for key in ("five_hour", "seven_day"):
            r = (cache.get(key) or {}).get("resets_at") or ""
            # Only a reset still ahead belongs to the window the sample is in.
            if r and calendar.timegm(time.strptime(r[:19], "%Y-%m-%dT%H:%M:%S")) > time.time():
                resets[key] = r
    except Exception:
        pass
    return {
        "five_hour": {"utilization": u.get("fh", 0), "resets_at": resets.get("five_hour", "")},
        "seven_day": {"utilization": u.get("sd", 0), "resets_at": resets.get("seven_day", "")},
        "_fetched_at": int(t),
        "cached": True,
        "source": "desktop",
        "needs_login": code == "login_required",
        "source_note": message,
    }


def newest_activity(folder):
    """Newest session log time. Claude Code appends every reply to a log in
    projects/<folder>/; history.jsonl moves only on some prompts."""
    paths = glob.glob(os.path.join(folder, "projects", "*", "*.jsonl"))
    paths.append(os.path.join(folder, "history.jsonl"))
    newest = 0
    for p in paths:
        try:
            newest = max(newest, int(os.path.getmtime(p)))
        except OSError:
            pass
    return newest


def read_token(cred_file):
    """(access token, expired). Raises on a file without a usable token."""
    with open(cred_file) as f:
        oauth = json.load(f)["claudeAiOauth"]
    token = oauth["accessToken"]
    if not token:
        raise ValueError("empty token")
    expires_at = oauth.get("expiresAt", 0)
    return token, bool(expires_at and time.time() * 1000 > expires_at)


def refresh_token(cred_file):
    """Exchange the refresh token for a new access token, as the CLI does.

    The access token lives about 8 hours and only Claude Code writes a fresh
    one, so after a night away the panel would sit on an error. The result is
    written back so the CLI and the widget keep sharing one credential. The
    write is atomic and re-reads the file first, so a CLI refresh that landed
    in the meantime wins. Returns (token, None) or (None, reason).
    """
    import urllib.error
    import urllib.request
    try:
        with open(cred_file) as f:
            oauth = json.load(f)["claudeAiOauth"]
        rt = oauth.get("refreshToken")
        if not rt:
            return None, "no refresh token stored"
        rt_exp = oauth.get("refreshTokenExpiresAt", 0)
        if rt_exp and time.time() * 1000 > rt_exp:
            return None, "refresh token expired"
        body = json.dumps({"grant_type": "refresh_token", "refresh_token": rt,
                           "client_id": CLIENT_ID}).encode()
        req = urllib.request.Request(TOKEN_URL, data=body, method="POST", headers={
            "Content-Type": "application/json", "Accept": "application/json",
            "User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                data = json.load(r)
        except urllib.error.HTTPError as e:
            return None, "HTTP %d" % e.code
        except Exception:
            return None, "network error"
        access = data.get("access_token")
        if not access:
            return None, "no access token in reply"
        with open(cred_file) as f:
            latest = json.load(f)
        lo = latest.get("claudeAiOauth", {})
        if lo.get("accessToken") != oauth.get("accessToken"):
            return lo.get("accessToken"), None
        lo["accessToken"] = access
        if data.get("refresh_token"):
            lo["refreshToken"] = data["refresh_token"]
        lo["expiresAt"] = int(time.time() * 1000) + int(data.get("expires_in", 3600)) * 1000
        if data.get("scope"):
            lo["scopes"] = data["scope"].split()
        latest["claudeAiOauth"] = lo
        # Write next to the real file (it may be a link) under a unique name,
        # so two widgets on one folder never share a temp file.
        target = os.path.realpath(cred_file)
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(target), prefix=".credentials.")
        try:
            with os.fdopen(fd, "w") as f:
                json.dump(latest, f)
            os.chmod(tmp, 0o600)
            os.replace(tmp, target)
        except BaseException:
            try:
                os.remove(tmp)
            except OSError:
                pass
            raise
        return access, None
    except Exception:
        return None, "refresh failed"


def renewed_elsewhere(cred_file, old_token):
    """The token Claude Code wrote while our refresh failed, if it is usable.

    When the CLI renews at the same moment, the server refuses our (now used)
    refresh token, but the file already holds a fresh sign-in.
    """
    try:
        token, expired = read_token(cred_file)
    except Exception:
        return None
    return token if token != old_token and not expired else None


def fetch(token, token_source, cache_file):
    import urllib.error
    import urllib.request
    req = urllib.request.Request(USAGE_URL, headers={
        "Authorization": "Bearer " + token,
        "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            body = r.read()
    except urllib.error.HTTPError as e:
        code = e.code
        if code == 429:
            try:
                with open(cache_file) as f:
                    data = json.load(f)
            except Exception:
                error("rate_limited", "Anthropic asks the widget to wait. It tries again later.")
            data["cached"] = True
            data["rate_limited"] = True
            raise Done(data)
        if code == 403 and token_source == "env":
            error("api_error", "The sign-in in CLAUDE_CODE_OAUTH_TOKEN cannot read usage (a token "
                  "from claude setup-token only works for model requests). Sign in with claude instead.")
        if code == 401 and token_source == "file":
            auth_error("login_required", "Your Claude sign-in is no longer valid. "
                       "Press the refresh button to sign in again.", cache_file)
        error("api_error", "Anthropic's server answered with an error (HTTP %d). "
              "The widget tries again later." % code)
    except Exception:
        error("network_error", "Could not reach Anthropic. Check the network; the widget tries again later.")
    try:
        data = json.loads(body)
    except Exception:
        error("parse_error", "Anthropic sent a reply the widget cannot read. It tries again later.")
    if "error" in data:
        msg = data.get("error", {})
        if isinstance(msg, dict):
            msg = msg.get("message", str(data))
        error("api_error", str(msg))
    data["_fetched_at"] = int(time.time())
    os.makedirs(os.path.dirname(cache_file), exist_ok=True)
    with open(cache_file, "w") as f:
        json.dump(data, f)
    raise Done(data)


def auth_error(code, message, cache_file):
    """An error the desktop app's numbers can cover, when they are fresh."""
    out = desktop_fallback(code, message, cache_file)
    if out:
        raise Done(out)
    error(code, message)


def run(argv):
    activity = "--activity" in argv
    refresh = "--no-refresh" not in argv
    rest = [a for a in argv if a not in ("--activity", "--no-refresh")]
    explicit = rest[0] if rest else ""

    folder, cred_file, ambiguous, candidates = find_folder(explicit)
    if activity:
        print(newest_activity(folder))
        return
    cache_file = usage_cache(folder)
    # The file of earlier versions, shared by all accounts.
    try:
        os.remove(os.path.join(cache_dir(), "last_usage.json"))
    except OSError:
        pass

    token, expired, unreadable = None, False, False
    if cred_file:
        try:
            token, expired = read_token(cred_file)
        except Exception:
            unreadable = True

    # CLAUDE_CODE_OAUTH_TOKEN only counts when the widget finds the folder
    # itself; an explicit folder names the account the user wants.
    source = "file"
    if (not token or expired) and not explicit and os.environ.get("CLAUDE_CODE_OAUTH_TOKEN"):
        token, expired, source = os.environ["CLAUDE_CODE_OAUTH_TOKEN"], False, "env"

    if not token:
        if ambiguous:
            auth_error("no_credentials", "Several Claude accounts found (%s). Set Claude folder "
                       "in the widget settings to pick one." % ", ".join(ambiguous), cache_file)
        if unreadable:
            auth_error("parse_error", "Could not read your sign-in from %s. Sign in again by "
                       "running claude in a terminal." % tildify(cred_file), cache_file)
        auth_error("no_credentials", "No Claude sign-in found in %s. Sign in by running claude in "
                   "a terminal, or set Claude folder in the widget settings."
                   % ", ".join(tildify(c) for c in candidates), cache_file)

    if expired and refresh and source == "file":
        old = token
        token, reason = refresh_token(cred_file)
        if not token:
            token = renewed_elsewhere(cred_file, old)
        if not token:
            # A dead refresh token (it lives about a month; the server answers
            # 400 invalid_grant or 401) needs a new sign-in, so it gets its own
            # code: the refresh button then starts the sign-in.
            if reason in ("refresh token expired", "no refresh token stored", "HTTP 400", "HTTP 401"):
                auth_error("login_required", SIGN_IN_AGAIN, cache_file)
            auth_error("token_expired", "Your Claude sign-in has expired and renewing it failed "
                       "(%s). Press refresh to try again." % reason, cache_file)
        expired = False

    if expired:
        auth_error("token_expired", "Your Claude sign-in has expired. Run claude in a terminal to "
                   "renew it, or turn on automatic renewal in the widget settings.", cache_file)
    fetch(token, source, cache_file)


def main():
    try:
        run(sys.argv[1:])
    except Done as d:
        print(json.dumps(d.out))
    except Exception:
        print(json.dumps({"error": "parse_error",
                          "message": "Something went wrong while reading your usage. "
                                     "The widget tries again later."}))


if __name__ == "__main__":
    main()
