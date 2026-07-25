import { execFileSync } from "node:child_process";
import { readFileSync, watch } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const STATE_VERSION = 1;
export const STATE_FILE = "display-state.json";
export const COLD_LAUNCH_GRACE_MS = 5 * 60 * 1000;

export function emptyState() {
  return {
    version: STATE_VERSION,
    generated_at: null,
    app_running: false,
    app_pid: null,
    app_start_time: null,
    sessions: [],
  };
}

function displayStatePath() {
  return join(homedir(), ".cctop", STATE_FILE);
}

function parseEntry(entry) {
  if (!entry || typeof entry !== "object") return null;
  if (typeof entry.id !== "string" || entry.id.length === 0) return null;
  if (typeof entry.name !== "string" || entry.name.length === 0) return null;
  if (typeof entry.status !== "string" || entry.status.length === 0) return null;
  if (typeof entry.color !== "string" || !/^#[0-9a-f]{6}$/i.test(entry.color)) return null;
  return {
    id: entry.id,
    name: entry.name,
    status: entry.status,
    color: entry.color,
  };
}

/// Parse only the app-published display projection. Invalid entries remain
/// empty holes so a malformed slot can never shift a later session forward.
export function parseDisplayState(text) {
  let raw;
  try {
    raw = JSON.parse(text);
  } catch {
    return emptyState();
  }

  if (!raw || typeof raw !== "object" || raw.version !== STATE_VERSION) return emptyState();
  if (typeof raw.generated_at !== "string" || !Number.isFinite(Date.parse(raw.generated_at))) {
    return emptyState();
  }
  if (typeof raw.app_running !== "boolean" || !Array.isArray(raw.sessions)) return emptyState();
  if (raw.app_running) {
    if (!Number.isInteger(raw.app_pid) || raw.app_pid <= 0) return emptyState();
    if (typeof raw.app_start_time !== "number" || !Number.isFinite(raw.app_start_time)
        || raw.app_start_time <= 0) return emptyState();
  } else if (raw.app_pid != null || raw.app_start_time != null) {
    return emptyState();
  }

  const sessions = raw.sessions.slice(0, 32).map(parseEntry);
  const ids = sessions.filter(Boolean).map((entry) => entry.id);
  if (new Set(ids).size !== ids.length) return emptyState();

  return {
    version: STATE_VERSION,
    generated_at: raw.generated_at,
    app_running: raw.app_running,
    app_pid: raw.app_running ? raw.app_pid : null,
    app_start_time: raw.app_running ? raw.app_start_time : null,
    sessions,
  };
}

function publisherIdentityMatches(state) {
  try {
    const output = execFileSync(
      "/bin/ps",
      ["-p", String(state.app_pid), "-o", "lstart="],
      {
        encoding: "utf8",
        env: { ...process.env, LC_ALL: "C" },
        stdio: ["ignore", "pipe", "ignore"],
        timeout: 1_000,
      },
    ).trim();
    const observedStartTime = Date.parse(output) / 1_000;
    return Number.isFinite(observedStartTime)
      && Math.floor(observedStartTime) === Math.floor(state.app_start_time);
  } catch {
    return false;
  }
}

/// Read the one public projection written by cctop. The plugin deliberately
/// never reads ~/.cctop/sessions or any client-specific state.
export function readDisplayState() {
  try {
    const state = parseDisplayState(readFileSync(displayStatePath(), "utf8"));
    if (state.app_running && !publisherIdentityMatches(state)) return emptyState();
    return state;
  } catch {
    return emptyState();
  }
}

export function isProcessAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
}

function sessionAt(state, slot) {
  if (!state || !Number.isInteger(slot) || slot < 1) return null;
  return state.sessions?.[slot - 1] ?? null;
}

/// Keys render sessions only while the exact publishing app process is alive.
export function displaySessionForSlot(state, slot) {
  if (state?.app_running !== true || !isProcessAlive(state.app_pid)) return null;
  return sessionAt(state, slot);
}

/// A recent graceful-quit snapshot may cold-launch cctop. Crashed state
/// (`app_running: true` with a dead pid) is never trusted.
export function commandSessionForSlot(state, slot) {
  if (state?.app_running === true) return displaySessionForSlot(state, slot);
  if (state?.app_running !== false) return null;
  const generatedAt = Date.parse(state.generated_at);
  const age = Date.now() - generatedAt;
  if (!Number.isFinite(age) || age < -60_000 || age > COLD_LAUNCH_GRACE_MS) return null;
  return sessionAt(state, slot);
}

/// Watch the parent directory because cctop atomically replaces the projection.
/// The app creates ~/.cctop before offering plugin installation. The caller
/// treats watcher failure as terminal so Stream Deck can supervise recovery.
export function watchDisplayState(onChange) {
  let timer = null;
  let watcher;
  try {
    watcher = watch(join(homedir(), ".cctop"), (_event, filename) => {
      if (filename && String(filename) !== STATE_FILE) return;
      if (timer) clearTimeout(timer);
      timer = setTimeout(() => {
        timer = null;
        onChange();
      }, 50);
    });
    watcher.on("close", () => {
      if (timer) clearTimeout(timer);
    });
  } catch {
    return null;
  }

  return watcher;
}
