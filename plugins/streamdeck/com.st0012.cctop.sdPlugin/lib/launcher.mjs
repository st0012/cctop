import { execFile } from "node:child_process";

export const TOGGLE_URL = "cctop://toggle";

export function focusURL(displayID) {
  if (typeof displayID !== "string" || displayID.length === 0) return null;
  return `cctop://focus?sid=${encodeURIComponent(displayID)}`;
}

export function acknowledgeURL(displayID) {
  if (typeof displayID !== "string" || displayID.length === 0) return null;
  return `cctop://acknowledge?sid=${encodeURIComponent(displayID)}`;
}

function isSupportedCommandURL(value) {
  try {
    const url = new URL(value);
    if (url.protocol !== "cctop:") return false;
    if (url.hostname === "toggle") return url.search === "";
    return ["focus", "acknowledge"].includes(url.hostname)
      && Boolean(url.searchParams.get("sid"));
  } catch {
    return false;
  }
}

/// Ask macOS Launch Services to deliver the command to cctop. Stream Deck's
/// SDK openUrl API only supports browser URLs and intercepts custom schemes.
export function openCctopURL(url) {
  if (!isSupportedCommandURL(url)) {
    return Promise.reject(new Error("Unsupported cctop command URL"));
  }
  return new Promise((resolve, reject) => {
    execFile("/usr/bin/open", [url], { timeout: 5_000 }, (error) => {
      if (error) reject(error);
      else resolve();
    });
  });
}
