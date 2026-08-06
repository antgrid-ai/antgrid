// The vocabulary every agent's event mapper normalizes INTO, plus the builders
// that stamp it onto an AgentItem. Each agent keeps its own table (a codex
// `commandExecution` and an opencode `bash` are the same card from different
// wire words); what they may produce is decided here, once.

import type { AgentError, AgentItem } from "../protocol";

export type ToolContent = NonNullable<AgentItem["content"]>;

/** The closed set of tool kinds the transcript renders. `other` is the honest
 *  answer for a tool this vocabulary has no row for — never a synonym. The app
 *  gives edit/read/mcp/search their own glyph and everything else the terminal
 *  glyph (tool_call_card.dart's _kindIcon); adding a member here without an app
 *  change is safe and renders as the terminal glyph. */
export type ToolKind =
  | "shell" | "edit" | "read" | "search" | "fetch" | "task" | "mcp" | "image" | "other";

/** Tool-call and subtask lifecycle. `cancelled` is subtask-only today. */
export type ToolStatus = "pending" | "running" | "completed" | "error" | "cancelled";

/** Plan-entry status (codex turn/plan/updated, opencode todo.updated). */
export type PlanStatus = "pending" | "running" | "completed" | "cancelled";

/** Tool output routing: shell output is a terminal pane, everything else is
 *  text. Empty output yields no content rows at all rather than a blank pane. */
export function toolOutput(kind: ToolKind, output: string): ToolContent {
  if (!output) return [];
  return kind === "shell"
    ? [{ type: "terminal", data: output }]
    : [{ type: "text", text: output }];
}

/** An absent field is omitted rather than emitted as `undefined`, so a mapper
 *  that has nothing to say about a tool's status leaves the app's own default
 *  standing instead of overwriting a cached value with a hole. */
export function toolCall(f: {
  itemId: string;
  toolKind: ToolKind;
  status?: ToolStatus;
  title?: string;
  rawInput?: unknown;
  rawOutput?: unknown;
  content?: ToolContent;
  error?: AgentError;
}): AgentItem {
  return {
    itemId: f.itemId,
    kind: "tool_call",
    toolKind: f.toolKind,
    ...(f.status !== undefined ? { status: f.status } : {}),
    ...(f.title !== undefined ? { title: f.title } : {}),
    ...(f.rawInput !== undefined ? { rawInput: f.rawInput } : {}),
    ...(f.rawOutput !== undefined ? { rawOutput: f.rawOutput } : {}),
    ...(f.content !== undefined ? { content: f.content } : {}),
    ...(f.error !== undefined ? { error: f.error } : {}),
  };
}

export function subtask(f: {
  itemId: string;
  status: ToolStatus;
  title?: string;
  agent?: string;
  parentItemId?: string;
  error?: AgentError;
}): AgentItem {
  return {
    itemId: f.itemId,
    kind: "subtask",
    status: f.status,
    ...(f.title !== undefined ? { title: f.title } : {}),
    ...(f.agent !== undefined ? { agent: f.agent } : {}),
    ...(f.parentItemId !== undefined ? { parentItemId: f.parentItemId } : {}),
    ...(f.error !== undefined ? { error: f.error } : {}),
  };
}

export function message(f: {
  itemId: string;
  role: "assistant" | "user";
  text: string;
  revertTarget?: AgentItem["revertTarget"];
}): AgentItem {
  return {
    itemId: f.itemId,
    kind: "message",
    role: f.role,
    text: f.text,
    ...(f.revertTarget !== undefined ? { revertTarget: f.revertTarget } : {}),
  };
}

export function reasoning(f: { itemId: string; text: string }): AgentItem {
  return { itemId: f.itemId, kind: "reasoning", text: f.text };
}

export function compaction(f: { itemId: string; summary?: string }): AgentItem {
  return {
    itemId: f.itemId,
    kind: "compaction",
    ...(f.summary !== undefined ? { summary: f.summary } : {}),
  };
}
