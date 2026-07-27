import assert from "node:assert/strict";
import childProcess from "node:child_process";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { syncBuiltinESMExports } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, beforeEach, test } from "node:test";

const realExecFile = childProcess.execFile;
const launches = [];
childProcess.execFile = (file, args, options, callback) => {
  launches.push({ file, args, options });
  queueMicrotask(() => callback(null, "", ""));
  return { unref() {} };
};
syncBuiltinESMExports();

const {
  defaultSlot,
  parseArgs,
  SESSION_ACTION,
  StreamDeckController,
  TOGGLE_ACTION,
} = await import("../com.st0012.cctop.sdPlugin/lib/controller.mjs");

const originalHome = process.env.HOME;
const testHome = mkdtempSync(join(tmpdir(), "cctop-streamdeck-protocol-"));
process.env.HOME = testHome;
mkdirSync(join(testHome, ".cctop"));

after(() => {
  childProcess.execFile = realExecFile;
  syncBuiltinESMExports();
  process.env.HOME = originalHome;
});

beforeEach(() => launches.splice(0));

const MK2 = { id: "mk2", name: "MK.2", size: { columns: 5, rows: 3 }, type: 0 };
const currentProcessStartTime = Date.parse(childProcess.execFileSync(
  "/bin/ps",
  ["-p", String(process.pid), "-o", "lstart="],
  { encoding: "utf8", env: { ...process.env, LC_ALL: "C" } },
).trim()) / 1_000;

class RecordingSocket {
  messages = [];

  send(raw) {
    this.messages.push(JSON.parse(raw));
  }
}

function writeState(overrides = {}) {
  const state = {
    version: 1,
    generated_at: new Date().toISOString(),
    app_running: true,
    app_pid: process.pid,
    app_start_time: currentProcessStartTime,
    sessions: [
      { id: "first/id?", name: "first", status: "working", color: "#7EAA6E" },
      { id: "second", name: "second", status: "idle", color: "#7DAEA3" },
    ],
    ...overrides,
  };
  writeFileSync(join(testHome, ".cctop", "display-state.json"), JSON.stringify(state));
}

function makeController() {
  const socket = new RecordingSocket();
  const controller = new StreamDeckController(socket, {
    pluginUUID: "com.st0012.cctop",
    registerEvent: "registerPlugin",
    info: { devices: [MK2] },
  });
  return { controller, socket };
}

function willAppear(context, coordinates, settings = {}) {
  return {
    event: "willAppear",
    action: SESSION_ACTION,
    context,
    device: MK2.id,
    payload: { coordinates, settings, controller: "Keypad" },
  };
}

function messages(socket, event) {
  return socket.messages.filter((message) => message.event === event);
}

test("parses launch arguments and registers through the supplied runtime socket", () => {
  const info = JSON.stringify({ devices: [MK2] });
  assert.deepEqual(parseArgs([
    "-registerEvent", "registerPlugin",
    "-info", info,
    "-port", "28196",
    "-pluginUUID", "com.st0012.cctop",
  ]), {
    port: 28196,
    pluginUUID: "com.st0012.cctop",
    registerEvent: "registerPlugin",
    info: { devices: [MK2] },
  });

  const { controller, socket } = makeController();
  controller.register();
  assert.deepEqual(socket.messages, [
    { event: "registerPlugin", uuid: "com.st0012.cctop" },
  ]);
});

test("persists the grid-derived slot and renders app-published state", () => {
  writeState();
  const { controller, socket } = makeController();
  controller.handleMessage(willAppear("key-2", { row: 0, column: 1 }));

  assert.equal(defaultSlot({ row: 0, column: 1 }, 5), 2);
  assert.deepEqual(messages(socket, "setSettings"), [
    { event: "setSettings", context: "key-2", payload: { slot: 2 } },
  ]);
  const image = messages(socket, "setImage")[0].payload.image;
  assert.ok(decodeURIComponent(image).includes("second"));
});

test("explicitly malformed initial settings never fall back to a different slot", () => {
  writeState();
  const { controller, socket } = makeController();
  controller.handleMessage(willAppear("bad-key", { row: 0, column: 0 }, { slot: "invalid" }));

  assert.equal(messages(socket, "setSettings").length, 0);
  assert.ok(!decodeURIComponent(messages(socket, "setImage")[0].payload.image).includes("first"));

  controller.handleMessage({ event: "keyDown", action: SESSION_ACTION, context: "bad-key" });
  assert.equal(launches.length, 0);
  assert.deepEqual(messages(socket, "showAlert"), [{ event: "showAlert", context: "bad-key" }]);
});

test("missing placement metadata stays unavailable instead of inventing slot one", () => {
  writeState();
  const { controller, socket } = makeController();

  assert.equal(defaultSlot(undefined, 5), null);
  assert.equal(defaultSlot({ row: 0, column: 0 }, undefined), null);
  assert.equal(defaultSlot({ row: -1, column: 0 }, 5), null);
  assert.equal(defaultSlot({ row: 0, column: 5 }, 5), null);

  controller.handleMessage(willAppear("missing-coordinates", undefined));
  controller.handleMessage({
    ...willAppear("missing-width", { row: 0, column: 0 }),
    device: "unknown-device",
  });

  assert.equal(messages(socket, "setSettings").length, 0);
  for (const imageMessage of messages(socket, "setImage")) {
    const image = decodeURIComponent(imageMessage.payload.image);
    assert.ok(!image.includes("first"));
    assert.ok(!image.includes("second"));
  }
  for (const context of ["missing-coordinates", "missing-width"]) {
    controller.handleMessage({ event: "keyDown", action: SESSION_ACTION, context });
  }
  assert.equal(launches.length, 0);
  assert.deepEqual(messages(socket, "showAlert"), [
    { event: "showAlert", context: "missing-coordinates" },
    { event: "showAlert", context: "missing-width" },
  ]);
});

test("a session key asks Launch Services to deliver the exact encoded cctop command", async () => {
  writeState();
  const { controller, socket } = makeController();
  controller.handleMessage(willAppear("key-1", { row: 0, column: 0 }, { slot: 1 }));
  controller.handleMessage({
    event: "keyDown",
    action: SESSION_ACTION,
    context: "key-1",
    device: MK2.id,
    payload: {},
  });
  await new Promise(setImmediate);

  assert.deepEqual(launches, [{
    file: "/usr/bin/open",
    args: ["cctop://focus?sid=first%2Fid%3F"],
    options: { timeout: 5_000 },
  }]);
  assert.equal(messages(socket, "openUrl").length, 0);
  assert.equal(messages(socket, "showAlert").length, 0);
});

test("toggle uses the same direct cctop command boundary", async () => {
  const { controller, socket } = makeController();
  controller.handleMessage({
    event: "keyDown",
    action: TOGGLE_ACTION,
    context: "toggle-key",
    device: MK2.id,
    payload: {},
  });
  await new Promise(setImmediate);

  assert.deepEqual(launches[0], {
    file: "/usr/bin/open",
    args: ["cctop://toggle"],
    options: { timeout: 5_000 },
  });
  assert.equal(messages(socket, "openUrl").length, 0);
});

test("a press sends the id the key rendered, not the slot's later occupant", async () => {
  writeState();
  const { controller } = makeController();
  controller.handleMessage(willAppear("key-1", { row: 0, column: 0 }, { slot: 1 }));

  // Sessions reorder after the key image was drawn; no refresh has run yet.
  writeState({ sessions: [
    { id: "second", name: "second", status: "working", color: "#DD5353" },
    { id: "first/id?", name: "first", status: "idle", color: "#7DAEA3" },
  ] });
  controller.handleMessage({ event: "keyDown", action: SESSION_ACTION, context: "key-1" });
  await new Promise(setImmediate);

  assert.deepEqual(launches.map((launch) => launch.args[0]), ["cctop://focus?sid=first%2Fid%3F"]);
});

test("a cold-launch press preserves the id rendered before sessions reordered", async () => {
  writeState();
  const { controller } = makeController();
  controller.handleMessage(willAppear("key-1", { row: 0, column: 0 }, { slot: 1 }));

  // cctop quits and publishes a reordered graceful snapshot before the key refreshes.
  writeState({
    app_running: false,
    app_pid: null,
    app_start_time: null,
    sessions: [
      { id: "second", name: "second", status: "working", color: "#DD5353" },
      { id: "first/id?", name: "first", status: "idle", color: "#7DAEA3" },
    ],
  });
  controller.handleMessage({ event: "keyDown", action: SESSION_ACTION, context: "key-1" });
  await new Promise(setImmediate);

  assert.deepEqual(launches.map((launch) => launch.args[0]), ["cctop://focus?sid=first%2Fid%3F"]);
});

test("recent graceful state can cold-launch but renders unavailable while stopped", async () => {
  writeState({ app_running: false, app_pid: null, app_start_time: null });
  const { controller, socket } = makeController();
  controller.handleMessage(willAppear("key-1", { row: 0, column: 0 }, { slot: 1 }));
  const image = decodeURIComponent(messages(socket, "setImage")[0].payload.image);
  assert.ok(!image.includes("first"));

  controller.handleMessage({ event: "keyDown", action: SESSION_ACTION, context: "key-1" });
  await new Promise(setImmediate);
  assert.equal(launches[0].args[0], "cctop://focus?sid=first%2Fid%3F");
});

test("empty or unusable slots fail safely without launching cctop", () => {
  writeState({ app_running: true, app_pid: 2_147_483_647 });
  const { controller, socket } = makeController();
  controller.handleMessage(willAppear("key-1", { row: 0, column: 0 }, { slot: 1 }));
  controller.handleMessage({ event: "keyDown", action: SESSION_ACTION, context: "key-1" });

  assert.equal(launches.length, 0);
  assert.deepEqual(messages(socket, "showAlert"), [{ event: "showAlert", context: "key-1" }]);
});

test("settings changes, reordering, and disappearance update existing contexts", () => {
  writeState();
  const { controller, socket } = makeController();
  controller.handleMessage(willAppear("key", { row: 0, column: 0 }, { slot: 1 }));
  controller.handleMessage({
    event: "didReceiveSettings",
    action: SESSION_ACTION,
    context: "key",
    payload: { settings: { slot: 2 } },
  });
  assert.ok(decodeURIComponent(messages(socket, "setImage").at(-1).payload.image).includes("second"));

  writeState({ sessions: [
    { id: "second", name: "second now first", status: "working", color: "#DD5353" },
    { id: "first/id?", name: "first now second", status: "idle", color: "#7DAEA3" },
  ] });
  controller.refresh();
  const reorderedImage = decodeURIComponent(messages(socket, "setImage").at(-1).payload.image);
  assert.ok(reorderedImage.includes("first now"));
  assert.ok(reorderedImage.includes("second"));

  const before = messages(socket, "setImage").length;
  controller.handleMessage({ event: "willDisappear", action: SESSION_ACTION, context: "key" });
  controller.refresh();
  assert.equal(messages(socket, "setImage").length, before);
});

test("monitored cctop lifecycle events refresh stale key images without launching", () => {
  writeState();
  const { controller, socket } = makeController();
  controller.handleMessage(willAppear("key", { row: 0, column: 0 }, { slot: 1 }));
  assert.ok(decodeURIComponent(messages(socket, "setImage").at(-1).payload.image).includes("first"));

  writeState({ app_pid: 2_147_483_647 });
  controller.handleMessage({
    event: "applicationDidTerminate",
    payload: { application: "com.st0012.CctopMenubar" },
  });
  assert.ok(!decodeURIComponent(messages(socket, "setImage").at(-1).payload.image).includes("first"));

  writeState();
  controller.handleMessage({
    event: "applicationDidLaunch",
    payload: { application: "com.st0012.CctopMenubar" },
  });
  assert.ok(decodeURIComponent(messages(socket, "setImage").at(-1).payload.image).includes("first"));
  assert.equal(launches.length, 0);
  assert.equal(messages(socket, "setSettings").length, 0);
});

test("malformed settings clear a previously valid target", () => {
  writeState();
  const { controller, socket } = makeController();
  controller.handleMessage(willAppear("key", { row: 0, column: 0 }, { slot: 1 }));
  assert.ok(decodeURIComponent(messages(socket, "setImage").at(-1).payload.image).includes("first"));

  controller.handleMessage({
    event: "didReceiveSettings",
    action: SESSION_ACTION,
    context: "key",
    payload: { settings: { slot: "invalid" } },
  });
  assert.ok(!decodeURIComponent(messages(socket, "setImage").at(-1).payload.image).includes("first"));

  controller.handleMessage({ event: "keyDown", action: SESSION_ACTION, context: "key" });
  assert.equal(launches.length, 0);
  assert.deepEqual(messages(socket, "showAlert"), [{ event: "showAlert", context: "key" }]);
});

test("malformed protocol input is contained", () => {
  const { controller, socket } = makeController();
  controller.handleMessage("{not json");
  controller.handleMessage(null);
  assert.equal(messages(socket, "logMessage").length, 1);
});
