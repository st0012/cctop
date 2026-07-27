// Loads cctop.ts directly via Node's built-in TypeScript type stripping
// (no build step, no dependencies). Requires Node 23.6+.
import assert from "node:assert/strict";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import cctop from "../cctop.ts";

function createHookHome() {
  const home = mkdtempSync(join(tmpdir(), "cctop-pi-extension-"));
  const hookDir = join(home, ".cctop", "bin");
  mkdirSync(hookDir, { recursive: true });

  const hookLog = join(home, "hook.log");
  writeFileSync(hookLog, "");
  const hookBin = join(hookDir, "cctop-hook");
  writeFileSync(
    hookBin,
    `#!/bin/sh
printf '%s\\t' "$1" >> ${JSON.stringify(hookLog)}
cat >> ${JSON.stringify(hookLog)}
printf '\\n' >> ${JSON.stringify(hookLog)}
`,
  );
  chmodSync(hookBin, 0o755);

  return { home, hookLog };
}

function loadExtension({ sessionName = null } = {}) {
  const { home, hookLog } = createHookHome();
  const previousHome = process.env.HOME;
  process.env.HOME = home;

  const handlers = new Map();
  const pi = {
    sessionName,
    on(eventName, handler) {
      handlers.set(eventName, handler);
    },
    getSessionName() {
      return this.sessionName;
    },
  };
  cctop(pi);

  return {
    pi,
    async emit(eventName, event = {}, ctx = undefined) {
      await handlers.get(eventName)(event, ctx);
    },
    handlerNames() {
      return [...handlers.keys()];
    },
    readCalls() {
      const log = readFileSync(hookLog, "utf8").trim();
      if (!log) return [];

      return log.split("\n").map((line) => {
        const [eventName, json] = line.split("\t");
        return { eventName, payload: JSON.parse(json) };
      });
    },
    restore() {
      if (previousHome === undefined) {
        delete process.env.HOME;
      } else {
        process.env.HOME = previousHome;
      }
    },
  };
}

function eventNames(calls) {
  return calls.map((call) => call.eventName);
}

test("registers handlers and emits SessionStart for interactive sessions", async () => {
  const extension = loadExtension({ sessionName: "pi session" });

  try {
    assert.deepEqual(extension.handlerNames(), [
      "session_start",
      "session_shutdown",
      "input",
      "agent_end",
      "tool_execution_start",
      "tool_execution_end",
      "session_before_compact",
      "session_compact",
      "session_switch",
    ]);

    await extension.emit("session_start", {}, { hasUI: true, cwd: "/tmp/test-project" });

    const calls = extension.readCalls();
    assert.deepEqual(eventNames(calls), ["SessionStart"]);
    assert.equal(calls[0].payload.session_id, `pi-${process.pid}`);
    assert.equal(calls[0].payload.cwd, "/tmp/test-project");
    assert.equal(calls[0].payload.harness_name, "pi");
    assert.equal(calls[0].payload.source, "pi");
    assert.equal(calls[0].payload.session_name, "pi session");
  } finally {
    extension.restore();
  }
});

test("adopts the real pi session id and rotates it on session switch", async () => {
  const extension = loadExtension();

  try {
    const ctxFor = (id) => ({
      hasUI: true,
      cwd: "/tmp/test-project",
      sessionManager: { getSessionId: () => id },
    });

    await extension.emit("session_start", {}, ctxFor("pi-session-aaa"));
    await extension.emit("tool_execution_end", { isError: false });
    await extension.emit("session_switch", { reason: "resume" }, ctxFor("pi-session-bbb"));

    const calls = extension.readCalls();
    assert.deepEqual(eventNames(calls), ["SessionStart", "PostToolUse", "SessionStart"]);
    assert.equal(calls[0].payload.session_id, "pi-session-aaa");
    assert.equal(calls[1].payload.session_id, "pi-session-aaa");
    assert.equal(calls[2].payload.session_id, "pi-session-bbb");
  } finally {
    extension.restore();
  }
});

test("session switch resets to the process fallback when id lookup is missing or fails", async () => {
  for (const sessionManager of [
    {},
    { getSessionId: () => { throw new Error("unavailable"); } },
  ]) {
    const extension = loadExtension();
    try {
      await extension.emit("session_start", {}, {
        hasUI: true,
        cwd: "/tmp/test-project",
        sessionManager: { getSessionId: () => "pi-session-aaa" },
      });
      await extension.emit("session_switch", { reason: "new" }, { sessionManager });

      const calls = extension.readCalls();
      assert.deepEqual(eventNames(calls), ["SessionStart", "SessionStart"]);
      assert.equal(calls[0].payload.session_id, "pi-session-aaa");
      assert.equal(calls[1].payload.session_id, `pi-${process.pid}`);
    } finally {
      extension.restore();
    }
  }
});

test("skips all tracking when ctx.hasUI is false", async () => {
  const extension = loadExtension();

  try {
    await extension.emit("session_start", {}, { hasUI: false, cwd: "/tmp/test-project" });
    await extension.emit("input", { text: "hello" });
    await extension.emit("tool_execution_start", { toolName: "bash", args: { command: "ls" } });
    await extension.emit("tool_execution_end", { isError: false });
    await extension.emit("agent_end");
    await extension.emit("session_switch");
    await extension.emit("session_shutdown");

    assert.deepEqual(extension.readCalls(), []);
  } finally {
    extension.restore();
  }
});

test("maps pi events to cctop prompt, tool, and lifecycle hooks", async () => {
  const extension = loadExtension();

  try {
    await extension.emit("session_start", {}, { hasUI: true, cwd: "/tmp/test-project" });
    await extension.emit("input", { text: "make it so" });
    await extension.emit("tool_execution_start", {
      toolName: "read",
      args: { filePath: "/tmp/test-project/README.md", ignored: true },
    });
    await extension.emit("agent_end");
    await extension.emit("session_before_compact");
    await extension.emit("session_compact");
    await extension.emit("session_shutdown");

    const calls = extension.readCalls();
    assert.deepEqual(
      eventNames(calls),
      [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "Stop",
        "PreCompact",
        "PostCompact",
        "SessionEnd",
      ],
    );
    assert.equal(calls[1].payload.prompt, "make it so");
    assert.equal(calls[2].payload.tool_name, "Read");
    assert.deepEqual(calls[2].payload.tool_input, { file_path: "/tmp/test-project/README.md" });
  } finally {
    extension.restore();
  }
});

test("maps tool_execution_end to PostToolUse or PostToolUseFailure by isError", async () => {
  const extension = loadExtension();

  try {
    await extension.emit("session_start", {}, { hasUI: true, cwd: "/tmp/test-project" });
    await extension.emit("tool_execution_end", { isError: false, result: "ok" });
    await extension.emit("tool_execution_end", { isError: true, result: "command exploded" });
    await extension.emit("tool_execution_end", { isError: true, result: { message: "object message" } });

    const calls = extension.readCalls();
    assert.deepEqual(
      eventNames(calls),
      ["SessionStart", "PostToolUse", "PostToolUseFailure", "PostToolUseFailure"],
    );
    assert.equal(calls[1].payload.error, undefined);
    assert.equal(calls[2].payload.error, "command exploded");
    assert.equal(calls[3].payload.error, "object message");
  } finally {
    extension.restore();
  }
});

test("session_switch refreshes the session name and emits SessionStart", async () => {
  const extension = loadExtension({ sessionName: "first session" });

  try {
    await extension.emit("session_start", {}, { hasUI: true, cwd: "/tmp/test-project" });
    extension.pi.sessionName = "renamed session";
    await extension.emit("session_switch");

    const calls = extension.readCalls();
    assert.deepEqual(eventNames(calls), ["SessionStart", "SessionStart"]);
    assert.equal(calls[0].payload.session_name, "first session");
    assert.equal(calls[1].payload.session_name, "renamed session");
  } finally {
    extension.restore();
  }
});
