import { showHUD } from "@raycast/api";

import { loadSessions } from "./sessions";
import { jumpToSession } from "./actions";

export default async function JumpToActive() {
  const sessions = loadSessions();
  // Sessions are already sorted by urgency (loadSessions sorts by STATUS_SORT_ORDER)
  // Skip idle sessions — jump to the most urgent non-idle session
  const active = sessions.filter((s) => s.status !== "idle");

  if (active.length === 0) {
    await showHUD("All sessions idle");
    return;
  }

  await jumpToSession(active[0]);
}
