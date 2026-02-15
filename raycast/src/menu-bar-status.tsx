import {
  Color,
  Icon,
  launchCommand,
  LaunchType,
  MenuBarExtra,
} from "@raycast/api";

import { jumpToSession } from "./actions";
import {
  loadSessions,
  displayName,
  contextLine,
  needsAttention,
  groupSessions,
} from "./sessions";
import { statusIcon } from "./status-ui";
export default function MenuBarStatus() {
  const sessions = loadSessions();
  const attentionCount = sessions.filter((s) =>
    needsAttention(s.status),
  ).length;

  const icon =
    attentionCount > 0
      ? { source: Icon.ExclamationMark, tintColor: Color.Red }
      : { source: Icon.Circle, tintColor: Color.SecondaryText };

  const title = attentionCount > 0 ? String(attentionCount) : undefined;
  const tooltip = `cctop: ${sessions.length} session${sessions.length !== 1 ? "s" : ""}`;

  const groups = groupSessions(sessions);

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
          onAction={() =>
            launchCommand({
              name: "show-sessions",
              type: LaunchType.UserInitiated,
            })
          }
        />
      </MenuBarExtra.Section>
    </MenuBarExtra>
  );
}
