import asyncio
import os
import sqlite3
import tempfile
import unittest
from contextlib import closing
from pathlib import Path

from codex_sessions import READY, Session
from live_sessions import observe_all, session_labels
from desktop_sessions import CodexDesktopSessions, IN_PROGRESS


class DesktopTests(unittest.TestCase):
    root_id = "11111111-1111-4111-8111-111111111111"
    child_id = "22222222-2222-4222-8222-222222222222"
    closed_id = "33333333-3333-4333-8333-333333333333"

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name)
        self.proc = self.home / "proc"
        self.proc.mkdir()
        server = self.proc / "437"
        server.mkdir()
        (server / "exe").symlink_to("/usr/lib/chatgpt/resources/codex")
        (server / "cmdline").write_bytes(b"codex\0app-server\0--analytics-default-enabled\0")
        locks = self.home / "thread-writer-locks"
        locks.mkdir()
        lines = []
        for thread_id in (self.root_id, self.child_id, self.closed_id):
            path = locks / f"{thread_id}.lock"
            path.touch()
            if thread_id != self.closed_id:
                st = path.stat()
                lines.append(f"1: FLOCK ADVISORY WRITE 437 {os.major(st.st_dev):02x}:{os.minor(st.st_dev):02x}:{st.st_ino} 0 EOF")
        (self.proc / "locks").write_text("\n".join(lines))
        with closing(sqlite3.connect(self.home / "state_5.sqlite")) as db:
            db.execute("create table threads(id, cwd, name, source, thread_source, attached_thread_parent_id, archived)")
            db.executemany("insert into threads values(?, '/work/Loja', ?, ?, ?, null, 0)", [
                (self.root_id, "Rever estoque", "vscode", "user"),
                (self.child_id, "Agente", "{}", "subagent"),
                (self.closed_id, "Antiga", "vscode", "user")])
            db.commit()
        with closing(sqlite3.connect(self.home / "thread_history_1.sqlite")) as db:
            db.execute("create table thread_turns(thread_id, rollout_ordinal, status)")
            db.executemany("insert into thread_turns values(?, ?, ?)", [
                (self.root_id, 1, "completed"), (self.root_id, 2, "inProgress")])
            db.commit()

    def test_only_open_desktop_root_and_its_latest_turn(self):
        reader = CodexDesktopSessions(self.home, self.proc)
        row, = reader.snapshot()
        self.assertEqual(row, Session(self.root_id, "/work/Loja", IN_PROGRESS, "Codex Desktop", "Rever estoque"))
        self.assertIn("Codex Desktop · Loja", session_labels([row])[0])
        with closing(sqlite3.connect(self.home / "thread_history_1.sqlite")) as db:
            db.execute("update thread_turns set status='completed' where rollout_ordinal=2")
            db.commit()
        self.assertEqual(reader.snapshot()[0].state, READY)
        (self.proc / "locks").write_text("")
        self.assertEqual(reader.snapshot(), [])

    def test_shared_server_does_not_count_as_desktop(self):
        (self.proc / "437/exe").unlink()
        (self.proc / "437/exe").symlink_to("/usr/bin/codex")
        self.assertEqual(CodexDesktopSessions(self.home, self.proc).snapshot(), [])

    def test_desktop_shows_alongside_claude_with_no_cli(self):
        result = []
        async def desktop(post):
            post(CodexDesktopSessions(self.home, self.proc).snapshot(), None)
        async def cli(post):
            post([], "Aguardando o Codex CLI")
        async def claude(post):
            post([Session("a", "/work/API", READY, "Claude Code")], None)
        asyncio.run(observe_all(lambda rows, _: result.append(rows), cli, claude, desktop))
        self.assertEqual({s.tool for s in result[-1]}, {"Codex Desktop", "Claude Code"})
