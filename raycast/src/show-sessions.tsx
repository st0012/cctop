import { Action, ActionPanel, Color, Icon, List } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { useEffect } from "react";

import { jumpToSession, getTerminalLabel } from "./actions";
import { loadSessions, displayName, contextLine, relativeTime, sourceLabel, statusGroup, StatusGroup } from "./sessions";
import { CctopSession, SessionStatus } from "./types";

/** Map session status to Raycast Color, matching SessionStatus+UI.swift */
function statusColor(status: SessionStatus): Color {
  switch (status) {
    case "waiting_permission":
      return Color.Red;
    case "waiting_input":
    case "needs_attention":
      return Color.Orange;
    case "working":
      return Color.Green;
    case "compacting":
      return Color.Purple;
    case "idle":
      return Color.SecondaryText;
  }
}

/** Map session status to display label, matching SessionStatus+UI.swift */
function statusLabel(status: SessionStatus): string {
  switch (status) {
    case "waiting_permission":
      return "PERMISSION";
    case "waiting_input":
    case "needs_attention":
      return "WAITING";
    case "working":
      return "WORKING";
    case "compacting":
      return "COMPACTING";
    case "idle":
      return "IDLE";
  }
}

/** Check if sessions come from multiple sources (CC + OC) */
function hasMultipleSources(sessions: CctopSession[]): boolean {
  const sources = new Set(sessions.map((s) => s.source ?? null));
  return sources.size > 1;
}

/** Whether to use sectioned display: >= 3 sessions AND >= 2 status groups */
function useSections(sessions: CctopSession[]): boolean {
  if (sessions.length < 3) return false;
  const groups = new Set(sessions.map((s) => statusGroup(s.status)));
  return groups.size >= 2;
}

/** Build accessories array for a session list item */
function sessionAccessories(session: CctopSession, showSource: boolean): List.Item.Accessory[] {
  const accessories: List.Item.Accessory[] = [];

  if (showSource) {
    const label = sourceLabel(session);
    accessories.push({
      tag: { value: label, color: label === "OC" ? Color.Blue : Color.Orange },
    });
  }

  accessories.push({ tag: { value: session.branch, color: Color.SecondaryText } });
  accessories.push({ text: relativeTime(session.last_activity) });
  accessories.push({ tag: { value: statusLabel(session.status), color: statusColor(session.status) } });

  return accessories;
}

/** Action panel for a session item */
function SessionActions({ session }: { session: CctopSession }) {
  const terminalName = getTerminalLabel(session);
  return (
    <ActionPanel>
      <Action
        title={`Open in ${terminalName}`}
        icon={Icon.Terminal}
        onAction={() => jumpToSession(session)}
      />
      <Action.CopyToClipboard
        title="Copy Project Path"
        content={session.project_path}
        shortcut={{ modifiers: ["cmd"], key: "c" }}
      />
      <Action.CopyToClipboard
        title="Copy Session ID"
        content={session.session_id}
        shortcut={{ modifiers: ["cmd", "shift"], key: "c" }}
      />
      <Action.Open
        title="Open in Finder"
        target={session.project_path}
        shortcut={{ modifiers: ["cmd"], key: "o" }}
      />
    </ActionPanel>
  );
}

/** Render a single session as a List.Item */
function SessionItem({ session, showSource }: { session: CctopSession; showSource: boolean }) {
  return (
    <List.Item
      key={session.pid?.toString() ?? session.session_id}
      icon={{ source: Icon.CircleFilled, tintColor: statusColor(session.status) }}
      title={displayName(session)}
      subtitle={contextLine(session) ?? undefined}
      accessories={sessionAccessories(session, showSource)}
      actions={<SessionActions session={session} />}
    />
  );
}

/** Group sessions by status group, preserving sort order within groups */
function groupSessions(sessions: CctopSession[]): { group: StatusGroup; sessions: CctopSession[] }[] {
  const order: StatusGroup[] = ["Needs Attention", "Active", "Idle"];
  const grouped = new Map<StatusGroup, CctopSession[]>();

  for (const session of sessions) {
    const group = statusGroup(session.status);
    const list = grouped.get(group) ?? [];
    list.push(session);
    grouped.set(group, list);
  }

  return order.filter((g) => grouped.has(g)).map((g) => ({ group: g, sessions: grouped.get(g)! }));
}

export default function ShowSessions() {
  const { data: sessions, revalidate, isLoading } = useCachedPromise(async () => loadSessions());

  useEffect(() => {
    const interval = setInterval(revalidate, 2000);
    return () => clearInterval(interval);
  }, [revalidate]);

  const allSessions = sessions ?? [];
  const showSource = hasMultipleSources(allSessions);
  const sectioned = useSections(allSessions);

  return (
    <List isLoading={isLoading}>
      <List.EmptyView
        title="No Active Sessions"
        description="Start a Claude Code or opencode session to see it here"
        icon={Icon.Monitor}
      />
      {sectioned
        ? groupSessions(allSessions).map(({ group, sessions: groupSessions }) => (
            <List.Section key={group} title={group}>
              {groupSessions.map((session) => (
                <SessionItem key={session.pid?.toString() ?? session.session_id} session={session} showSource={showSource} />
              ))}
            </List.Section>
          ))
        : allSessions.map((session) => (
            <SessionItem key={session.pid?.toString() ?? session.session_id} session={session} showSource={showSource} />
          ))}
    </List>
  );
}
