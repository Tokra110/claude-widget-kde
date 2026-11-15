#!/usr/bin/env python3
"""Open a terminal that runs `claude auth login`, and wait until it closes.

The widget runs this from the refresh button when fetch_usage.py reports
login_required, then fetches again. Prints one JSON object.

Usage: login.py [claude-folder]
  claude-folder  the widget's "Claude folder" setting; when set, the sign-in
                 is written there through CLAUDE_CONFIG_DIR.
Inside the terminal it runs itself again as: login.py --in-terminal CLAUDE FOLDER
"""

import json
import os
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from claude_folder import find_folder  # noqa: E402

HOME = os.path.expanduser("~")


def find_claude():
    # plasmashell does not read a shell profile, so ~/.local/bin (where the
    # Claude Code installer puts claude) is often missing from PATH here.
    found = shutil.which("claude")
    if found:
        return found
    for c in (HOME + "/.local/bin/claude", HOME + "/.claude/local/claude",
              "/usr/local/bin/claude", "/usr/bin/claude"):
        if os.access(c, os.X_OK):
            return c
    return None


def in_terminal(claude, folder):
    env = dict(os.environ)
    if folder:
        env["CLAUDE_CONFIG_DIR"] = folder
    print("Claude Widget: your Claude sign-in has expired.")
    print("A browser window opens. Approve the sign-in there.\n")
    if subprocess.call([claude, "auth", "login"], env=env) == 0:
        print("\nSigned in. This window closes in 3 seconds.")
        time.sleep(3)
    else:
        input("\nSign-in did not finish. Press Enter to close this window.")


def main():
    args = sys.argv[1:]
    if args[:1] == ["--in-terminal"]:
        in_terminal(args[1], args[2] if len(args) > 2 else "")
        return
    # The same folder search as the limits, so the sign-in lands in the
    # account the widget shows. The default folder needs no CLAUDE_CONFIG_DIR.
    folder = find_folder(args[0] if args else "")[0]
    if os.path.realpath(folder) == os.path.realpath(os.path.join(HOME, ".claude")):
        folder = ""
    claude = find_claude()
    if not claude:
        print(json.dumps({"error": "Claude Code is not installed, so the widget cannot sign in. "
                                   "Install it, then run claude auth login."}))
        return
    # Values go in as separate arguments (no shell), so a folder path with
    # quotes or spaces cannot break the command.
    inner = [sys.executable, "-I", os.path.abspath(__file__), "--in-terminal", claude, folder]
    # --nofork keeps konsole in the foreground, so we know when it closes.
    if shutil.which("konsole"):
        cmd = ["konsole", "--nofork", "-e"] + inner
    elif shutil.which("xterm"):
        cmd = ["xterm", "-T", "Claude sign-in", "-e"] + inner
    else:
        print(json.dumps({"error": "No terminal found to sign in with. "
                                   "Run claude auth login in a terminal yourself."}))
        return
    subprocess.call(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(json.dumps({"status": "done"}))


if __name__ == "__main__":
    main()
