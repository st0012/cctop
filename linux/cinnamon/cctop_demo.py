#!/usr/bin/python3
"""Sessões de Claude Code e Codex (desktop e terminal) na bandeja do Cinnamon."""

import argparse
import asyncio
import signal
import threading
from collections import Counter
from math import pi
from pathlib import Path
from tempfile import TemporaryDirectory

import cairo
import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("XApp", "1.0")
from gi.repository import Gdk, GdkPixbuf, Gio, GLib, Gtk, XApp

from codex_sessions import ERROR, IDLE, IN_PROGRESS, ORDER, PERMISSION, READY, REPLY, UNKNOWN, WORKING, Session
from live_sessions import observe_all
from panel_preferences import TOOLS
from session_panel import ALERT_STATES, SessionPanel

PROJECTS = ("Loja", "Site", "API")
SCENES = (
    (WORKING, WORKING, WORKING),
    (PERMISSION, REPLY, WORKING),
    (WORKING, REPLY, WORKING),
    (WORKING, WORKING, WORKING),
    (PERMISSION, WORKING, IDLE),
    (PERMISSION, READY, IDLE),
)
COLORS = {
    WORKING: (0.26, 0.77, 0.64),
    IN_PROGRESS: (0.26, 0.77, 0.64),
    REPLY: (1.0, 0.76, 0.32),
    PERMISSION: (1.0, 0.48, 0.34),
    READY: (0.45, 0.72, 0.95),
    IDLE: (0.61, 0.65, 0.68),
    UNKNOWN: (0.61, 0.65, 0.68),
    ERROR: (0.95, 0.42, 0.44),
}


def draw_icon(states, path):
    """Draw a segmented bar and add a distinct silhouette for pending work."""
    scale = 4
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, 44 * scale, 22 * scale)
    ctx = cairo.Context(surface)
    ctx.scale(scale, scale)
    counts = Counter(states)
    pending = sum(counts[state] for state in ALERT_STATES)
    end = 27 if pending else 38
    ctx.set_line_cap(cairo.LINE_CAP_ROUND)
    ctx.set_line_width(9)
    ctx.set_source_rgb(0.11, 0.16, 0.19)
    ctx.move_to(6, 11)
    ctx.line_to(end, 11)
    ctx.stroke()

    # Clip the colored segments to the inside of the pill.
    radius = 3.25
    ctx.save()
    ctx.arc(6, 11, radius, pi / 2, 3 * pi / 2)
    ctx.arc(end, 11, radius, -pi / 2, pi / 2)
    ctx.close_path()
    ctx.clip()
    x = 6 - radius
    if not states:
        ctx.set_source_rgb(*COLORS[IDLE])
        ctx.paint()
    for state, color in COLORS.items():
        if not counts[state]:
            continue
        width = (end - 6 + 2 * radius) * counts[state] / counts.total()
        ctx.set_source_rgb(*color)
        ctx.rectangle(x, 11 - radius, width, 2 * radius)
        ctx.fill()
        x += width
    ctx.restore()

    if pending:
        ctx.set_source_rgb(*COLORS[REPLY])
        ctx.arc(35, 11, 8, 0, 2 * pi)
        ctx.fill_preserve()
        ctx.set_source_rgb(0.11, 0.16, 0.19)
        ctx.set_line_width(1.5)
        ctx.stroke()
        ctx.set_line_width(2.4)
        ctx.move_to(35, 7)
        ctx.line_to(35, 11.5)
        ctx.stroke()
        ctx.arc(35, 15, 1.2, 0, 2 * pi)
        ctx.fill()
    surface.write_to_png(str(path))


class TrayApp(Gtk.Application):
    def __init__(self, live):
        super().__init__(application_id="local.lcctop.Live" if live else "local.lcctop.Demo",
                         flags=Gio.ApplicationFlags.FLAGS_NONE)
        self.live = live
        self.stage = 0
        self.indicator = None
        self.previous = None
        self.icon_key = None
        self.icon_number = 0

    def do_activate(self):
        if self.indicator is not None:
            return
        self.hold()
        self.icon_dir = TemporaryDirectory(prefix="lcctop-",
                                           dir=GLib.get_user_runtime_dir())
        settings_path = Path(GLib.get_user_config_dir()) / "lcctop" / "settings.json"
        self.panel = SessionPanel(self, settings_path, self.render_sessions, None if self.live else self.advance)
        self.indicator = XApp.StatusIcon.new_with_name("lcctop-live" if self.live else "lcctop-demo")
        self.indicator.connect("button-release-event", self.on_icon_release)
        if self.live:
            self.refresh([], {}, "Procurando sessões locais…")
            def publish(sessions, notes):
                GLib.idle_add(self.refresh, sessions, notes)
            threading.Thread(target=asyncio.run, args=(observe_all(publish, notes_by_tool=True),), daemon=True).start()
        else:
            self.refresh_demo()
        self.indicator.set_visible(True)
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, self.quit)

    def on_icon_release(self, _indicator, x, y, button, timestamp, edge):
        if button == Gdk.BUTTON_PRIMARY:
            self.panel.toggle_at(x, y, edge, timestamp)

    def refresh_demo(self):
        states = SCENES[self.stage]
        last = self.stage == len(SCENES) - 1
        self.panel.next_button.set_label("Reiniciar" if last else "Avançar")
        self.panel.next_button.set_tooltip_text("Reiniciar demonstração" if last else "Avançar demonstração")
        titles = ("Revisar catálogo", "", "Conferir integração")
        sessions = [Session(name, name, state, tool, title)
                    for name, state, tool, title in zip(PROJECTS, states, TOOLS, titles)]
        self.refresh(sorted(sessions, key=lambda s: ORDER.index(s.state)), {})

    def refresh(self, sessions, notes, loading=None):
        snapshot = (sessions, notes, loading)
        if snapshot != self.previous:
            self.previous = snapshot
            self.render_sessions()

    def render_sessions(self):
        rows, notes, loading = self.previous
        selected = self.panel.preferences.tools
        sessions = [s for s in rows if s.tool in selected]
        message = loading or " · ".join(notes[t] for t in TOOLS if t in notes and t in selected)
        if not selected:
            message = "Selecione uma ferramenta em Settings."
        counts = Counter(s.state for s in sessions)
        self.panel.update_sessions(sessions, counts, message)
        pending = sum(counts[state] for state in ALERT_STATES)
        self.indicator.set_tooltip_text(f"cctop · Sessões com alerta: {pending}/{len(sessions)}")
        if counts != self.icon_key:
            self.icon_number += 1
            folder = Path(self.icon_dir.name)
            path = folder / f"barra-{self.icon_number}.png"
            draw_icon(counts, path)
            self.indicator.set_icon_name(str(path))
            self.panel.logo.set_from_pixbuf(GdkPixbuf.Pixbuf.new_from_file_at_scale(str(path), 29, 15, True))
            self.icon_key = counts
            # Cinnamon loads changed filenames asynchronously.
            (folder / f"barra-{self.icon_number - 4}.png").unlink(missing_ok=True)

    def advance(self, _item):
        self.stage = (self.stage + 1) % len(SCENES)
        self.refresh_demo()

    def do_shutdown(self):
        if self.indicator is not None:
            self.indicator.set_visible(False)
            self.icon_dir.cleanup()
        Gtk.Application.do_shutdown(self)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", help="acompanhar Claude Code, Codex Desktop e Codex CLI")
    args = parser.parse_args()
    GLib.set_prgname("lcctop-live" if args.live else "lcctop-demo")
    GLib.set_application_name("cctop · Sessões locais" if args.live else "cctop · Demonstração")
    raise SystemExit(TrayApp(args.live).run(["lcctop"]))
