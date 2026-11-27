"""Read the loaded Codex Desktop chats and their locally projected turn state."""

import asyncio
import os
import re
import sqlite3
from contextlib import closing
from pathlib import Path

from codex_sessions import ERROR, IDLE, IN_PROGRESS, READY, UNKNOWN, Session


THREAD_LOCK = re.compile(r"([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})\.lock")
TURN_STATES = {"inProgress": IN_PROGRESS, "completed": READY, "failed": ERROR, "interrupted": IDLE}


def desktop_server(proc, pid):
    try:
        executable = (proc / pid / "exe").readlink()
        if executable.name != "codex" or executable.parent.name != "resources":
            return False
        args = (proc / pid / "cmdline").read_bytes().split(b"\0")
        return b"app-server" in args and b"--analytics-default-enabled" in args
    except OSError:
        return False


def database_path(folder, prefix):
    versions = []
    for path in folder.glob(f"{prefix}_*.sqlite"):
        version = path.stem.removeprefix(prefix + "_")
        if version.isascii() and version.isdecimal():
            versions.append((int(version), path))
    return max(versions)[1] if versions else None


def read_only(path):
    return sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=0.3)


class CodexDesktopSessions:
    def __init__(self, home, proc=Path("/proc"), db_home=None):
        self.home = home
        self.db_home = db_home or home
        self.proc = proc

    def loaded(self):
        files = {}
        for path in (self.home / "thread-writer-locks").glob("*.lock"):
            match = THREAD_LOCK.fullmatch(path.name)
            if not match:
                continue
            try:
                info = path.stat()
            except FileNotFoundError:
                continue
            files[os.major(info.st_dev), os.minor(info.st_dev), info.st_ino] = match[1]
        if not files:
            return []
        owners = {}
        loaded = set()
        # A lock file can survive process exit. Match the actual kernel lock,
        # including device and inode, before looking up any chat metadata.
        for line in (self.proc / "locks").read_text().splitlines():
            parts = line.split()
            if len(parts) < 6 or parts[1:4] != ["FLOCK", "ADVISORY", "WRITE"]:
                continue
            major, minor, inode = parts[5].split(":")
            thread_id = files.get((int(major, 16), int(minor, 16), int(inode)))
            if thread_id:
                pid = parts[4]
                if pid not in owners:
                    owners[pid] = desktop_server(self.proc, pid)
                if owners[pid]:
                    loaded.add(thread_id)
        return sorted(loaded)

    def snapshot(self):
        ids = self.loaded()
        if not ids:
            return []
        state = database_path(self.db_home, "state")
        if not state:
            raise FileNotFoundError("Catálogo do Codex Desktop indisponível")
        params = ",".join("?" for _ in ids)
        with closing(read_only(state)) as db:
            rows = db.execute(f"""
                SELECT id, cwd, name FROM threads
                WHERE id IN ({params}) AND archived=0 AND attached_thread_parent_id IS NULL
                  AND source IN ('cli', 'vscode', 'appServer', 'unknown')
                  AND (thread_source IS NULL OR thread_source='user')
                """, ids).fetchall()
        states = {}
        history = database_path(self.db_home, "thread_history")
        if history and rows:
            with closing(read_only(history)) as db:
                for thread_id, _, _ in rows:
                    last = db.execute("""
                        SELECT status FROM thread_turns WHERE thread_id=?
                        ORDER BY rollout_ordinal DESC LIMIT 1
                        """, (thread_id,)).fetchone()
                    if last:
                        states[thread_id] = TURN_STATES.get(last[0], UNKNOWN)
        return [Session(thread_id, cwd, states.get(thread_id, UNKNOWN), "Codex Desktop", name or "")
                for thread_id, cwd, name in rows if cwd]


async def observe_desktop(publish):
    home = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")
    reader = CodexDesktopSessions(home, db_home=Path(os.environ.get("CODEX_SQLITE_HOME") or home))
    while True:
        try:
            rows = await asyncio.to_thread(reader.snapshot)
            publish(rows, None)
        except (OSError, sqlite3.Error):
            publish([], "Metadados do Codex Desktop indisponíveis")
        await asyncio.sleep(2)
