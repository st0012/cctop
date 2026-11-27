import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock

from codex_sessions import CodexConnection, IDLE, PERMISSION, READY, REPLY, RpcError, WORKING


class SessionTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        home = tempfile.TemporaryDirectory()
        self.addCleanup(home.cleanup)
        self.client = CodexConnection(None, Path(home.name))

    async def test_idle_turn_does_not_imply_pending_input(self):
        thread = {"id": "a", "status": {"type": "idle"}, "updatedAt": 1}
        self.client.call = AsyncMock(side_effect=[
            RpcError({"code": -32600, "message": "thread a is not materialized yet"}),
            {"data": [{"status": "completed"}]},
        ])
        self.assertEqual(await self.client.session_state(thread), IDLE)
        thread["status"] = {"type": "active", "activeFlags": []}
        self.assertEqual(await self.client.session_state(thread), WORKING)
        thread["status"] = {"type": "idle"}
        self.assertEqual(await self.client.session_state(thread), READY)
        self.client.call.assert_called_with("thread/turns/list", {
            "threadId": "a", "limit": 1, "sortDirection": "desc", "itemsView": "notLoaded",
        })

    async def test_paginated_snapshot_keeps_cli_sessions_and_their_order(self):
        def thread(key, source, origin, flags):
            return {"id": key, "cwd": f"/work/{key}", "source": source, "originator": origin,
                    "status": {"type": "active", "activeFlags": flags}}
        threads = [
            thread("work", "cli", None, []),
            thread("reply", "vscode", "codex-tui", ["waitingOnUserInput"]),
            thread("approve", "vscode", "codex-tui", ["waitingOnApproval"]),
            thread("desktop", "vscode", "Codex Desktop", []),
            dict(thread("child", "vscode", "codex-tui", []), ephemeral=True),
        ]
        async def call(method, params):
            if method == "thread/loaded/list":
                if params["cursor"] is None:
                    return {"data": ["work", "reply", "closed"], "nextCursor": "next"}
                return {"data": ["approve", "desktop", "child"], "nextCursor": None}
            self.assertEqual(method, "thread/read")
            self.assertFalse(params["includeTurns"])
            if params["threadId"] == "closed":
                raise RpcError({"code": -32600, "message": "thread not found"})
            return {"thread": next(t for t in threads if t["id"] == params["threadId"])}
        self.client.call = call
        sessions = await self.client.snapshot()
        self.assertEqual([(s.project, s.state) for s in sessions],
                         [("approve", PERMISSION), ("reply", REPLY), ("work", WORKING)])

    def test_resumed_terminal_thread_with_desktop_origin(self):
        marker = self.client.home / "tui-thread-reference-capabilities" / "resumed"
        marker.parent.mkdir()
        thread = {"id": "resumed", "source": "vscode", "originator": "Codex Desktop"}
        self.assertFalse(self.client.is_cli(thread))
        marker.touch()
        self.assertTrue(self.client.is_cli(thread))
        self.assertFalse(self.client.is_cli(dict(thread, parentThreadId="parent")))


if __name__ == "__main__":
    unittest.main()
