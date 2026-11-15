#!/usr/bin/env python3
"""Install, update or remove the Claude Widget for KDE Plasma 6.

Usage: python3 install.py [--no-reload | --remove]

By default this restarts the Plasma shell around the update, so the new version
shows up in place. Plasma keeps each widget's settings in
~/.config/plasma-org.kde.plasma.desktop-appletsrc, keyed by the widget's
instance, and an update never touches them; only removing the widget from the
panel and adding it back starts over at defaults.

--no-reload  update the files only; restart the shell yourself to see them.
--remove     uninstall the widget.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(ROOT, "metadata.json")) as f:
    WIDGET_ID = json.load(f)["KPlugin"]["Id"]


def kpackagetool(*args):
    return subprocess.run(["kpackagetool6", "-t", "Plasma/Applet", *args],
                          capture_output=True, text=True)


def shell_running():
    return subprocess.run(["pgrep", "-x", "plasmashell"], capture_output=True).returncode == 0


def stop_shell():
    # Stop the shell BEFORE the update: kpackagetool6 -u removes the old package
    # and then installs the new one, and a running shell that sees the widget
    # vanish in between drops it from the panel or System Tray for good.
    print("Stopping the Plasma shell for the update (settings are kept)...")
    if subprocess.run(["kquitapp6", "plasmashell"], capture_output=True).returncode != 0:
        subprocess.run(["killall", "plasmashell"], capture_output=True)
    for _ in range(50):
        if not shell_running():
            return
        time.sleep(0.2)


def start_shell():
    print("Starting the Plasma shell again...")
    starter = shutil.which("kstart") or shutil.which("kstart6") or "kstart"
    subprocess.Popen([starter, "plasmashell"], stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)
    print("Done. The panel flickers once as it restarts.")


def main():
    args = sys.argv[1:]
    if "--remove" in args:
        r = kpackagetool("-r", WIDGET_ID)
        print(r.stdout or r.stderr, end="")
        sys.exit(r.returncode)

    reload = "--no-reload" not in args
    if reload:
        stop_shell()
    installed = WIDGET_ID in kpackagetool("-l").stdout
    print("Updating the installed widget..." if installed else "Installing the widget...")
    # Install the same files a release ships (metadata, icon, licence and
    # contents/), not the whole folder with its tools and notes.
    sys.path.insert(0, os.path.join(ROOT, "tools"))
    sys.dont_write_bytecode = True
    import release
    with tempfile.TemporaryDirectory() as tmp:
        archive = os.path.join(tmp, "claude-widget-kde.plasmoid")
        root = release.Path(ROOT)
        release.cmd_package(release.argparse.Namespace(root=root, version=release.read_version(root), out=archive))
        r = kpackagetool("-u" if installed else "-i", archive)
    print(r.stdout or r.stderr, end="")
    if reload:
        start_shell()
    else:
        print("Files updated. Run 'kquitapp6 plasmashell && kstart plasmashell' to see them.")
    sys.exit(r.returncode)


if __name__ == "__main__":
    main()
