"""Where the widget's files are: the Claude folder to read, and its own caches.

Shared by fetch_usage.py, cost_report.py and login.py, so the limits, the Cost
tab and the sign-in always use the same Claude folder. Everything is looked up
at call time from the environment (HOME, CLAUDE_CONFIG_DIR, XDG_CACHE_HOME).
"""

import glob
import hashlib
import os


def home():
    return os.path.expanduser("~")


def expand(path):
    return home() + path[1:] if path.startswith("~") else path


def tildify(path):
    h = home()
    if h != "/" and (path == h or path.startswith(h + "/")):
        return "~" + path[len(h):]
    return path


def find_folder(explicit=""):
    """(claude folder, credentials file or None, ambiguous list, checked list).

    An explicit folder (the widget's "Claude folder" setting) wins outright;
    otherwise try the places Claude Code uses. plasmashell does not read a shell
    profile, so CLAUDE_CONFIG_DIR is only seen here when exported session-wide.
    """
    if explicit:
        candidates = [expand(explicit)]
    else:
        candidates = []
        if os.environ.get("CLAUDE_CONFIG_DIR"):
            candidates.append(expand(os.environ["CLAUDE_CONFIG_DIR"]))
        candidates.append(os.path.join(home(), ".claude"))
    for d in candidates:
        if os.path.isfile(os.path.join(d, ".credentials.json")):
            return d, os.path.join(d, ".credentials.json"), [], candidates
    # Last resort: a single ~/.claude* sibling, which is what a multi-account
    # CLAUDE_CONFIG_DIR setup looks like. Never guess between several.
    if not explicit:
        matches = sorted(glob.glob(os.path.join(home(), ".claude*", ".credentials.json")))
        if len(matches) == 1:
            return os.path.dirname(matches[0]), matches[0], [], candidates
        if len(matches) > 1:
            return candidates[0], None, [tildify(os.path.dirname(m)) for m in matches], candidates
    return candidates[0], None, [], candidates


def cache_dir():
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(home(), ".cache")
    return os.path.join(base, "claude-widget-kde")


def folder_key(folder):
    """Short stable name for a Claude folder, so each account has its own caches."""
    return hashlib.sha1(os.path.realpath(folder).encode()).hexdigest()[:12]
