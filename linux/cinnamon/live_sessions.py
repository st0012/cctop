"""Combine local Claude Code process records and the Codex CLI observer."""

import asyncio
import json
import os
import time
from collections import Counter
from pathlib import Path

from codex_sessions import IDLE, ORDER, PERMISSION, REPLY, UNKNOWN, WORKING, Session, observe
from desktop_sessions import observe_desktop


class ClaudeSessions:
    def __init__(self, records, proc=Path("/proc")):
        self.records = records
        self.proc = proc
        try:
            machine = Path("/etc/machine-id").read_text().strip()
            self.domain = f"linux:{machine}:{(proc / 'self/ns/pid').readlink()}"
        except OSError:
            self.domain = None

    def matching_process(self, record, pid):
        domain = record.get("pidDomain")
        if self.domain and domain and self.domain != domain:
            return False
        fields = (self.proc / str(pid) / "stat").read_bytes().rsplit(b")", 1)[-1].split()
        if len(fields) < 20 or fields[0] in (b"Z", b"X"):
            return False
        birth = record.get("procStart")
        if birth is not None:
            return str(birth) == fields[19].decode("ascii")
        # Older registrations can lack a birth token. Only accept a Claude process
        # that was already alive when this registration was created.
        exe = (self.proc / str(pid) / "exe").readlink()
        if exe.name != "claude" and exe.parent.parts[-2:] != ("claude", "versions"):
            return False
        started = record.get("startedAt")
        if not isinstance(started, (int, float)):
            return False
        uptime = float((self.proc / "uptime").read_text().split()[0])
        age = uptime - int(fields[19]) / os.sysconf("SC_CLK_TCK")
        return time.time() - age <= started / 1000 + 2

    def snapshot(self):
        latest = {}
        try:
            entries = list(self.records.iterdir())
        except FileNotFoundError:
            return []
        for path in entries:
            if path.suffix != ".json" or not path.stem.isascii() or not path.stem.isdecimal():
                continue
            try:
                record = json.loads(path.read_bytes())
                if not isinstance(record, dict) or record.get("pid") != int(path.stem):
                    continue
                if record.get("kind") not in (None, "interactive"):
                    continue
                sid, cwd = record.get("sessionId"), record.get("cwd")
                if not isinstance(sid, str) or not sid or not isinstance(cwd, str) or not cwd:
                    continue
                if not self.matching_process(record, path.stem):
                    continue
            except (OSError, ValueError):
                continue
            status = str(record.get("status") or "")
            state = {"idle": IDLE, "busy": WORKING}.get(status, UNKNOWN)
            if status == "waiting":
                reason = str(record.get("waitingFor") or "").casefold()
                state = PERMISSION if "permission" in reason else REPLY
            # Derived names may contain prompts. Only present an explicitly named session.
            title = record.get("name") if record.get("nameSource") == "user" else ""
            title = " ".join(title.split()) if isinstance(title, str) else ""
            updated = record.get("updatedAt") or record.get("statusUpdatedAt") or record.get("startedAt")
            stamp = updated if isinstance(updated, (int, float)) else 0
            if sid not in latest or stamp > latest[sid][0]:
                latest[sid] = (stamp, Session(sid, cwd, state, "Claude Code", title))
        return [session for _, session in latest.values()]


async def observe_claude(publish):
    home = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")
    reader = ClaudeSessions(home / "sessions")
    while True:
        try:
            publish(await asyncio.to_thread(reader.snapshot), None)
        except OSError:
            publish([], "Registros locais do Claude Code indisponíveis")
        await asyncio.sleep(2)


async def observe_all(publish, codex_feed=observe, claude_feed=observe_claude, desktop_feed=observe_desktop,
                      *, notes_by_tool=False):
    snapshots = {}

    def update(tool, sessions, message):
        snapshots[tool] = sessions, message
        desktop_ids = {s.id for s in snapshots.get("Codex Desktop", ([], None))[0]}
        merged = [s for rows, _ in snapshots.values() for s in rows
                  if s.tool != "Codex CLI" or s.id not in desktop_ids]
        merged.sort(key=lambda s: (ORDER.index(s.state), s.project.casefold(), s.tool, not s.title, s.id))
        notes = {name: note for name, (_, note) in snapshots.items() if note and note != "Aguardando o Codex CLI"}
        publish(merged, notes if notes_by_tool else " · ".join(notes.values()) or None)

    await asyncio.gather(codex_feed(lambda rows, note: update("Codex CLI", rows, note)),
                         claude_feed(lambda rows, note: update("Claude Code", rows, note)),
                         desktop_feed(lambda rows, note: update("Codex Desktop", rows, note)))


def session_captions(sessions):
    """Return project and optional title, disambiguated for the visible sessions."""
    names = Counter((s.tool, s.project) for s in sessions)
    captions = []
    for s in sessions:
        project = s.project
        title = s.title if len(s.title) <= 64 else s.title[:63] + "…"
        if not title and s.tool == "Codex CLI" and names[s.tool, project] > 1:
            project = s.cwd
        captions.append((project, title))
    counts = Counter((s.tool, *parts) for s, parts in zip(sessions, captions))
    for s, (project, title) in zip(sessions, captions):
        if counts[s.tool, project, title] > 1:
            suffix = f" [{s.id[-6:]}]"
            if title:
                title += suffix
            else:
                project += suffix
        yield project, title


def session_labels(sessions):
    labels = []
    for s, (project, title) in zip(sessions, session_captions(sessions)):
        name = f"{project} — {title}" if title else project
        labels.append(f"{s.tool} · {name}   ·   {s.state}")
    return labels
