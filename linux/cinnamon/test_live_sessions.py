import asyncio
import json
import tempfile
import unittest
from pathlib import Path

from codex_sessions import IDLE, PERMISSION, REPLY, WORKING, Session
from live_sessions import ClaudeSessions, observe_all, session_labels


class ClaudeSessionTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.records = self.root / "sessions"
        self.records.mkdir()
        self.reader = ClaudeSessions(self.records, self.root / "proc")

    def record(self, pid, **kwargs):
        data = dict(pid=pid, procStart="123", cwd="/work/Loja/.claude/worktrees/branch-01",
                    sessionId=f"session-{pid}", entrypoint="claude-desktop", kind="interactive",
                    name="Revisar catálogo", nameSource="user", status="idle")
        data.update(kwargs)
        (self.records / f"{pid}.json").write_text(json.dumps(data))

    def process(self, pid, birth="123", state="S"):
        path = self.root / "proc" / str(pid)
        path.mkdir(parents=True)
        (path / "stat").write_text(f"{pid} (claude (UI)) {state} " + "0 " * 18 + birth)

    def test_open_desktop_worktree_all_transitions_and_close(self):
        self.process(42)
        for status, reason, expected in [("busy", "", WORKING), ("waiting", "input needed", REPLY),
                                         ("waiting", "permission prompt", PERMISSION), ("idle", "", IDLE)]:
            self.record(42, status=status, waitingFor=reason)
            sessions = self.reader.snapshot()
            self.assertEqual(len(sessions), 1)
            self.assertEqual((sessions[0].project, sessions[0].state), ("Loja", expected))
            row, = session_labels(sessions)
            for field in ("Claude Code", "Loja", "Revisar catálogo", expected):
                self.assertIn(field, row)
        (self.root / "proc/42/stat").unlink()
        self.assertEqual(self.reader.snapshot(), [])

    def test_reused_pid_zombie_and_partial_write_do_not_hide_live_session(self):
        self.process(10, birth="456")
        self.process(11, state="Z")
        self.process(12)
        for pid in (10, 11, 12, 13):
            self.record(pid)
        (self.records / "14.json").write_text("{")
        self.assertEqual([s.id for s in self.reader.snapshot()], ["session-12"])

    def test_duplicate_process_registration_and_derived_title(self):
        for pid in (41, 42):
            self.process(pid)
            self.record(pid, sessionId="same", nameSource="derived", updatedAt=pid,
                        status="busy" if pid == 42 else "idle")
        sessions = self.reader.snapshot()
        self.assertEqual([s.state for s in sessions], [WORKING])
        self.assertNotIn("Revisar catálogo", session_labels(sessions)[0])


class CombinedTests(unittest.IsolatedAsyncioTestCase):
    async def test_codex_disconnect_keeps_claude_and_reconnect_orders_both(self):
        claude = Session("claude-session", "/work/A", WORKING, "Claude Code")
        codex = Session("codex-session", "/work/B", PERMISSION)
        seen = []
        published = asyncio.Event()

        async def claude_feed(post):
            post([claude], None)
            published.set()

        async def codex_feed(post):
            await published.wait()
            post([], "Aguardando o Codex CLI")
            post([codex], None)

        async def desktop_feed(post):
            post([], None)

        await observe_all(lambda rows, note: seen.append((rows, note)), codex_feed, claude_feed, desktop_feed)
        self.assertIn(([claude], None), seen)
        self.assertEqual(seen[-1], ([codex, claude], None))
