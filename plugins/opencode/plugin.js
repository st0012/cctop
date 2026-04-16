// cctop plugin for opencode
// Translates opencode events to cctop-hook calls.
// Zero dependencies — only Node builtins.

import { execFileSync } from "child_process";
import { existsSync } from "fs";
import { join } from "path";
import { homedir } from "os";

// Tool name normalization: opencode lowercase -> CC PascalCase
const TOOL_NAME_MAP = {
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

// opencode sends camelCase args, cctop-hook expects snake_case
const KEY_MAP = { filePath: "file_path" };

function findHookBinary() {
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

function normalizeTool(name) {
  if (!name) return null;
  const lower = name.toLowerCase();
  if (TOOL_NAME_MAP[lower]) return TOOL_NAME_MAP[lower];
  return name.charAt(0).toUpperCase() + name.slice(1);
}

function normalizeToolInput(args) {
  if (!args || typeof args !== "object") return args;
  const result = {};
  for (const [k, v] of Object.entries(args)) {
    const mapped = KEY_MAP[k] || k;
    if (typeof v === "string") result[mapped] = v;
  }
  return result;
}

function callHook(hookBin, eventName, payload) {
  try {
    const json = JSON.stringify({ ...payload, hook_event_name: eventName });
    execFileSync(hookBin, [eventName], {
      input: json,
      timeout: 5000,
      stdio: ["pipe", "pipe", "pipe"],
    });
  } catch {
    // Best-effort — never crash opencode
  }
}

export const cctop = async ({ directory }) => {
  const hookBin = findHookBinary();
  if (!hookBin) return {};

  const sessionId = `opencode-${process.pid}`;
  let sessionName = null;

  function basePayload() {
    return {
      session_id: sessionId,
      cwd: directory,
      harness_name: "opencode",
      source: "opencode",  // MIGRATION(harness_name): Keep for older cctop-hook binaries
      ...(sessionName && { session_name: sessionName }),
    };
  }

  // Fire SessionStart immediately on plugin load
  callHook(hookBin, "SessionStart", basePayload());

  return {
    event: async ({ event }) => {
      if (!event || !event.type) return;

      switch (event.type) {
        case "session.created":
          callHook(hookBin, "SessionStart", basePayload());
          break;

        case "session.idle":
          callHook(hookBin, "Stop", basePayload());
          break;

        case "session.error": {
          const errMsg = event.error?.message || event.message || null;
          callHook(hookBin, "SessionError", {
            ...basePayload(),
            ...(errMsg && { error: errMsg }),
            ...(event.message && { message: event.message }),
          });
          break;
        }

        case "session.status": {
          const type =
            event.properties?.status?.type ||
            event.properties?.type ||
            event.status?.type;
          if (type === "retry") {
            callHook(hookBin, "SessionError", {
              ...basePayload(),
              error: "Retry",
            });
          }
          // busy → skip (already working)
          // idle → handled by session.idle
          break;
        }

        case "session.updated": {
          const title = event.properties?.info?.title;
          if (title) sessionName = title;
          break;
        }

        case "session.compacted":
          callHook(hookBin, "PostCompact", basePayload());
          break;

        case "session.deleted":
        case "permission.replied":
          // skip — liveness handles deletion, PreToolUse follows permission
          break;
      }
    },

    "chat.message": async (_input, output) => {
      const prompt =
        output?.message?.content ||
        output?.content ||
        (typeof output?.text === "string" ? output.text : null);
      callHook(hookBin, "UserPromptSubmit", {
        ...basePayload(),
        ...(prompt && { prompt }),
      });
    },

    "tool.execute.before": async (_input, output) => {
      const tool = normalizeTool(output?.tool || _input?.tool);
      const args = output?.args || _input?.args;
      callHook(hookBin, "PreToolUse", {
        ...basePayload(),
        ...(tool && { tool_name: tool }),
        ...(args && { tool_input: normalizeToolInput(args) }),
      });
    },

    "tool.execute.after": async () => {
      callHook(hookBin, "PostToolUse", basePayload());
    },

    "permission.ask": async (input) => {
      const tool = normalizeTool(input?.tool);
      const args = input?.args;
      callHook(hookBin, "PermissionRequest", {
        ...basePayload(),
        ...(tool && { tool_name: tool }),
        ...(input?.title && { title: input.title }),
        ...(args && { tool_input: normalizeToolInput(args) }),
      });
    },

    "experimental.session.compacting": async () => {
      callHook(hookBin, "PreCompact", basePayload());
    },
  };
};
