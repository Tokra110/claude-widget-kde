# Changelog

## 1.0.0 - 2026-11-15

First version. Based on Claude Meter 0.6.2 by p3kj (MIT).

- 5-hour and weekly limits, plus a bar for every scoped weekly limit the API reports
- Pace marker on each bar: usage ahead of the time that has passed shows in the warning color
- Panel styles: plain percent, stacked bars or a gauge; fits in the System Tray
- Renews an expired sign-in by itself; when the sign-in is dead, the refresh button opens `claude auth login`
- Falls back to the Claude desktop app's numbers when the CLI sign-in cannot be used
- Cost tab: what Claude Code use on this computer would cost at API prices, by period, model, day and hour (counting rules from ccusage, MIT)
- Peak hours clock on the Limits tab, with how long until the next peak or until the current one ends
- Cost tab: loads when the popup opens (switching tabs is instant) and unloads when it closes; counts the logs once in the background at start, opens on Today, and can be turned off (which deletes its cache)
- Settings in five sections (Panel, Popup, Warning levels, Colors, Account): which limits the popup shows, peak hours clock on or off, Cost tab opens on Today or the last period
- QML and Python (standard library) only; install with `python3 install.py`
