import { z } from "zod";

export const AgentErrorSchema = z.object({
  category: z.enum([
    "rate_limited", "server_error", "auth", "context_overflow",
    "quota_exceeded", "network", "aborted", "unknown",
  ]),
  message: z.string(),
  retryable: z.boolean(),
  retryAfterMs: z.number().optional(),
  httpStatus: z.number().optional(),
  provider: z.string().optional(),
  raw: z.unknown().optional(),
});

export const ToolContentSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("text"), text: z.string() }),
  z.object({
    type: z.literal("diff"),
    path: z.string(),
    oldText: z.string().optional(),
    newText: z.string(),
    range: z.object({ start: z.number(), end: z.number() }).optional(),
  }),
  z.object({ type: z.literal("terminal"), data: z.string() }),
]);

export const AgentItemSchema = z.object({
  itemId: z.string(),
  parentItemId: z.string().optional(),
  kind: z.string(), // message | reasoning | tool_call | plan | subtask | compaction (+future)
  revertTarget: z.object({
    messageId: z.string().optional(),
    partId: z.string().optional(),
  }).optional(),
  // message / reasoning
  role: z.enum(["assistant", "user"]).optional(),
  text: z.string().optional(),
  // tool_call
  status: z.string().optional(),
  toolKind: z.string().optional(),
  title: z.string().optional(),
  rawInput: z.unknown().optional(),
  rawOutput: z.unknown().optional(),
  content: z.array(ToolContentSchema).optional(),
  error: AgentErrorSchema.optional(),
  // plan
  entries: z.array(z.object({ text: z.string(), status: z.string() })).optional(),
  // subtask
  agent: z.string().optional(),
  // compaction
  summary: z.string().optional(),
});

export const AgentUsageSchema = z.object({
  inputTokens: z.number().optional(),
  outputTokens: z.number().optional(),
  cacheReadTokens: z.number().optional(),
  cacheWriteTokens: z.number().optional(),
  reasoningTokens: z.number().optional(),
  totalTokens: z.number().optional(),
  costUsd: z.number().optional(),
});

export const AgentTurnStartMessage = z.object({
  type: z.literal("agent:turn-start"),
  sessionId: z.string(),
  turnId: z.string(),
});

export const AgentSessionResetMessage = z.object({
  type: z.literal("agent:session-reset"),
  sessionId: z.string(),
});

export const AgentTurnEndMessage = z.object({
  type: z.literal("agent:turn-end"),
  sessionId: z.string(),
  turnId: z.string(),
  stopReason: z.enum(["end_turn", "cancelled", "error"]),
  usage: AgentUsageSchema.optional(),
  error: AgentErrorSchema.optional(),
});

/**
 * A resumed transcript, delivered as ONE frame instead of a frame per item.
 *
 * The relay drops routed frames past its per-pair rate limit and never
 * retransmits, so replaying an N-item transcript as N frames loses whatever
 * falls past the cap — including the trailing `agent:turn-end`, which leaves
 * the app rendering a turn that can never close. Batching makes the replay
 * atomic: it arrives whole or not at all.
 *
 * `frames` are AbMessage-shaped and re-dispatched individually by the
 * receiver; they can't be typed as AbMessage here without making the union
 * self-referential.
 */
export const AgentTranscriptReplayMessage = z.object({
  type: z.literal("agent:transcript-replay"),
  sessionId: z.string(),
  frames: z.array(z.record(z.string(), z.unknown())),
});

export const AgentItemAddedMessage = z.object({
  type: z.literal("agent:item-added"),
  sessionId: z.string(),
  turnId: z.string(),
  itemId: z.string(),
  parentItemId: z.string().optional(),
  item: AgentItemSchema,
});

export const AgentItemDeltaMessage = z.object({
  type: z.literal("agent:item-delta"),
  sessionId: z.string(),
  turnId: z.string(),
  itemId: z.string(),
  textChunk: z.string(),
});

export const AgentItemUpdatedMessage = z.object({
  type: z.literal("agent:item-updated"),
  sessionId: z.string(),
  turnId: z.string(),
  itemId: z.string(),
  item: AgentItemSchema,
});

export const AgentSnapshotMessage = z.object({
  type: z.literal("agent:snapshot"),
  sessionId: z.string(),
  turnId: z.string(),
  items: z.array(AgentItemSchema),
});

export const AgentCapabilitiesMessage = z.object({
  type: z.literal("agent:capabilities"),
  sessionId: z.string(),
  // false = discovery still in flight (models/modes not yet populated), true =
  // catalog settled. Drivers emit an early ready:false frame on start so the app
  // can show a loading indicator; absence defaults to ready (legacy/replay).
  ready: z.boolean().optional(),
  commands: z.array(z.object({ id: z.string(), name: z.string(), description: z.string().optional(), argHint: z.string().optional() })).optional(),
  modes: z.array(z.object({ id: z.string(), name: z.string(), description: z.string().optional() })).optional(),
  models: z.array(z.object({
    id: z.string(),
    name: z.string(),
    provider: z.string().optional(),
    efforts: z.array(z.string()).optional(),
    defaultEffort: z.string().optional(),
  })).optional(),
  currentModeId: z.string().optional(),
  currentModelId: z.string().optional(),
  currentEffortId: z.string().optional(),
});

// Proactive "a newer coding-agent CLI exists" notice (bridge -> app). Advisory
// only: the app surfaces a dismissible chip, never a modal (codex exposes no
// per-model minimum version, so this can't assert the update is *required* —
// the reactive turn-error path is the precise signal). `tool` is the agent
// spec id ("codex" | "claude-code" | ...); `sessionId` is the chat session that
// triggered the check, carried for routing context.
export const AgentUpdateAvailableMessage = z.object({
  type: z.literal("agent:updateAvailable"),
  tool: z.string(),
  installed: z.string(),
  latest: z.string(),
  sessionId: z.string().optional(),
});

// App -> agent: run the agent CLI's in-app self-update (codex/claude `update`,
// opencode `upgrade` — see each agent's `update` in agents/registry.ts). A project verb
// — gated by the same pairing + allowlist chokepoint as every other inbound
// message (see currentPhoneAllowed() in agent-core). The update is machine-
// global, so the bridge quiesces every live chat session of that tool, updates
// once, then restarts them. `sessionId` is the chat session that raised the
// notice (routing context for the result). A `tool` with no known self-updater
// fails soft with an agent:updateResult message.
export const AgentUpdateMessage = z.object({
  type: z.literal("agent:update"),
  tool: z.string(),
  sessionId: z.string().optional(),
});

// Agent -> app: terminal outcome of an agent:update run. `installed` is the
// re-probed version after a successful update; `output` is a bounded tail of the
// updater's combined stdout+stderr, surfaced on failure.
export const AgentUpdateResultMessage = z.object({
  type: z.literal("agent:updateResult"),
  tool: z.string(),
  sessionId: z.string().optional(),
  ok: z.boolean(),
  exitCode: z.number().optional(),
  installed: z.string().optional(),
  output: z.string().optional(),
});

export const AgentPermissionRequestMessage = z.object({
  type: z.literal("agent:permission-request"),
  sessionId: z.string(),
  permissionId: z.string(),
  itemId: z.string().optional(),
  title: z.string(),
  reason: z.string().optional(),
  options: z.array(z.object({
    optionId: z.string(),
    label: z.string(),
    kind: z.enum(["allow_once", "allow_always", "reject"]),
  })),
});

export const AgentQuestionMessage = z.object({
  type: z.literal("agent:question"),
  sessionId: z.string(),
  questionId: z.string(),
  itemId: z.string().optional(),
  kind: z.enum(["text", "single_select", "multi_select"]),
  prompt: z.string(),
  // The answer is sensitive (codex requestUserInput isSecret) — clients should
  // mask input. Rendering is deferred to the UI cycle; carrying it now means
  // that cycle needs no bridge change.
  isSecret: z.boolean().optional(),
  options: z.array(z.object({ id: z.string(), label: z.string(), description: z.string().optional() })).optional(),
});

// A previously sent permission-request/question is no longer answerable
// (agent retracted it, turn ended, or the driver was disposed) — the app
// must drop it from its pending lists. Exactly one of the two ids is set.
export const AgentRequestRetractedMessage = z.object({
  type: z.literal("agent:request-retracted"),
  sessionId: z.string(),
  permissionId: z.string().optional(),
  questionId: z.string().optional(),
});

export const AgentErrorMessage = z.object({
  type: z.literal("agent:error"),
  sessionId: z.string(),
  turnId: z.string().optional(),
  error: AgentErrorSchema,
});

// Cumulative token usage for the session. Carried as its own low-frequency
// message (not on turn-end) because codex reports usage via a thread-level
// stream (thread/tokenUsage/updated) decoupled from turn boundaries.
export const AgentUsageMessage = z.object({
  type: z.literal("agent:usage"),
  sessionId: z.string(),
  turnId: z.string().optional(),
  // Anchors a historical usage frame to the assistant message it describes.
  // Live frames omit it so replayed history cannot replace live meter state.
  itemId: z.string().optional(),
  total: AgentUsageSchema,
  last: AgentUsageSchema.optional(),
  contextWindow: z.number().nullable().optional(),
});

// Live inventory of the agent's background tasks (backgrounded shells,
// subagents, monitors). Latest-wins full-list semantics like
// agent:capabilities: each frame REPLACES the session's list; a finished task
// simply drops out. Session-scoped — tasks outlive turns.
export const AgentBackgroundTaskSchema = z.object({
  // Driver-native handle — what agent:task-stop takes, opaque to everyone else.
  // Unique only within the live list: codex's is the unified-exec processId (an
  // OS pid, reusable once the process is gone), so never key anything durable
  // off it.
  taskId: z.string(),
  kind: z.string(), // shell | subagent | monitor | workflow (+future)
  title: z.string(), // command line for shells, description otherwise
  status: z.string(), // driver-native: running | pending | paused (+future)
  // The transcript tool_call item this task detached from, when known.
  itemId: z.string().optional(),
  startedAt: z.number().optional(), // epoch ms
  killable: z.boolean().optional(), // absent = true
});

export const AgentBackgroundTasksMessage = z.object({
  type: z.literal("agent:background-tasks"),
  sessionId: z.string(),
  tasks: z.array(AgentBackgroundTaskSchema),
});

// App -> agent: stop one background task. Routed to the driver's stopTask
// (claude Query.stopTask / codex thread/backgroundTerminals/terminate).
export const AgentTaskStopMessage = z.object({
  type: z.literal("agent:task-stop"),
  sessionId: z.string(),
  taskId: z.string(),
});

// ── Inbound app→agent control-plane messages ──────────────────────────────────
// These carry the app's intent into the active agent session. sessionId scopes
// each message to one running agent session (not the project). requestId on
// agent:prompt ties the turn to the app's send action for correlation.

export const AgentPromptMessage = z.object({
  type: z.literal("agent:prompt"),
  sessionId: z.string(),
  requestId: z.string(),
  text: z.string(),
  commandId: z.string().optional(), // present => slash command invocation
});

export const AgentCancelMessage = z.object({
  type: z.literal("agent:cancel"),
  sessionId: z.string(),
  turnId: z.string().optional(),
});

export const AgentSetConfigMessage = z.object({
  type: z.literal("agent:set-config"),
  sessionId: z.string(),
  key: z.string(),
  value: z.unknown(),
});

export const AgentSessionActionMessage = z.object({
  type: z.literal("agent:session-action"),
  sessionId: z.string(),
  action: z.enum(["compact", "revert"]),
  turnId: z.string().optional(),
  itemId: z.string().optional(),
  messageId: z.string().optional(),
  partId: z.string().optional(),
});

export const AgentPermissionResolveMessage = z.object({
  type: z.literal("agent:permission-resolve"),
  sessionId: z.string(),
  permissionId: z.string(),
  optionId: z.string(),
});

export const AgentQuestionResolveMessage = z.object({
  type: z.literal("agent:question-resolve"),
  sessionId: z.string(),
  questionId: z.string(),
  answer: z.union([z.string(), z.array(z.string())]),
});

