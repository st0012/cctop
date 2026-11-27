# cctop for Cinnamon

The tray icon shows when a Claude Code or Codex session needs your attention.
Click it to see which project is waiting for permission or a reply. The panel
groups sessions into Active and Idle and lets you filter by tool. This
experimental Linux client was developed on Linux Mint 22.2 with Cinnamon on
X11. Its interface includes Portuguese labels.

## Try it on Linux Mint

Enable the **XApp Status Applet** in Cinnamon's panel. The client uses the
system Python (3.11 or later), GTK 3 and XApp. Install their packages on
Mint 22.2 with `apt`.

```sh
sudo apt install python3-gi python3-cairo gir1.2-gtk-3.0 gir1.2-xapp-1.0 python3-websockets
```

Run the demo from the repository root to see three sample sessions.

```sh
/usr/bin/python3 linux/cinnamon/cctop_demo.py
```

Click the tray icon and select **Avançar** to step through permission, reply
and completion states. Select **Sair** to quit. Start the live monitor with
`--live` to see your own sessions.

```sh
/usr/bin/python3 linux/cinnamon/cctop_demo.py --live
```

To launch it from the Cinnamon menu, add a custom launcher for the live command
using the absolute path to `cctop_demo.py`. The **Settings** panel saves the
palette, light/dark preference and selected tools in
`$XDG_CONFIG_HOME/lcctop/settings.json` (usually `~/.config/lcctop/settings.json`).

## Session sources

| Tool | How the panel finds open sessions |
| --- | --- |
| Claude Code | Reads local session registrations and checks the process identity in `/proc`. Displays a session name when the user assigned it. |
| Codex CLI | Queries loaded threads over the local app-server Unix socket. For an idle thread, it requests the latest turn status with its items omitted. |
| Codex Desktop | Matches live writer locks in `/proc/locks` to the desktop app-server and reads the thread name and latest turn status from local SQLite databases. |

The live monitor polls these sources every two seconds. A tool can be absent
while the others continue to report. The Codex interfaces are version-dependent,
including the experimental CLI API and the Desktop database schema.

The scope here is session monitoring on Cinnamon. Jumping to a session, other
desktop environments and the upstream macOS hook integrations are outside this
prototype. The Linux client runs directly from this directory.

## Tests

Run the suite from the repository root.

```sh
/usr/bin/python3 -m unittest discover -s linux/cinnamon -v
```

Run the suite from a graphical Cinnamon session to include the GTK panel tests.
The tests use temporary session records, databases and preferences.
