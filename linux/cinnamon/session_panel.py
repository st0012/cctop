"""The GTK window opened by the Cinnamon status icon."""

from dataclasses import replace
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, Gio, Gtk, Pango

from codex_sessions import ERROR, IDLE, IN_PROGRESS, PERMISSION, READY, REPLY, UNKNOWN, WORKING
from live_sessions import session_captions
from panel_preferences import MODES, PALETTES, TOOLS, Preferences, theme_colors


PANEL_WIDTH = 364
GAP = 5
IDLE_STATES = (IDLE, READY, UNKNOWN)
ALERT_STATES = (PERMISSION, REPLY, ERROR)
TONES = {
    PERMISSION: "permission", REPLY: "waiting", ERROR: "permission",
    WORKING: "working", IN_PROGRESS: "working", READY: "ready",
    IDLE: "quiet", UNKNOWN: "quiet",
}


def anchored_position(x, y, edge, workarea, width, height):
    """XApp reports the point on the icon's edge facing the desktop."""
    if edge in (Gtk.PositionType.TOP, Gtk.PositionType.BOTTOM):
        left = x - width // 2
        top = y + GAP if edge == Gtk.PositionType.TOP else y - height - GAP
    else:
        top = y - height // 2
        left = x + GAP if edge == Gtk.PositionType.LEFT else x - width - GAP
    return (max(workarea.x, min(left, workarea.x + workarea.width - width)),
            max(workarea.y, min(top, workarea.y + workarea.height - height)))


def styled(widget, *classes):
    for name in classes:
        widget.get_style_context().add_class(name)
    return widget


def text_label(text, style):
    return styled(Gtk.Label(label=text, xalign=0), style)


def segmented(options, selected, on_select):
    bar = styled(Gtk.Box(spacing=2, homogeneous=True), "segments")
    buttons = {}
    first = None
    for option in options:
        button = Gtk.RadioButton.new_with_label_from_widget(first, option)
        if first is None:
            first = button
        button.set_mode(False)
        button.set_active(option == selected)
        styled(button, "segment")
        bar.pack_start(button, True, True, 0)
        buttons[option] = button
    for option, button in buttons.items():
        button.connect("toggled", lambda b, value: on_select(value) if b.get_active() else None, option)
    return bar, buttons


class SessionPanel(Gtk.Window):
    def __init__(self, app, settings_path, on_filter_changed, advance=None):
        super().__init__(application=app, title="cctop", decorated=False, resizable=False)
        self.set_name("lcctop-panel")
        self.set_type_hint(Gdk.WindowTypeHint.UTILITY)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_keep_above(True)
        visual = self.get_screen().get_rgba_visual()
        if visual is not None:
            self.set_visual(visual)
        self.anchor = None
        self.active_tab = "Active"
        self.sessions = ()
        self.message = ""
        self.settings_path = settings_path
        self.preferences = Preferences.load(settings_path)
        self.on_filter_changed = on_filter_changed
        self.applied_theme = None
        self.css = Path(__file__).with_name("panel.css").read_text(encoding="utf-8")
        self.provider = Gtk.CssProvider()
        Gtk.StyleContext.add_provider_for_screen(self.get_screen(), self.provider,
                                                 Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        self.portal = None
        source = Gio.SettingsSchemaSource.get_default()
        schema = source.lookup("org.x.apps.portal", True) if source else None
        if schema and schema.has_key("color-scheme"):
            self.portal = Gio.Settings.new_full(schema, None, None)
            self.portal.connect("changed::color-scheme", self.apply_appearance)
        gtk_settings = self.get_settings()
        gtk_settings.connect("notify::gtk-theme-name", self.apply_appearance)
        gtk_settings.connect("notify::gtk-application-prefer-dark-theme", self.apply_appearance)
        self.apply_appearance()

        self.root = styled(Gtk.Box(orientation=Gtk.Orientation.VERTICAL), "panel-body")
        self.add(self.root)
        self.header = styled(Gtk.Box(spacing=7), "panel-header")
        self.logo = Gtk.Image()
        self.header.pack_start(self.logo, False, False, 0)
        self.heading = text_label("cctop", "wordmark")
        self.header.pack_start(self.heading, True, True, 0)
        self.badges = {}
        for tone, description in (("permission", "Pedem permissão ou estão em erro"),
                                  ("waiting", "Aguardam sua resposta"), ("working", "Em andamento")):
            label = styled(Gtk.Label(), "count", tone)
            label.set_tooltip_text(description)
            self.header.pack_start(label, False, False, 0)
            self.badges[tone] = label
        self.root.pack_start(self.header, False, False, 0)
        self.tabs, self.tab_buttons = segmented(("Active", "Idle"), self.active_tab, self.select_tab)
        self.tabs.set_margin_start(12)
        self.tabs.set_margin_end(12)
        self.root.pack_start(self.tabs, False, False, 0)

        self.scroll = Gtk.ScrolledWindow()
        self.scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.scroll.set_propagate_natural_height(True)
        self.scroll.set_max_content_height(360)
        self.stack = Gtk.Stack(homogeneous=False)
        self.rows = styled(Gtk.Box(orientation=Gtk.Orientation.VERTICAL), "session-list")
        self.stack.add_named(self.rows, "sessions")
        self.stack.add_named(self.build_settings(), "settings")
        self.stack.set_visible_child_name("sessions")
        self.scroll.add(self.stack)
        self.root.pack_start(self.scroll, True, True, 0)

        self.footer = styled(Gtk.Box(spacing=4), "panel-footer")
        quit_button = styled(Gtk.Button(label="Sair"), "flat")
        quit_button.set_tooltip_text("Sair do monitor" if advance is None else "Sair da demonstração")
        quit_button.connect("clicked", lambda _: app.quit())
        self.footer.pack_start(quit_button, False, False, 0)
        self.next_button = None
        if advance is not None:
            self.next_button = styled(Gtk.Button(label="Avançar"), "flat")
            self.next_button.connect("clicked", advance)
            self.footer.pack_start(self.next_button, False, False, 0)
        self.settings_button = styled(Gtk.Button(label="Settings"), "flat")
        self.settings_button.set_image(Gtk.Image.new_from_icon_name("emblem-system-symbolic", Gtk.IconSize.MENU))
        self.settings_button.set_always_show_image(True)
        self.settings_button.connect("clicked", lambda _: self.show_settings(not self.in_settings))
        self.footer.pack_end(self.settings_button, False, False, 0)
        self.root.pack_end(self.footer, False, False, 0)
        self.root.show_all()
        self.connect("delete-event", lambda *_: self.hide_on_delete())
        self.connect("key-press-event", self.on_key)
        self.connect("size-allocate", self.on_size_allocate)

    def build_settings(self):
        box = styled(Gtk.Box(orientation=Gtk.Orientation.VERTICAL), "settings")
        box.pack_start(text_label("Paleta", "setting-title"), False, False, 0)
        palettes, self.palette_buttons = segmented(PALETTES, self.preferences.palette,
                                                   lambda value: self.change_preferences(palette=value))
        box.pack_start(palettes, False, False, 0)
        box.pack_start(text_label("Modo", "setting-title"), False, False, 0)
        modes, self.mode_buttons = segmented(MODES, self.preferences.mode,
                                            lambda value: self.change_preferences(mode=value))
        box.pack_start(modes, False, False, 0)
        box.pack_start(text_label("Ferramentas", "setting-title"), False, False, 0)
        self.tool_buttons = {}
        for tool in TOOLS:
            button = styled(Gtk.CheckButton(label=tool), "tool")
            button.set_active(tool in self.preferences.tools)
            self.tool_buttons[tool] = button
            button.connect("toggled", self.select_tools)
            box.pack_start(button, False, False, 0)
        self.save_error = text_label("Não foi possível salvar as preferências neste computador.", "save-error")
        self.save_error.set_line_wrap(True)
        self.save_error.set_no_show_all(True)
        box.pack_start(self.save_error, False, False, 0)
        return box

    def system_mode(self):
        scheme = self.portal.get_string("color-scheme") if self.portal else "default"
        if scheme in ("prefer-dark", "prefer-light"):
            return "Escuro" if scheme == "prefer-dark" else "Claro"
        settings = self.get_settings()
        if settings.get_property("gtk-application-prefer-dark-theme"):
            return "Escuro"
        name = settings.get_property("gtk-theme-name") or ""
        if "dark" in name.lower():
            return "Escuro"
        found, bg = self.get_style_context().lookup_color("theme_bg_color")
        if found and (0.2126 * bg.red + 0.7152 * bg.green + 0.0722 * bg.blue) < 0.5:
            return "Escuro"
        return "Claro"

    def apply_appearance(self, *_):
        mode = self.preferences.mode
        theme = self.preferences.palette, self.system_mode() if mode == "Sistema" else mode
        if self.applied_theme != theme:
            self.provider.load_from_data((theme_colors(*theme) + self.css).encode())
            self.applied_theme = theme

    def select_tools(self, _button):
        self.change_preferences(tools=frozenset(t for t, b in self.tool_buttons.items() if b.get_active()))

    def change_preferences(self, **changes):
        previous = self.preferences
        self.preferences = replace(previous, **changes)
        self.apply_appearance()
        try:
            self.preferences.save(self.settings_path)
            self.save_error.hide()
        except OSError:
            self.save_error.show()
        if self.preferences.tools != previous.tools:
            self.on_filter_changed()

    @property
    def in_settings(self):
        return self.stack.get_visible_child_name() == "settings"

    def show_settings(self, show):
        self.heading.set_text("Settings" if show else "cctop")
        self.tabs.set_visible(not show)
        self.stack.set_visible_child_name("settings" if show else "sessions")
        self.settings_button.set_label("Voltar às sessões" if show else "Settings")
        icon = "go-previous-symbolic" if show else "emblem-system-symbolic"
        self.settings_button.get_image().set_from_icon_name(icon, Gtk.IconSize.MENU)
        self.scroll.get_vadjustment().set_value(0)
        focus = self.palette_buttons[self.preferences.palette] if show else self.tab_buttons[self.active_tab]
        focus.grab_focus()

    def on_key(self, _window, event):
        if event.keyval == Gdk.KEY_Escape:
            if self.in_settings:
                self.show_settings(False)
            else:
                self.hide()
            return True
        return False

    def toggle_at(self, x, y, edge, timestamp):
        display = self.get_display()
        # At a shared monitor edge, look one pixel toward the monitor's interior.
        monitor = display.get_monitor_at_point(x - int(edge == Gtk.PositionType.RIGHT),
                                               y - int(edge == Gtk.PositionType.BOTTOM))
        if self.get_visible() and self.anchor and self.anchor[3] == monitor:
            self.hide()
            return
        self.anchor = (x, y, edge, monitor)
        area = monitor.get_workarea()
        if self.in_settings:
            self.show_settings(False)
        self.set_size_request(min(PANEL_WIDTH, area.width), -1)
        chrome = sum(w.get_preferred_height().natural_height for w in (self.header, self.tabs, self.footer))
        self.scroll.set_max_content_height(max(1, min(360, area.height - chrome - 2 * GAP - 4)))
        natural = self.root.get_preferred_size().natural_size
        self.move(*anchored_position(x, y, edge, area, min(PANEL_WIDTH, area.width), natural.height))
        self.show()
        self.present_with_time(timestamp)
        self.on_size_allocate(self, self.get_allocation())

    def on_size_allocate(self, _window, allocation):
        if self.anchor and self.get_visible():
            x, y, edge, monitor = self.anchor
            self.move(*anchored_position(x, y, edge, monitor.get_workarea(),
                                         allocation.width, allocation.height))

    def select_tab(self, tab):
        self.active_tab = tab
        self.render_rows()
        self.scroll.get_vadjustment().set_value(0)

    def update_sessions(self, sessions, counts, message):
        self.sessions = sessions
        self.message = message
        idle = sum(counts[state] for state in IDLE_STATES)
        self.tab_buttons["Idle"].set_label(f"Idle  {idle}")
        self.tab_buttons["Active"].set_label(f"Active  {len(sessions) - idle}")
        for tone, n in (("permission", counts[PERMISSION] + counts[ERROR]), ("waiting", counts[REPLY]),
                        ("working", counts[WORKING] + counts[IN_PROGRESS])):
            badge = self.badges[tone]
            badge.set_text(f"● {n}")
            badge.get_accessible().set_name(f"{badge.get_tooltip_text()}: {n}")
            badge.set_visible(n > 0)
        self.render_rows()

    def render_rows(self):
        for child in self.rows.get_children():
            child.destroy()
        for session, caption in zip(self.sessions, session_captions(self.sessions)):
            if (session.state in IDLE_STATES) != (self.active_tab == "Idle"):
                continue
            project, title = caption
            row = styled(Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3), "session-card")
            top = Gtk.Box(spacing=7)
            heading = text_label(title or project, "session-title")
            heading.set_ellipsize(Pango.EllipsizeMode.MIDDLE)
            heading.set_single_line_mode(True)
            heading.set_tooltip_text(title or project)
            top.pack_start(heading, True, True, 0)
            state = styled(Gtk.Label(label="●  " + session.state), "session-state", TONES[session.state])
            top.pack_end(state, False, False, 0)
            row.pack_start(top, False, False, 0)
            detail = text_label(f"{project} · {session.tool}" if title else session.tool, "session-detail")
            detail.set_ellipsize(Pango.EllipsizeMode.MIDDLE)
            detail.set_single_line_mode(True)
            detail.set_tooltip_text(detail.get_text())
            row.pack_start(detail, False, False, 0)
            self.rows.pack_start(row, False, False, 0)
        if not self.rows.get_children() and not self.message:
            self.rows.pack_start(text_label(f"Nenhuma sessão em {self.active_tab}", "empty"), False, False, 0)
        if self.message:
            note = text_label(self.message, "empty")
            note.set_line_wrap(True)
            self.rows.pack_start(note, False, False, 0)
        self.rows.show_all()
