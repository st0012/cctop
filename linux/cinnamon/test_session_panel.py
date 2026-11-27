import json
import tempfile
import unittest
from collections import Counter
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

from cctop_demo import GdkPixbuf, Gio, Gtk, TrayApp
from codex_sessions import ERROR, IDLE, IN_PROGRESS, PERMISSION, READY, REPLY, UNKNOWN, WORKING, Session
from live_sessions import session_captions
from panel_preferences import PALETTES, TOOLS, Preferences
from session_panel import GAP, SessionPanel, anchored_position


class PreferencesTests(unittest.TestCase):
    def test_first_use_and_damaged_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "settings.json"
            defaults = Preferences("Claude", "Sistema", frozenset(TOOLS))
            self.assertEqual(Preferences.load(path), defaults)
            for content in ("{", "null", '{"palette": [], "mode": "invalid", "tools": false}'):
                path.write_text(content)
                self.assertEqual(Preferences.load(path), defaults)

    def test_round_trip_including_an_empty_selection(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "lcctop" / "settings.json"
            for tools in (frozenset(TOOLS[1:]), frozenset()):
                chosen = Preferences("Tokyo Night", "Escuro", tools)
                chosen.save(path)
                self.assertEqual(Preferences.load(path), chosen)
            self.assertEqual(json.loads(path.read_text())["tools"], [])
            self.assertEqual(list(path.parent.iterdir()), [path])


class PositionTests(unittest.TestCase):
    def test_faces_the_icon_on_each_edge_of_a_secondary_monitor(self):
        area = SimpleNamespace(x=-1920, y=24, width=1920, height=1056)
        for edge, anchor, expected in (
            (Gtk.PositionType.TOP, (-170, 24), (-364, 24 + GAP)),
            (Gtk.PositionType.BOTTOM, (-1880, 1080), (-1920, 1080 - 260 - GAP)),
            (Gtk.PositionType.LEFT, (-1920, 500), (-1920 + GAP, 370)),
            (Gtk.PositionType.RIGHT, (0, 25), (-364 - GAP, 24)),
        ):
            with self.subTest(edge=edge):
                self.assertEqual(anchored_position(*anchor, edge, area, 364, 260), expected)


class TrayFilterTests(unittest.TestCase):
    def setUp(self):
        self.app = TrayApp(False)
        self.app.indicator = Mock()
        self.app.panel = Mock()
        self.app.panel.preferences = Preferences()
        self.app.icon_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.app.icon_dir.cleanup)
        self.rows = [Session("1", "/work/A", PERMISSION, "Claude Code"),
                     Session("2", "/work/B", WORKING, "Codex CLI"),
                     Session("3", "/work/C", IDLE, "Codex Desktop")]

    def select(self, tools):
        self.app.panel.preferences = Preferences(tools=frozenset(tools))
        self.app.render_sessions()
        return self.app.panel.update_sessions.call_args.args

    def has_alert(self):
        icon_path, = self.app.indicator.set_icon_name.call_args.args
        icon = GdkPixbuf.Pixbuf.new_from_file(icon_path)
        # Above the bar, inside the circular exclamation badge.
        offset = 20 * icon.get_rowstride() + 140 * icon.get_n_channels()
        return icon.get_pixels()[offset + 3] != 0

    def test_filter_repaints_counts_tooltip_and_icon_without_another_observation(self):
        self.app.refresh(self.rows, {"Claude Code": "Fonte indisponível"})
        self.assertTrue(self.has_alert())
        rows, counts, note = self.select(TOOLS[1:])
        self.assertEqual((rows, counts, note), (self.rows[1:], Counter([WORKING, IDLE]), ""))
        self.assertFalse(self.has_alert())
        self.app.indicator.set_tooltip_text.assert_called_with("cctop · Sessões com alerta: 0/2")
        self.select(TOOLS)
        self.assertTrue(self.has_alert())
        rows, counts, note = self.select([])
        self.assertEqual((rows, counts), ([], Counter()))
        self.assertIn("Settings", note)
        self.assertFalse(self.has_alert())

    def test_each_visible_permission_reply_or_error_keeps_the_alert(self):
        for state in (REPLY, ERROR):
            with self.subTest(state=state):
                self.app.refresh([self.rows[0], Session("2", "/work/B", state)], {})
                self.select(["Claude Code"])
                self.assertTrue(self.has_alert())
                self.select(["Codex CLI"])
                self.assertTrue(self.has_alert())
                self.select(["Codex Desktop"])
                self.assertFalse(self.has_alert())
        for state in (WORKING, IN_PROGRESS, READY, IDLE, UNKNOWN):
            self.app.refresh([Session("2", "/work/B", state)], {})
            self.select(TOOLS)
            self.assertFalse(self.has_alert(), state)

    def test_same_project_keeps_its_path_title_or_identifier(self):
        rows = [Session("001", "/a/Loja", WORKING), Session("002", "/b/Loja", READY),
                Session("003", "/b/Loja", READY),
                Session("dsk", "/a/Loja", READY, "Codex Desktop", "Revisar catálogo")]
        self.assertEqual(list(session_captions(rows)), [("/a/Loja", ""), ("/b/Loja [002]", ""),
                                                       ("/b/Loja [003]", ""), ("Loja", "Revisar catálogo")])


def label_texts(container):
    if isinstance(container, Gtk.Label):
        return [container.get_text()]
    return [text for child in container.get_children() for text in label_texts(child)]


def contrast(foreground, background):
    def luminance(color):
        def linear(channel):
            return channel / 12.92 if channel <= 0.04045 else ((channel + 0.055) / 1.055) ** 2.4
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    a, b = sorted((luminance(foreground), luminance(background)))
    return (b + 0.05) / (a + 0.05)


@unittest.skipUnless(Gtk.init_check()[0], "requer uma sessão gráfica GTK")
class NativePanelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.gtk_app = Gtk.Application(application_id="local.lcctop.NativeTest", flags=Gio.ApplicationFlags.NON_UNIQUE)
        cls.gtk_app.register(None)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        app = TrayApp(False)
        # Exercise real GTK controls without putting a test indicator on the user's panel.
        app.indicator = Mock()
        app.icon_dir = self.tmp
        app.panel = SessionPanel(self.gtk_app, Path(self.tmp.name) / "settings.json", app.render_sessions, app.advance)
        app.refresh_demo()
        self.app = app
        self.panel = app.panel
        self.addCleanup(self.panel.destroy)

    def test_same_session_moves_from_active_to_idle_and_back(self):
        app, panel = self.app, self.panel
        for state, active, idle in ((WORKING, 2, 1), (READY, 1, 2), (WORKING, 2, 1)):
            sessions = [Session("claude", "/repo/Loja", PERMISSION, "Claude Code"),
                        Session("cli", "/repo/Loja", state),
                        Session("desktop", "/repo/Loja", UNKNOWN, "Codex Desktop", "Revisar loja")]
            app.refresh(sessions, {})
            self.assertEqual(panel.tab_buttons["Active"].get_label(), f"Active  {active}")
            self.assertEqual(panel.tab_buttons["Idle"].get_label(), f"Idle  {idle}")
            for tab in ("Active", "Idle"):
                panel.tab_buttons[tab].set_active(True)
                texts = label_texts(panel.rows)
                self.assertEqual(texts.count("Codex CLI"), int((tab == "Idle") == (state == READY)))
                if tab == "Idle":
                    self.assertIn("●  " + UNKNOWN, texts)
                    self.assertIn("Loja · Codex Desktop", texts)

    def test_settings_filters_the_open_panel_and_returns_to_the_selected_tab(self):
        app, panel = self.app, self.panel
        app.stage = 4
        app.refresh_demo()
        panel.tab_buttons["Idle"].set_active(True)
        panel.settings_button.clicked()
        self.assertTrue(panel.in_settings)
        for enabled, active in ((False, 1), (True, 2)):
            panel.tool_buttons["Claude Code"].set_active(enabled)
            self.assertEqual(panel.tab_buttons["Active"].get_label(), f"Active  {active}")
            self.assertEqual(panel.tab_buttons["Idle"].get_label(), "Idle  1")
        for button in panel.tool_buttons.values():
            button.set_active(False)
        panel.settings_button.clicked()
        self.assertFalse(panel.in_settings)
        self.assertEqual(panel.active_tab, "Idle")
        self.assertTrue(panel.settings_button.is_sensitive())
        self.assertEqual(panel.tab_buttons["Idle"].get_label(), "Idle  0")
        self.assertIn("Selecione uma ferramenta em Settings.", label_texts(panel.rows))
        self.assertEqual(Preferences.load(panel.settings_path).tools, frozenset())

    def test_all_palettes_and_live_system_mode(self):
        panel = self.panel
        panel.settings_button.clicked()
        for palette in PALETTES:
            panel.palette_buttons[palette].set_active(True)
            for mode in ("Escuro", "Claro"):
                panel.mode_buttons[mode].set_active(True)
                self.assertEqual(panel.applied_theme, (palette, mode))
                self.assertEqual(Preferences.load(panel.settings_path), Preferences(palette, mode))
        if panel.portal is None:
            self.skipTest("requer o esquema de aparência do Cinnamon")
        # Deliver a real GSettings change signal using a private, in-memory backend.
        schema = panel.portal.props.settings_schema
        panel.portal = Gio.Settings.new_full(schema, Gio.memory_settings_backend_new(), None)
        panel.portal.connect("changed::color-scheme", panel.apply_appearance)
        panel.mode_buttons["Sistema"].set_active(True)
        for scheme, mode in (("prefer-dark", "Escuro"), ("prefer-light", "Claro")):
            panel.portal.set_string("color-scheme", scheme)
            self.assertEqual(panel.applied_theme, ("Nord", mode))

    def test_small_text_contrast_in_each_palette_and_mode(self):
        panel = self.panel
        self.app.stage = 1
        self.app.refresh_demo()
        for palette in PALETTES:
            panel.palette_buttons[palette].set_active(True)
            for mode in ("Claro", "Escuro"):
                panel.mode_buttons[mode].set_active(True)
                for widget in (*panel.badges.values(), panel.tab_buttons["Active"]):
                    ctx = widget.get_style_context()
                    state = ctx.get_state()
                    background = ctx.get_property("background-color", state)
                    self.assertGreaterEqual(contrast(ctx.get_color(state), background), 4.5,
                                            (palette, mode, widget.get_label()))
