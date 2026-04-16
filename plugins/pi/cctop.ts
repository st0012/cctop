// cctop extension for pi coding agent
// Translates pi events to cctop-hook calls.
// Zero dependencies — runs in-process via jiti.

import { execFileSync } from "child_process";
import { existsSync } from "fs";
import { join } from "path";
import { homedir } from "os";

// Tool name normalization: pi lowercase -> CC PascalCase
const TOOL_NAME_MAP: Record<string, string> = {
  bash: "Bash",
  read: "Read",
  edit: "Edit",
  write: "Write",
  grep: "Grep",
  glob: "Glob",
  webfetch: "WebFetch",
  websearch: "WebSearch",
  task: "Task",
};

// pi may send camelCase args; cctop-hook expects snake_case
const KEY_MAP: Record<string, string> = { filePath: "file_path" };

function findHookBinary(): string | null {
  const candidates = [
    join(homedir(), ".cctop/bin/cctop-hook"),
    "/Applications/cctop.app/Contents/MacOS/cctop-hook",
    join(homedir(), "Applications/cctop.app/Contents/MacOS/cctop-hook"),
  ];
  for (const p of candidates) {
    if (existsSync(p)) return p;
  }
  return null;
}

function normalizeTool(name: string | undefined | null): string | null {
  if (!name) return null;
  const lower = name.toLowerCase();
  if (TOOL_NAME_MAP[lower]) return TOOL_NAME_MAP[lower];
  return name.charAt(0).toUpperCase() + name.slice(1);
}

function normalizeToolInput(
  args: Record<string, unknown> | undefined | null
): Record<string, string> | undefined {
  if (!args || typeof args !== "object") return undefined;
  const result: Record<string, string> = {};
  for (const [k, v] of Object.entries(args)) {
    const mapped = KEY_MAP[k] || k;
    if (typeof v === "string") result[mapped] = v;
  }
  return Object.keys(result).length > 0 ? result : undefined;
}

function callHook(
  hookBin: string,
  eventName: string,
  payload: Record<string, unknown>
): void {
  try {
    const json = JSON.stringify({ ...payload, hook_event_name: eventName });
    execFileSync(hookBin, [eventName], {
      input: json,
      timeout: 5000,
      stdio: ["pipe", "pipe", "pipe"],
    });
  } catch {
    // Best-effort — never crash the pi process
  }
}

// Pi extension entry point
export default function cctop(pi: any) {
  const hookBin = findHookBinary();
  if (!hookBin) return;

  const sessionId = `pi-${process.pid}`;
  let sessionName: string | null = null;
  let cwd: string = process.cwd();
  let interactive: boolean | null = null; // null = not yet determined

  function basePayload() {
    return {
      session_id: sessionId,
      cwd,
      harness_name: "pi",
      source: "pi",  // MIGRATION(harness_name): Keep for older cctop-hook binaries
      ...(sessionName && { session_name: sessionName }),
    };
  }

  function tryGetSessionName() {
    try {
      const name = pi.getSessionName?.();
      if (name) sessionName = name;
    } catch {
      // Not available
    }
  }

  // Session lifecycle
  pi.on("session_start", async (_event: any, ctx: any) => {
    // Skip non-interactive sessions (background agents, -p mode, --mode json)
    interactive = ctx?.hasUI !== false;
    if (!interactive) return;

    cwd = ctx?.cwd || process.cwd();
    tryGetSessionName();
    callHook(hookBin, "SessionStart", basePayload());
  });

  pi.on("session_shutdown", async () => {
    if (!interactive) return;
    callHook(hookBin, "SessionEnd", basePayload());
  });

  // User input → working
  pi.on("input", async (event: any) => {
    if (!interactive) return;
    const prompt = event?.text || null;
    callHook(hookBin, "UserPromptSubmit", {
      ...basePayload(),
      ...(prompt && { prompt }),
    });
  });

  // Agent done → waiting for input
  pi.on("agent_end", async () => {
    if (!interactive) return;
    callHook(hookBin, "Stop", basePayload());
  });

  // Tool execution
  pi.on("tool_execution_start", async (event: any) => {
    if (!interactive) return;
    const tool = normalizeTool(event?.toolName);
    const args = normalizeToolInput(event?.args);
    callHook(hookBin, "PreToolUse", {
      ...basePayload(),
      ...(tool && { tool_name: tool }),
      ...(args && { tool_input: args }),
    });
  });

  pi.on("tool_execution_end", async (event: any) => {
    if (!interactive) return;
    if (event?.isError) {
      const msg =
        typeof event.result === "string"
          ? event.result
          : event.result?.message || null;
      callHook(hookBin, "PostToolUseFailure", {
        ...basePayload(),
        ...(msg && { error: msg }),
      });
    } else {
      callHook(hookBin, "PostToolUse", basePayload());
    }
  });

  // Compaction
  pi.on("session_before_compact", async () => {
    if (!interactive) return;
    callHook(hookBin, "PreCompact", basePayload());
  });

  pi.on("session_compact", async () => {
    if (!interactive) return;
    callHook(hookBin, "PostCompact", basePayload());
  });

  // Session switch — update name
  pi.on("session_switch", async () => {
    if (!interactive) return;
    tryGetSessionName();
    callHook(hookBin, "SessionStart", basePayload());
  });
}
