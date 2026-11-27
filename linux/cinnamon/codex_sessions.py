"""Read-only observer of the local Codex app-server. No transcript or event log."""

import asyncio
import json
import os
import time
from dataclasses import dataclass
from pathlib import Path

import websockets
from websockets.exceptions import WebSocketException


PERMISSION = "Pede permissão"
REPLY = "Aguarda sua resposta"
READY = "Resposta pronta"
WORKING = "Trabalhando"
IN_PROGRESS = "Em andamento"
IDLE = "Disponível"
ERROR = "Erro na sessão"
UNKNOWN = "Estado indisponível"
ORDER = (PERMISSION, REPLY, ERROR, READY, WORKING, IN_PROGRESS, IDLE, UNKNOWN)


@dataclass(frozen=True)
class Session:
    id: str
    cwd: str
    state: str
    tool: str = "Codex CLI"
    title: str = ""

    @property
    def project(self):
        folder = Path(self.cwd)
        if self.tool == "Claude Code":
            for parent in folder.parents:
                if parent.name == "worktrees" and parent.parent.name == ".claude":
                    return parent.parent.parent.name or self.cwd
        return folder.name or self.cwd


class RpcError(Exception):
    def __init__(self, error):
        super().__init__(error.get("code"))
        self.message = error.get("message", "")


class CodexConnection:
    def __init__(self, socket, home):
        self.socket = socket
        self.home = home
        self.request_id = 0
        self.last_turn = {}

    async def call(self, method, params):
        self.request_id += 1
        await self.socket.send(json.dumps({"id": self.request_id, "method": method, "params": params}))
        async with asyncio.timeout(5):
            async for message in self.socket:
                data = json.loads(message)
                if "method" in data or data.get("id") != self.request_id:
                    continue
                if "error" in data:
                    raise RpcError(data["error"])
                return data["result"]
        raise ConnectionError("Codex desconectou")

    async def initialize(self):
        await self.call("initialize", {
            "clientInfo": {"name": "lcctop_mint", "version": "1.0"},
            "capabilities": {"experimentalApi": True},
        })
        await self.socket.send(json.dumps({"method": "initialized"}))

    def is_cli(self, thread):
        if thread.get("ephemeral") or thread.get("parentThreadId") or thread.get("attachedToThreadId"):
            return False
        source = thread.get("source")
        if isinstance(source, dict) or source == "exec":
            return False
        if source == "cli" or thread.get("originator") == "codex-tui":
            return True
        # A TUI can also resume a thread originally created in another client.
        thread_id = thread["id"]
        return (Path(thread_id).name == thread_id and thread_id not in (".", "..")
                and (self.home / "tui-thread-reference-capabilities" / thread_id).is_file())

    async def session_state(self, thread):
        status = thread["status"]
        kind = status["type"]
        thread_id = thread["id"]
        if kind != "idle":
            self.last_turn.pop(thread_id, None)
            if kind == "active":
                flags = status.get("activeFlags", [])
                if "waitingOnApproval" in flags:
                    return PERMISSION
                if "waitingOnUserInput" in flags:
                    return REPLY
                return WORKING
            return ERROR if kind == "systemError" else None

        stamp = thread.get("updatedAt")
        cached = self.last_turn.get(thread_id)
        # Updated timestamps have second resolution; two fast turns can share one.
        if cached and cached[0] == stamp and time.monotonic() < cached[2]:
            return cached[1]
        try:
            result = await self.call("thread/turns/list", {
                "threadId": thread_id, "limit": 1, "sortDirection": "desc", "itemsView": "notLoaded",
            })
        except RpcError as error:
            # A new TUI has no materialized turn until its first prompt.
            if "not materialized" not in error.message:
                raise
            result = {"data": []}
        last = next(iter(result["data"]), {})
        state = {"completed": READY, "failed": ERROR}.get(last.get("status"), IDLE)
        self.last_turn[thread_id] = (stamp, state, time.monotonic() + 15)
        return state

    async def snapshot(self):
        ids = []
        cursor = None
        while True:
            page = await self.call("thread/loaded/list", {"cursor": cursor, "limit": 100})
            ids.extend(page["data"])
            cursor = page.get("nextCursor")
            if not cursor:
                break
        self.last_turn = {k: v for k, v in self.last_turn.items() if k in ids}
        sessions = []
        for thread_id in dict.fromkeys(ids):
            try:
                reply = await self.call("thread/read", {"threadId": thread_id, "includeTurns": False})
                thread = reply["thread"]
                if not self.is_cli(thread):
                    continue
                state = await self.session_state(thread)
            except RpcError as error:
                if any(s in error.message.lower() for s in ("not found", "no longer loaded", "unknown thread")):
                    continue
                raise
            if state:
                sessions.append(Session(thread_id, thread["cwd"], state))
        return sorted(sessions, key=lambda s: (ORDER.index(s.state), s.project.casefold(), s.id))


async def observe(publish):
    home = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")
    endpoint = home / "app-server-control" / "app-server-control.sock"
    while True:
        try:
            async with websockets.unix_connect(str(endpoint), open_timeout=4, close_timeout=1) as socket:
                client = CodexConnection(socket, home)
                await client.initialize()
                while True:
                    sessions = await client.snapshot()
                    publish(sessions, None)
                    await asyncio.sleep(2)
        except (FileNotFoundError, ConnectionRefusedError):
            publish([], "Aguardando o Codex CLI")
        except (OSError, RpcError, WebSocketException, KeyError, ValueError):
            publish([], "Conexão com o Codex indisponível")
        await asyncio.sleep(2)
