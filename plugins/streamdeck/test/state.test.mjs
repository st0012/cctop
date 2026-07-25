import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, renameSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import {
  COLD_LAUNCH_GRACE_MS,
  commandSessionForSlot,
  displaySessionForSlot,
  emptyState,
  parseDisplayState,
  readDisplayState,
  watchDisplayState,
} from "../com.st0012.cctop.sdPlugin/lib/state.mjs";

const originalHome = process.env.HOME;
const testHome = mkdtempSync(join(tmpdir(), "cctop-streamdeck-state-"));
process.env.HOME = testHome;
mkdirSync(join(testHome, ".cctop", "sessions"), { recursive: true });
after(() => { process.env.HOME = originalHome; });

function validState(overrides = {}) {
  return {
    version: 1,
    generated_at: new Date().toISOString(),
    app_running: true,
    app_pid: process.pid,
    sessions: [
      { id: "one", name: "alpha", status: "working", color: "#7EAA6E" },
      { id: "two", name: "beta", status: "idle", color: "#7DAEA3" },
    ],
    ...overrides,
  };
}

test("parses the versioned app projection", () => {
  const state = parseDisplayState(JSON.stringify(validState()));
  assert.equal(state.app_running, true);
  assert.equal(state.app_pid, process.pid);
  assert.deepEqual(state.sessions.map((session) => session.id), ["one", "two"]);
});

test("missing, corrupt, wrong-version, and duplicate state is unavailable", () => {
  assert.deepEqual(parseDisplayState("{not json"), emptyState());
  assert.deepEqual(parseDisplayState(JSON.stringify(validState({ version: 2 }))), emptyState());
  assert.deepEqual(parseDisplayState(JSON.stringify(validState({
    sessions: [validState().sessions[0], validState().sessions[0]],
  }))), emptyState());
});

test("a malformed entry stays an empty slot instead of shifting later sessions", () => {
  const state = parseDisplayState(JSON.stringify(validState({
    sessions: [validState().sessions[0], { name: "missing identity" }, validState().sessions[1]],
  })));
  assert.equal(state.sessions[0].id, "one");
  assert.equal(state.sessions[1], null);
  assert.equal(state.sessions[2].id, "two");
  assert.equal(displaySessionForSlot(state, 2), null);
  assert.equal(displaySessionForSlot(state, 3).id, "two");
});

test("live process state renders and targets its exact slot", () => {
  const state = parseDisplayState(JSON.stringify(validState()));
  assert.equal(displaySessionForSlot(state, 1).id, "one");
  assert.equal(commandSessionForSlot(state, 2).id, "two");
  assert.equal(commandSessionForSlot(state, 3), null);
  assert.equal(commandSessionForSlot(state, 0), null);
});

test("dead publisher state is unavailable", () => {
  const state = parseDisplayState(JSON.stringify(validState({ app_pid: 2_147_483_647 })));
  assert.equal(displaySessionForSlot(state, 1), null);
  assert.equal(commandSessionForSlot(state, 1), null);
});

test("recent graceful state is command-only and expires", () => {
  const recent = parseDisplayState(JSON.stringify(validState({ app_running: false, app_pid: null })));
  assert.equal(displaySessionForSlot(recent, 1), null);
  assert.equal(commandSessionForSlot(recent, 1).id, "one");

  const expired = parseDisplayState(JSON.stringify(validState({
    generated_at: new Date(Date.now() - COLD_LAUNCH_GRACE_MS - 1_000).toISOString(),
    app_running: false,
    app_pid: null,
  })));
  assert.equal(commandSessionForSlot(expired, 1), null);
});

test("the plugin does not derive display state from cctop session sources", () => {
  writeFileSync(join(testHome, ".cctop", "sessions", "123.json"), JSON.stringify({
    session_id: "must-not-be-read",
    status: "working",
  }));
  assert.deepEqual(readDisplayState(), emptyState());
});

test("watches atomic replacement of the app projection without polling", async () => {
  const statePath = join(testHome, ".cctop", "display-state.json");
  writeFileSync(statePath, JSON.stringify(validState()));
  let changes = 0;
  const watcher = watchDisplayState(() => { changes += 1; });
  assert.ok(watcher);
  try {
    const temporary = `${statePath}.tmp`;
    writeFileSync(temporary, JSON.stringify(validState({ generated_at: new Date().toISOString() })));
    renameSync(temporary, statePath);
    const deadline = Date.now() + 2_000;
    while (changes === 0 && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    assert.ok(changes >= 1);
  } finally {
    watcher.close();
  }
});
