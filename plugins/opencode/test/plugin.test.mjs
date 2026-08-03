import assert from "node:assert/strict";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { cctop } from "../plugin.js";

function createHookHome() {
  const home = mkdtempSync(join(tmpdir(), "cctop-opencode-plugin-"));
  const hookDir = join(home, ".cctop", "bin");
  mkdirSync(hookDir, { recursive: true });

  const hookLog = join(home, "hook.log");
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

async function loadPlugin({ cwd = "/tmp/test-project" } = {}) {
  const { home, hookLog } = createHookHome();
  const previousHome = process.env.HOME;
  process.env.HOME = home;

  const hooks = await cctop({
    directory: cwd,
    client: {},
    project: {},
    worktree: undefined,
    serverUrl: "http://localhost:4096",
    $: undefined,
  });

  return {
    hooks,
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

test("registers hooks and emits SessionStart on load", async () => {
  const plugin = await loadPlugin();

  try {
    assert.equal(typeof plugin.hooks.event, "function");
    assert.equal(typeof plugin.hooks["chat.message"], "function");
    assert.equal(typeof plugin.hooks["tool.execute.before"], "function");
    assert.equal(typeof plugin.hooks["tool.execute.after"], "function");
    assert.equal(typeof plugin.hooks["permission.ask"], "function");
    assert.equal(typeof plugin.hooks["experimental.session.compacting"], "function");

    const calls = plugin.readCalls();
    assert.deepEqual(eventNames(calls), ["SessionStart"]);
    assert.equal(calls[0].payload.session_id.startsWith("opencode-"), true);
    assert.equal(calls[0].payload.cwd, "/tmp/test-project");
    assert.equal(calls[0].payload.harness_name, "opencode");
    assert.equal(calls[0].payload.source, "opencode");
  } finally {
    plugin.restore();
  }
});

test("maps opencode plugin callbacks to cctop prompt and tool hooks", async () => {
  const plugin = await loadPlugin();

  try {
    await plugin.hooks["chat.message"]({}, { message: { content: "make it so" } });
    await plugin.hooks["tool.execute.before"]({}, {
      tool: "read",
      args: { filePath: "/tmp/test-project/README.md", ignored: true },
    });
    await plugin.hooks["tool.execute.after"]();
    await plugin.hooks["permission.ask"]({
      tool: "bash",
      title: "Run command?",
      args: { command: "make test" },
    });
    await plugin.hooks["experimental.session.compacting"]();

    const calls = plugin.readCalls();

    assert.deepEqual(
      eventNames(calls),
      [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PermissionRequest",
        "PreCompact",
      ],
    );
    assert.equal(calls[1].payload.prompt, "make it so");
    assert.equal(calls[2].payload.tool_name, "Read");
    assert.deepEqual(calls[2].payload.tool_input, { file_path: "/tmp/test-project/README.md" });
    assert.equal(calls[4].payload.tool_name, "Bash");
    assert.equal(calls[4].payload.title, "Run command?");
    assert.deepEqual(calls[4].payload.tool_input, { command: "make test" });
  } finally {
    plugin.restore();
  }
});

test("routes every callback-provided opencode session id", async () => {
  const plugin = await loadPlugin();

  try {
    await plugin.hooks["chat.message"]({ sessionID: "ses_chat" }, { text: "hello" });
    await plugin.hooks["tool.execute.before"]({ sessionID: "ses_before", tool: "read" }, {});
    await plugin.hooks["tool.execute.after"]({ sessionID: "ses_after" });
    await plugin.hooks["permission.ask"]({ sessionID: "ses_permission", tool: "bash" });
    await plugin.hooks["experimental.session.compacting"]({ sessionID: "ses_compact" });

    assert.deepEqual(
      plugin.readCalls().slice(1).map((call) => call.payload.session_id),
      ["ses_chat", "ses_before", "ses_after", "ses_permission", "ses_compact"],
    );
  } finally {
    plugin.restore();
  }
});

test("maps opencode session events to cctop lifecycle hooks", async () => {
  const plugin = await loadPlugin();

  try {
    await plugin.hooks.event({
      event: { type: "session.updated", properties: { info: { id: "ses_top", title: "opencode session" } } },
    });
    await plugin.hooks.event({
      event: { type: "session.created", properties: { info: { id: "ses_top" } } },
    });
    await plugin.hooks.event({ event: { type: "session.idle", properties: { sessionID: "ses_top" } } });
    await plugin.hooks.event({ event: { type: "session.compacted", properties: { sessionID: "ses_top" } } });
    await plugin.hooks.event({
      event: { type: "session.status", properties: { sessionID: "ses_top", status: { type: "retry" } } },
    });
    await plugin.hooks.event({
      event: { type: "session.status", properties: { sessionID: "ses_top", status: { type: "busy" } } },
    });
    await plugin.hooks.event({
      event: { type: "session.error", properties: { sessionID: "ses_top", error: { message: "boom" } } },
    });
    await plugin.hooks.event({
      event: { type: "session.deleted", properties: { info: { id: "ses_top", title: "opencode session" } } },
    });
    await plugin.hooks.event({ event: { type: "permission.replied" } });

    const calls = plugin.readCalls();

    assert.deepEqual(
      eventNames(calls),
      ["SessionStart", "SessionStart", "Stop", "PostCompact", "SessionError", "SessionError", "SessionEnd"],
    );
    assert.equal(calls[1].payload.session_name, "opencode session");
    assert.equal(calls[1].payload.session_id, "ses_top");
    assert.equal(calls[4].payload.error, "Retry");
    assert.equal(calls[5].payload.error, "boom");
    assert.equal(calls[6].payload.session_id, "ses_top");
  } finally {
    plugin.restore();
  }
});

test("keeps concurrent opencode identities, titles, and child ownership separate", async () => {
  const plugin = await loadPlugin();

  try {
    await plugin.hooks.event({
      event: { type: "session.created", properties: { info: { id: "ses_top", title: "Top work" } } },
    });
    await plugin.hooks.event({
      event: {
        type: "session.created",
        properties: { info: { id: "ses_child", parentID: "ses_top", title: "Child work" } },
      },
    });
    await plugin.hooks.event({
      event: { type: "session.updated", properties: { info: { id: "ses_top", title: "Top work renamed" } } },
    });
    await plugin.hooks["tool.execute.before"](
      { tool: "bash", sessionID: "ses_top" },
      { args: { command: "make test" } },
    );
    await plugin.hooks.event({
      event: { type: "session.idle", properties: { sessionID: "ses_child" } },
    });
    await plugin.hooks["tool.execute.after"]({ sessionID: "ses_top" });

    const calls = plugin.readCalls();
    assert.deepEqual(
      calls.slice(1).map((call) => [
        call.eventName,
        call.payload.session_id,
        call.payload.session_name,
        call.payload.is_subagent,
      ]),
      [
        ["SessionStart", "ses_top", "Top work", undefined],
        ["SessionStart", "ses_child", "Child work", true],
        ["PreToolUse", "ses_top", "Top work renamed", undefined],
        ["Stop", "ses_child", "Child work", true],
        ["PostToolUse", "ses_top", "Top work renamed", undefined],
      ],
    );
    assert.equal(calls[3].payload.tool_name, "Bash");
    assert.deepEqual(calls[3].payload.tool_input, { command: "make test" });
  } finally {
    plugin.restore();
  }
});

test("maps opencode question events to cctop permission wait hooks", async () => {
  const plugin = await loadPlugin();

  try {
    await plugin.hooks.event({
      event: {
        type: "question.asked",
        properties: {
          sessionID: "ses_question",
          questions: [
            {
              header: "Direction",
              question: "Which direction should I take?",
              options: [
                { label: "A", description: "First option" },
                { label: "B", description: "Second option" },
              ],
            },
          ],
        },
      },
    });
    await plugin.hooks.event({
      event: {
        type: "question.asked",
        properties: {
          questions: [{ header: "Fallback", options: [] }],
        },
      },
    });
    await plugin.hooks.event({ event: { type: "question.replied", properties: { answers: [["A"]] } } });
    await plugin.hooks.event({ event: { type: "question.rejected", properties: {} } });

    const calls = plugin.readCalls();

    assert.deepEqual(
      eventNames(calls),
      ["SessionStart", "PermissionRequest", "PermissionRequest", "PostToolUse", "PostToolUse"],
    );

    assert.equal(calls[1].payload.title, "Which direction should I take?");
    assert.equal(calls[1].payload.session_id, "ses_question");
    assert.equal(calls[1].payload.harness_name, "opencode");
    assert.equal(calls[1].payload.source, "opencode");
    assert.equal(calls[1].payload.notification_type, undefined);
    assert.equal(calls[2].payload.title, "Fallback");
    assert.equal(calls[2].payload.session_id, `opencode-${process.pid}`);
    assert.equal(calls[3].payload.notification_type, undefined);
    assert.equal(calls[4].payload.notification_type, undefined);
  } finally {
    plugin.restore();
  }
});
