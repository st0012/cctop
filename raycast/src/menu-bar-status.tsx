import { Color, Icon, launchCommand, LaunchType, MenuBarExtra } from "@raycast/api";

import { jumpToSession } from "./actions";
import {
  loadSessions,
  displayName,
  contextLine,
  needsAttention,
  statusGroup,
  StatusGroup,
} from "./sessions";
import { statusIcon } from "./status-ui";
import { CctopSession } from "./types";

export default function MenuBarStatus() {
  const sessions = loadSessions();
  const attentionCount = sessions.filter((s) => needsAttention(s.status)).length;

  const icon =
    attentionCount > 0
      ? { source: Icon.ExclamationMark, tintColor: Color.Red }
      : { source: Icon.Circle, tintColor: Color.SecondaryText };

  const title = attentionCount > 0 ? String(attentionCount) : undefined;
  const tooltip = `cctop: ${sessions.length} session${sessions.length !== 1 ? "s" : ""}`;

  // Group sessions by status group for menu sections
  const order: StatusGroup[] = ["Needs Attention", "Active", "Idle"];
  const grouped = new Map<StatusGroup, CctopSession[]>();
  for (const s of sessions) {
    const g = statusGroup(s.status);
    const list = grouped.get(g) ?? [];
    list.push(s);
    grouped.set(g, list);
  }
  const groups = order.filter((g) => grouped.has(g)).map((g) => ({ group: g, sessions: grouped.get(g)! }));

  return (
    <MenuBarExtra icon={icon} title={title} tooltip={tooltip}>
      {sessions.length === 0 ? (
        <MenuBarExtra.Item title="No active sessions" />
      ) : (
        groups.map(({ group, sessions: groupSessions }) => (
          <MenuBarExtra.Section key={group} title={group}>
            {groupSessions.map((session) => (
              <MenuBarExtra.Item
                key={session.pid?.toString() ?? session.session_id}
                title={displayName(session)}
                subtitle={contextLine(session) ?? undefined}
                icon={statusIcon(session.status)}
                onAction={() => jumpToSession(session)}
              />
            ))}
          </MenuBarExtra.Section>
        ))
      )}
      <MenuBarExtra.Section>
        <MenuBarExtra.Item
          title="Show All Sessions"
          onAction={() => launchCommand({ name: "show-sessions", type: LaunchType.UserInitiated })}
        />
      </MenuBarExtra.Section>
    </MenuBarExtra>
  );
}
