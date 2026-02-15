import { Action, ActionPanel, Color, Icon, Image, List } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { useEffect, useState } from "react";

import { jumpToSession, getTerminalLabel } from "./actions";
import {
  loadSessions,
  displayName,
  contextLine,
  relativeTime,
  sourceLabel,
  statusGroup,
  needsAttention,
  formatToolDisplay,
  StatusGroup,
} from "./sessions";
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

/** Full status description for the detail pane */
function statusDescription(status: SessionStatus): string {
  switch (status) {
    case "waiting_permission":
      return "Waiting for Permission";
    case "waiting_input":
      return "Waiting for Input";
    case "needs_attention":
      return "Needs Attention";
    case "working":
      return "Working";
    case "compacting":
      return "Compacting Context";
    case "idle":
      return "Idle";
  }
}

/** Map session status to icon shape based on urgency */
function statusIcon(status: SessionStatus): Image.ImageLike {
  if (needsAttention(status)) return { source: Icon.ExclamationMark, tintColor: statusColor(status) };
  if (status === "idle") return { source: Icon.Circle, tintColor: statusColor(status) };
  return { source: Icon.CircleFilled, tintColor: statusColor(status) };
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

/** Detail pane showing full session metadata */
function SessionDetail({ session }: { session: CctopSession }) {
  const toolDisplay =
    session.last_tool ? formatToolDisplay(session.last_tool, session.last_tool_detail) : undefined;

  return (
    <List.Item.Detail
      metadata={
        <List.Item.Detail.Metadata>
          <List.Item.Detail.Metadata.TagList title="Status">
            <List.Item.Detail.Metadata.TagList.Item
              text={statusDescription(session.status)}
              color={statusColor(session.status)}
            />
          </List.Item.Detail.Metadata.TagList>
          <List.Item.Detail.Metadata.Label title="Project" text={session.project_name} />
          {session.session_name && session.session_name !== session.project_name && (
            <List.Item.Detail.Metadata.Label title="Session Name" text={session.session_name} />
          )}
          <List.Item.Detail.Metadata.Label title="Branch" text={session.branch} />
          <List.Item.Detail.Metadata.Label title="Path" text={session.project_path} />
          <List.Item.Detail.Metadata.Label title="Terminal" text={getTerminalLabel(session)} />
          <List.Item.Detail.Metadata.Label
            title="Source"
            text={session.source === "opencode" ? "opencode" : "Claude Code"}
          />
          <List.Item.Detail.Metadata.Separator />
          <List.Item.Detail.Metadata.Label title="Started" text={relativeTime(session.started_at)} />
          <List.Item.Detail.Metadata.Label title="Last Activity" text={relativeTime(session.last_activity)} />
          {toolDisplay && <List.Item.Detail.Metadata.Label title="Last Tool" text={toolDisplay} />}
          {session.last_prompt && (
            <List.Item.Detail.Metadata.Label title="Last Prompt" text={session.last_prompt} />
          )}
          {session.status === "waiting_permission" && session.notification_message && (
            <List.Item.Detail.Metadata.Label title="Notification" text={session.notification_message} />
          )}
        </List.Item.Detail.Metadata>
      }
    />
  );
}

/** Action panel for a session item */
function SessionActions({
  session,
  isShowingDetail,
  onToggleDetail,
}: {
  session: CctopSession;
  isShowingDetail: boolean;
  onToggleDetail: () => void;
}) {
  const terminalName = getTerminalLabel(session);
  return (
    <ActionPanel>
      <Action
        title={`Open in ${terminalName}`}
        icon={Icon.Terminal}
        onAction={() => jumpToSession(session)}
      />
      <Action
        title={isShowingDetail ? "Hide Details" : "Show Details"}
        icon={Icon.Sidebar}
        shortcut={{ modifiers: ["cmd"], key: "d" }}
        onAction={onToggleDetail}
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
function SessionItem({
  session,
  showSource,
  isShowingDetail,
  onToggleDetail,
}: {
  session: CctopSession;
  showSource: boolean;
  isShowingDetail: boolean;
  onToggleDetail: () => void;
}) {
  return (
    <List.Item
      key={session.pid?.toString() ?? session.session_id}
      icon={statusIcon(session.status)}
      title={displayName(session)}
      subtitle={contextLine(session) ?? undefined}
      accessories={sessionAccessories(session, showSource)}
      detail={isShowingDetail ? <SessionDetail session={session} /> : undefined}
      actions={
        <SessionActions
          session={session}
          isShowingDetail={isShowingDetail}
          onToggleDetail={onToggleDetail}
        />
      }
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

/** Filter sessions based on the selected dropdown value */
function filterSessions(sessions: CctopSession[], filter: string): CctopSession[] {
  switch (filter) {
    case "attention":
      return sessions.filter((s) => needsAttention(s.status));
    case "active":
      return sessions.filter((s) => s.status === "working" || s.status === "compacting");
    case "idle":
      return sessions.filter((s) => s.status === "idle");
    default:
      return sessions;
  }
}

export default function ShowSessions() {
  const { data: sessions, revalidate, isLoading } = useCachedPromise(async () => loadSessions());
  const [isShowingDetail, setIsShowingDetail] = useState(true);
  const [filter, setFilter] = useState("all");

  useEffect(() => {
    const interval = setInterval(revalidate, 2000);
    return () => clearInterval(interval);
  }, [revalidate]);

  const allSessions = sessions ?? [];
  const filteredSessions = filterSessions(allSessions, filter);
  const showSource = hasMultipleSources(allSessions);
  const sectioned = useSections(filteredSessions);
  const toggleDetail = () => setIsShowingDetail((prev) => !prev);

  const renderItem = (session: CctopSession) => (
    <SessionItem
      key={session.pid?.toString() ?? session.session_id}
      session={session}
      showSource={showSource}
      isShowingDetail={isShowingDetail}
      onToggleDetail={toggleDetail}
    />
  );

  return (
    <List
      isLoading={isLoading}
      isShowingDetail={isShowingDetail}
      searchBarAccessory={
        <List.Dropdown tooltip="Filter by status" onChange={setFilter} storeValue>
          <List.Dropdown.Item title="All Sessions" value="all" />
          <List.Dropdown.Item title="Needs Attention" value="attention" />
          <List.Dropdown.Item title="Active" value="active" />
          <List.Dropdown.Item title="Idle" value="idle" />
        </List.Dropdown>
      }
    >
      <List.EmptyView
        title="No Active Sessions"
        description="Start a Claude Code or opencode session to see it here"
        icon={Icon.Monitor}
      />
      {sectioned
        ? groupSessions(filteredSessions).map(({ group, sessions: groupSessions }) => (
            <List.Section key={group} title={group}>
              {groupSessions.map(renderItem)}
            </List.Section>
          ))
        : filteredSessions.map(renderItem)}
    </List>
  );
}
