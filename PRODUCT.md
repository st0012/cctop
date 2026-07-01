# PRODUCT.md - Product Guide for cctop

This document captures product intent and UX judgment for cctop. It is written
for any agent or contributor making product, workflow, or copy decisions.

Use this document for **what cctop should feel like and why a feature belongs**.
Use [DESIGN.md](DESIGN.md) for visual language and [AGENTS.md](AGENTS.md) for
development workflow, architecture, release, and verification rules.

## Product Promise

cctop is a local-first macOS menubar app for developers running AI coding
sessions across multiple tools. It helps them see which sessions need attention,
jump back to the right workspace, and safely clean up completed work without
losing local changes.

The product should feel like a quiet instrument: always nearby, fast to scan,
and careful with local state.

## Audience

cctop is for developers who run more than one AI coding session, often across
different agents, terminals, editors, or desktop apps. They need peripheral
awareness, fast navigation, and confidence that cctop will not hide or destroy
work.

## Core Tension

cctop must make many AI coding sessions feel manageable without becoming another
dashboard, project manager, Git GUI, or agent runner. It should reveal just
enough local state to help users act confidently, then get out of the way.

## Core Jobs

1. Show session state clearly enough to understand in under a second.
2. Take the user back to the most specific available place: thread, pane, tab,
   editor window, app, or project.
3. Preserve local trust by treating session files, Git state, and app lifecycle
   as evidence rather than assumptions.
4. Help users make cleanup and review decisions without leaving the flow.
5. Stay lightweight enough to live in the menubar all day.

## Golden Workflows

These flows should stay excellent as the product grows:

1. Notice that a session needs attention, then jump to the right workspace.
2. Glance at several sessions and understand which one matters next.
3. Return to a recent project without rebuilding context manually.
4. Inspect a completed worktree, understand the risk, and remove or keep it.
5. Install or trust an integration and know whether it is actually connected.

## Product Principles

### Local-first trust

cctop should keep user work local. It should not upload session content,
telemetry, project paths, or Git state. Features that inspect local files should
be visible, scoped, and explainable.

### Session data starts the story; live state decides safety

Persisted session data tells cctop where a session happened and when it ended.
It does not prove that a path is still safe to act on. Cleanup, navigation, and
lifecycle features should use session data as the starting point, then verify
current local state before making safety claims.

### Show decision evidence inline

When cctop asks users to decide, the evidence needed for that decision should be
visible at the decision point. Users should not need to open Finder, copy a
path, run a command, or expand secondary UI just to understand why an item is
safe, risky, stale, or blocked.

### Make computation visible

Any noticeable check, refresh, scan, or validation step is part of the feature.
The triggering control and affected panel, list, or empty state should show that
cctop is checking. Do not show stale counts, stale success, an empty state, or
"all good" as final while work is still running.

Prefer words like "Checking..." when cctop is validating known local candidates.
Use "Scanning..." only when the product is actually searching across a broader
surface.

### Destructive actions need fresh proof

Before removing a worktree, changing hook/install state, or taking any
destructive action, cctop should re-check the relevant local evidence as close
to the action as practical. If the evidence changes, refuse or ask for review
rather than proceeding from stale UI state.

### Cross-harness neutrality

cctop should not feel like a wrapper for one agent. Its value comes from giving
developers one local view across supported harnesses, with source differences
shown only when they help the user decide or navigate.

### Ambient first, workflow second

The primary cctop experience is a glanceable menubar surface. New workflows
should preserve that lightweight shape. Prefer compact, direct actions and
focused detail views over dashboards, long forms, or project-management flows.

### Earn attention

cctop lives in peripheral vision. Color, badges, notifications, and urgent copy
should be reserved for states that change what the user should do next. Quiet
states should stay quiet.

### Reveal only useful complexity

cctop tracks many lifecycle layers: app liveness, client process liveness,
session visibility, archive state, hook provenance, worktree state, and Git
safety. The UI should reveal these layers only when they help explain a state or
decision. Avoid surfacing implementation categories as product concepts.

## Feature Fit Rubric

A feature belongs in cctop when it:

- improves awareness of active, idle, waiting, recent, or ended AI coding work;
- helps the user return to the right local workspace faster;
- reduces risk around local cleanup or session lifecycle decisions;
- works across more than one supported harness or has a clear path to doing so;
- can be explained using local evidence cctop already owns or can safely check.

A feature is suspect when it:

- turns cctop into a full Git GUI, project manager, or agent runner;
- requires silent mutation of another tool's configuration or conversation state;
- depends on private or brittle harness internals when a visible handoff is
  safer;
- adds polling, directory walking, or background work without a user-visible
  reason and clear in-progress UI;
- makes the product feel heavier than a menubar utility.

Ask these questions before building:

1. Does this reduce lost attention or context switching?
2. Does this make a local action safer or easier to trust?
3. Does this work across harnesses, or can it become cross-harness naturally?
4. Does this preserve the menubar app's lightweight feel?
5. Does this introduce new trust, privacy, or permission risk?

## Non-goals

cctop should not become:

- a full Git GUI;
- a general project manager;
- an agent orchestration/control plane that silently drives other tools;
- a dashboard that demands sustained attention;
- a cloud service for session content or telemetry.

Future features can touch Git, projects, or agent coordination when they serve a
golden workflow, but the product should keep its center of gravity as local
awareness, navigation, and trustworthy action.

## Integration Quality Bar

An integration is best when it reports lifecycle events reliably and lets cctop
jump to the exact working surface. Exact thread, pane, tab, or workspace focus is
better than app activation; app activation is better than a dead affordance.

When an integration cannot support exact navigation or complete lifecycle data,
cctop should be honest about the fallback. Do not turn brittle private internals
into product promises. Prefer visible setup, trust, and recovery flows over
silent mutation.

## Cleanup Workflow Guidance

Cleanup is a decision-support workflow, not a blind deletion tool.

- Show ended-session worktrees only when cctop can tie them to session data.
- Use live Git and filesystem checks to classify candidates as clean, review, or
  ignored.
- Keep concrete evidence visible for review cases, especially local files,
  unique commits, locked worktrees, unknown branches, submodules, and unreadable
  status.
- For clean candidates, offer a direct remove action.
- For review candidates, require extra confirmation and explain why.
- Avoid broad protected-folder access. If a path is merely a historical project
  path and not plausibly a cctop-managed worktree, skip it before probing.

## Failure-State Rules

When cctop cannot prove something, it should say so plainly:

- prefer unknown, review, or unavailable over invented confidence;
- keep stale prior results visibly provisional during refreshes;
- show recovery actions when permission, trust, or setup blocks a workflow;
- fail closed for destructive actions.

## Terminology

- **Session**: one tracked AI coding conversation or run.
- **Project**: the local workspace path associated with a session.
- **Thread**: a desktop-app conversation surface when the host exposes one.
- **Workspace**: the editor, terminal, pane, tab, thread, or app surface the user
  needs to return to.
- **Worktree**: a Git worktree associated with completed or ongoing work.
- **Active**: a visible session with live work or recent state.
- **Idle**: a session that is connected but not currently asking for action.
- **Waiting**: a session that needs user input or permission.
- **Recent**: a remembered project or session target that is no longer active.
- **Clean**: a cleanup candidate whose fresh checks support direct removal.
- **Review**: a cleanup candidate that needs user inspection before removal.

## Copy And Language

- Prefer verbs that describe the real operation: "Checking" for validation of
  known candidates, "Scanning" only for broad discovery.
- Use "Review" for cases where the user must inspect risk, not "Warning" for
  every non-clean state.
- Use "Clean" only when fresh checks support the claim.
- Keep source/tool labels quiet unless the source changes what the user can do.
- Public copy should center the user's workflow and relief, not a feature
  inventory.

## Public Storytelling

When writing launch, website, README, or video copy, make the developer the
hero and cctop the guide. Start from the user's problem, show the moment cctop
helps, and include the payoff: the session is found, the right workspace opens,
or risky cleanup becomes clear.

Avoid product-first feature montages. The strongest story is not "cctop has
tabs, badges, themes, and integrations"; it is "you can keep multiple AI coding
sessions moving without losing track of the one that needs you."

For visual demos, introduce cctop the way a user first encounters it: a menubar
glance, a status change, a notification, or a jump back to work. Every action
beat should show its result.

## Documentation Boundaries

- `PRODUCT.md`: product promise, audience, feature fit, UX principles, and
  language choices.
- `DESIGN.md`: visual system, colors, typography, spacing, component shape, and
  visual guardrails.
- `AGENTS.md`: development workflow, architecture, testing, release, debugging,
  and repo-specific agent rules.
- `README.md`: user-facing product description, install, supported tools, and
  public FAQ.
- `site/README.md`: website publishing and sync rules.
- `.agents/skills/`: repeatable operational workflows that are too specific for
  product principles.

Keep personal preferences, private machine paths, temporary screenshots,
unpublished strategy notes, and local investigation artifacts out of this file.
