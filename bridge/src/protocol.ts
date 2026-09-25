import * as agentPayloads from "antgrid-agents/payloads";
import { z } from "zod";
import { AbConfigSchema } from "./config";
import { KNOWN_TIERS } from "./entitlement";
import {
  ARTIFACT_CHUNK_B64_MAX,
  ARTIFACT_CHUNK_BYTES,
  MAX_PARTS,
  MAX_PART_CHARS,
  MAX_SUMMARY_CHARS,
  MAX_UNEXPECTED_CHARS,
} from "./session-bus/constants";
// The frame-display payload sub-schemas and their byte/row budgets live with the
// implementation that has to honour them; only the eight wire ENVELOPES are
// declared here (see the block below TerminalSnapshotMessage for why).
import {
  TERMINAL_HISTORY_PAGE_ROWS,
  TERMINAL_PROTOCOL_VERSION,
  TerminalHistoryBoundarySchema,
  TerminalHistoryRowSchema,
  TerminalScreenFrameSchema,
} from "./terminal-frames/protocol";

const BaseMessage = z.object({
  id: z.string().uuid(),
  timestamp: z.number(),
});

const AgentErrorSchema = agentPayloads.AgentErrorSchema;
const ToolContentSchema = agentPayloads.ToolContentSchema;
const AgentItemSchema = agentPayloads.AgentItemSchema;
const AgentUsageSchema = agentPayloads.AgentUsageSchema;
const AgentTurnStartMessage = agentPayloads.AgentTurnStartMessage.extend(BaseMessage.shape);
const AgentSessionResetMessage = agentPayloads.AgentSessionResetMessage.extend(BaseMessage.shape);
const AgentTurnEndMessage = agentPayloads.AgentTurnEndMessage.extend(BaseMessage.shape);
const AgentTranscriptReplayMessage = agentPayloads.AgentTranscriptReplayMessage.extend(BaseMessage.shape);
const AgentItemAddedMessage = agentPayloads.AgentItemAddedMessage.extend(BaseMessage.shape);
const AgentItemDeltaMessage = agentPayloads.AgentItemDeltaMessage.extend(BaseMessage.shape);
const AgentItemUpdatedMessage = agentPayloads.AgentItemUpdatedMessage.extend(BaseMessage.shape);
const AgentSnapshotMessage = agentPayloads.AgentSnapshotMessage.extend(BaseMessage.shape);
const AgentCapabilitiesMessage = agentPayloads.AgentCapabilitiesMessage.extend(BaseMessage.shape);
const AgentUpdateAvailableMessage = agentPayloads.AgentUpdateAvailableMessage.extend(BaseMessage.shape);
const AgentUpdateMessage = agentPayloads.AgentUpdateMessage.extend(BaseMessage.shape);
const AgentUpdateResultMessage = agentPayloads.AgentUpdateResultMessage.extend(BaseMessage.shape);
const AgentPermissionRequestMessage = agentPayloads.AgentPermissionRequestMessage.extend(BaseMessage.shape);
const AgentQuestionMessage = agentPayloads.AgentQuestionMessage.extend(BaseMessage.shape);
const AgentRequestRetractedMessage = agentPayloads.AgentRequestRetractedMessage.extend(BaseMessage.shape);
const AgentErrorMessage = agentPayloads.AgentErrorMessage.extend(BaseMessage.shape);
const AgentUsageMessage = agentPayloads.AgentUsageMessage.extend(BaseMessage.shape);
const AgentBackgroundTaskSchema = agentPayloads.AgentBackgroundTaskSchema;
const AgentBackgroundTasksMessage = agentPayloads.AgentBackgroundTasksMessage.extend(BaseMessage.shape);
const AgentTaskStopMessage = agentPayloads.AgentTaskStopMessage.extend(BaseMessage.shape);
const AgentPromptMessage = agentPayloads.AgentPromptMessage.extend(BaseMessage.shape);
const AgentCancelMessage = agentPayloads.AgentCancelMessage.extend(BaseMessage.shape);
const AgentSetConfigMessage = agentPayloads.AgentSetConfigMessage.extend(BaseMessage.shape);
const AgentSessionActionMessage = agentPayloads.AgentSessionActionMessage.extend(BaseMessage.shape);
const AgentPermissionResolveMessage = agentPayloads.AgentPermissionResolveMessage.extend(BaseMessage.shape);
const AgentQuestionResolveMessage = agentPayloads.AgentQuestionResolveMessage.extend(BaseMessage.shape);

// Filesystem-sensitive frames are scoped explicitly. Zod supplies `main` for
// old apps, while an explicit unknown id is rejected by the checkout registry.
const CheckoutScoped = { checkoutId: z.string().default("main") };

// Recursive FileTreeNode schema
const FileTreeNodeSchema: z.ZodType<{
  name: string;
  path: string;
  type: "file" | "directory";
  size?: number;
  extension?: string;
  children?: any[];
  truncated?: true;
}> = z.lazy(() =>
  z.object({
    name: z.string(),
    path: z.string(),
    type: z.enum(["file", "directory"]),
    size: z.number().optional(),
    extension: z.string().optional(),
    children: z.array(FileTreeNodeSchema).optional(),
    // The directory's listing was cut at the tree's node budget — see
    // MAX_TREE_NODES in file-tree.ts.
    truncated: z.literal(true).optional(),
  }),
);

const TerminalOutputMessage = BaseMessage.extend({
  type: z.literal("terminal:output"),
  terminalId: z.string(),
  data: z.string(),
  seq: z.number().int().nonnegative().optional(),
  ...CheckoutScoped,
});

const TerminalInputMessage = BaseMessage.extend({
  type: z.literal("terminal:input"),
  terminalId: z.string(),
  data: z.string(),
  ...CheckoutScoped,
});

const TerminalStartedMessage = BaseMessage.extend({
  type: z.literal("terminal:started"),
  terminalId: z.string(),
  shell: z.string(),
  cols: z.number().int().positive(),
  rows: z.number().int().positive(),
  // "agent" for session-backed PTYs, "service" for antgrid.yaml services,
  // omitted for ad-hoc shells. Lets the app classify the tab without
  // waiting for the next agent:status frame.
  terminalType: z.enum(["agent", "service"]).optional(),
  ...CheckoutScoped,
});

const TerminalExitedMessage = BaseMessage.extend({
  type: z.literal("terminal:exited"),
  terminalId: z.string(),
  exitCode: z.number().int().nullable(),
  ...CheckoutScoped,
});

const TerminalNotificationMessage = BaseMessage.extend({
  type: z.literal("terminal:notification"),
  terminalId: z.string(),
  kind: z.enum(["osc9", "osc777"]),
  title: z.string().optional(),
  body: z.string().optional(),
  ...CheckoutScoped,
});

const TerminalBellMessage = BaseMessage.extend({
  type: z.literal("terminal:bell"),
  terminalId: z.string(),
  runId: z.string().uuid(),
  ...CheckoutScoped,
});

const PingMessage = BaseMessage.extend({
  type: z.literal("ping"),
});

const PongMessage = BaseMessage.extend({
  type: z.literal("pong"),
});

// A native peer session is established by one plaintext hello per connection —
// QUIC/TLS between authorized endpoints is the confidentiality layer, so
// there is no transcript to sign and nothing to confirm. Bare session frames
// like this one carry no `id`/`timestamp` envelope, so they are deliberately
// NOT members of `AbMessageSchema`/`KNOWN_TYPES` — see the comment above
// `PeerSessionOwner.handleHello` (peer-session-owner.ts) for why, and never
// add them there.
export const SessionHelloCapabilities = z.object({
  checkoutRouting: z.literal(true).optional(),
  pullsTree: z.literal(true).optional(),
  // The app can render `terminal:frame` display mode. Absent means it cannot,
  // and the read of it MUST fail closed (unknown peer reads false) or an old
  // app is switched into a mode it has no renderer for.
  terminalFramesV1: z.literal(true).optional(),
});
export const SessionHelloFrame = z.object({
  type: z.literal("session:hello"),
  attemptId: z.string().min(1).max(256),
  capabilities: SessionHelloCapabilities.optional(),
});
export const SessionEstablishedFrame = z.object({
  type: z.literal("established"),
  attemptId: z.string().min(1).max(256),
});

const TerminalStartCommand = BaseMessage.extend({
  type: z.literal("terminal:start"),
  terminalId: z.string(),
  name: z.string().optional(),
  command: z.string().optional(),
  args: z.array(z.string()).optional(),
  cwd: z.string().optional(),
  env: z.record(z.string(), z.string()).optional(),
  ...CheckoutScoped,
});

const TerminalStopCommand = BaseMessage.extend({
  type: z.literal("terminal:stop"),
  terminalId: z.string(),
  ...CheckoutScoped,
});

const TerminalResizeCommand = BaseMessage.extend({
  type: z.literal("terminal:resize"),
  terminalId: z.string(),
  cols: z.number().int().positive(),
  rows: z.number().int().positive(),
  clientId: z.string(),
  intent: z.enum(["resize", "takeover"]),
  baseDriverClientId: z.string().optional(),
  ...CheckoutScoped,
});

const TerminalSizeMessage = BaseMessage.extend({
  type: z.literal("terminal:size"),
  terminalId: z.string(),
  cols: z.number().int().positive(),
  rows: z.number().int().positive(),
  // The clientId whose resize the PTY currently follows. A client renders
  // with this grid; passive viewers center and scale it down when needed.
  driverClientId: z.string(),
  ...CheckoutScoped,
});

const TerminalStatusInfo = z.object({
  terminalId: z.string(),
  name: z.string(),
  running: z.boolean(),
  shell: z.string(),
  cols: z.number().int().positive(),
  rows: z.number().int().positive(),
  driverClientId: z.string().optional(),
});

const ServiceStatusInfo = z.object({
  id: z.string(),
  name: z.string(),
  running: z.boolean(),
  command: z.string(),
  exitCode: z.number().int().optional(),
});

const CommandInfo = z.object({
  name: z.string(),
  confirm: z.boolean().optional(),
  description: z.string().optional(),
  icon: z.string().optional(),
});

const PortInfo = z.object({
  port: z.number().int().positive(),
  name: z.string().optional(),
  url: z.string().optional(),
  scheme: z.enum(["http", "https"]).optional(),
  onDetect: z.enum(["notify", "openPreview", "silent", "ignore"]),
  source: z.enum(["process", "output", "declared"]),
});

const AgentStatusMessage = BaseMessage.extend({
  type: z.literal("agent:status"),
  projectId: z.string().optional(),
  projectName: z.string().optional(),
  hostMachineName: z.string().optional(),
  terminals: z.array(TerminalStatusInfo),
  services: z.array(ServiceStatusInfo).optional(),
  commands: z.array(CommandInfo).optional(),
  ports: z.array(PortInfo).optional(),
  // Counts are LOCAL (against the upstream ref), so they are as fresh as the
  // last fetch — see [readSyncState] in git-sync.ts for why nothing here may
  // reach the network. All three are optional so an older bridge still parses.
  git: z.object({
    branch: z.string(),
    ahead: z.number().int().nonnegative().optional(),
    behind: z.number().int().nonnegative().optional(),
    hasUpstream: z.boolean().optional(),
  }).optional(),
  agent: z.object({
    tool: z.string().optional(),
    name: z.string().optional(),
    version: z.string(),
    flags: z.array(z.string()).optional(),
  }),
  needsFirstRun: z.boolean().optional(),
  ...CheckoutScoped,
});

const GitFileStatus = z.object({
  path: z.string(),
  status: z.enum(["M", "A", "D", "R", "U", "!"]),
  staged: z.boolean(),
  // Pre-rename path, populated only for status "R" (the tree only has a node
  // for the new path, so this is what a future "renamed from X" tooltip needs).
  oldPath: z.string().optional(),
  // Line-level diff stat vs HEAD (combined staged+unstaged); 0/0 for a merge
  // conflict or a binary file. Optional so a hand-built fixture (or an older
  // sender) that omits them still validates — absence reads as "unknown", the
  // app already treats it as 0.
  additions: z.number().int().nonnegative().optional(),
  deletions: z.number().int().nonnegative().optional(),
  // Both are sent only for status "!" (see [ConflictKind] in git.ts), and both
  // are optional so an older bridge still validates. Absence of
  // conflictResolved reads as "not resolved", which is what makes the app ask
  // before it stages an unmerged path — the safe direction.
  conflictKind: z
    .enum([
      "bothModified",
      "bothAdded",
      "bothDeleted",
      "addedByUs",
      "addedByThem",
      "deletedByUs",
      "deletedByThem",
    ])
    .optional(),
  conflictResolved: z.boolean().optional(),
});

const GitStatusMessage = BaseMessage.extend({
  type: z.literal("git:status"),
  projectId: z.string(),
  files: z.array(GitFileStatus),
  ...CheckoutScoped,
});

const GitDiffRequestMessage = BaseMessage.extend({
  type: z.literal("git:diff"),
  projectId: z.string(),
  path: z.string(),
  ...CheckoutScoped,
});

const GitDiffContentMessage = BaseMessage.extend({
  type: z.literal("git:diff-content"),
  projectId: z.string(),
  path: z.string(),
  diff: z.string().nullable(),
  additions: z.number().int(),
  deletions: z.number().int(),
  ...CheckoutScoped,
});

const GitListBranchesMessage = BaseMessage.extend({
  type: z.literal("git:list-branches"),
  projectId: z.string(),
  ...CheckoutScoped,
});

const GitBranchesMessage = BaseMessage.extend({
  type: z.literal("git:branches"),
  projectId: z.string(),
  current: z.string(),
  branches: z.array(z.string()),
  ...CheckoutScoped,
});

const GitCheckoutMessage = BaseMessage.extend({
  type: z.literal("git:checkout"),
  projectId: z.string(),
  branch: z.string(),
  ...CheckoutScoped,
});

const GitCheckoutResultMessage = BaseMessage.extend({
  type: z.literal("git:checkout-result"),
  projectId: z.string(),
  branch: z.string(),
  success: z.boolean(),
  error: z.string().optional(),
  ...CheckoutScoped,
});

const GitCommitMessage = BaseMessage.extend({
  type: z.literal("git:commit"),
  projectId: z.string(),
  message: z.string(),
  ...CheckoutScoped,
});

const GitCommitResultMessage = BaseMessage.extend({
  type: z.literal("git:commit-result"),
  projectId: z.string(),
  success: z.boolean(),
  sha: z.string().optional(),
  error: z.string().optional(),
  ...CheckoutScoped,
});

const GitDiscardMessage = BaseMessage.extend({
  type: z.literal("git:discard"),
  projectId: z.string(),
  files: z.array(z.string()),
  /** Revert each path all the way to HEAD, staged content included. Absent
   * from an older app, which discards worktree edits only — see [gitDiscard]. */
  includeStaged: z.boolean().optional(),
  ...CheckoutScoped,
});

const GitDiscardResultMessage = BaseMessage.extend({
  type: z.literal("git:discard-result"),
  projectId: z.string(),
  success: z.boolean(),
  files: z.array(z.string()),
  error: z.string().optional(),
  ...CheckoutScoped,
});

const GitStageMessage = BaseMessage.extend({
  type: z.literal("git:stage"),
  projectId: z.string(),
  files: z.array(z.string()),
  ...CheckoutScoped,
});

const GitStageResultMessage = BaseMessage.extend({
  type: z.literal("git:stage-result"),
  projectId: z.string(),
  success: z.boolean(),
  files: z.array(z.string()),
  error: z.string().optional(),
  ...CheckoutScoped,
});

const GitUnstageMessage = BaseMessage.extend({
  type: z.literal("git:unstage"),
  projectId: z.string(),
  files: z.array(z.string()),
  ...CheckoutScoped,
});

const GitUnstageResultMessage = BaseMessage.extend({
  type: z.literal("git:unstage-result"),
  projectId: z.string(),
  success: z.boolean(),
  files: z.array(z.string()),
  error: z.string().optional(),
  ...CheckoutScoped,
});

const GitStashEntrySchema = z.object({
  ref: z.string(),
  /** "" when unparseable — see `parseStashSubject` in git-branches.ts. */
  branch: z.string(),
  message: z.string(),
  createdAt: z.number(),
});

const GitStashListRequestMessage = BaseMessage.extend({
  type: z.literal("git:stash-list"),
  projectId: z.string(),
  ...CheckoutScoped,
});

const GitStashListResultMessage = BaseMessage.extend({
  type: z.literal("git:stash-list-result"),
  projectId: z.string(),
  stashes: z.array(GitStashEntrySchema),
  error: z.string().optional(),
  ...CheckoutScoped,
});

const GitStashPopMessage = BaseMessage.extend({
  type: z.literal("git:stash-pop"),
  projectId: z.string(),
  ref: z.string(),
  ...CheckoutScoped,
});

const GitStashPopResultMessage = BaseMessage.extend({
  type: z.literal("git:stash-pop-result"),
  projectId: z.string(),
  ref: z.string(),
  success: z.boolean(),
  error: z.string().optional(),
  ...CheckoutScoped,
});

const GitStashDropMessage = BaseMessage.extend({
  type: z.literal("git:stash-drop"),
  projectId: z.string(),
  ref: z.string(),
  ...CheckoutScoped,
});

const GitStashDropResultMessage = BaseMessage.extend({
  type: z.literal("git:stash-drop-result"),
  projectId: z.string(),
  ref: z.string(),
  success: z.boolean(),
  error: z.string().optional(),
  ...CheckoutScoped,
});

const GitLogEntrySchema = z.object({
  sha: z.string(),
  shortSha: z.string(),
  subject: z.string(),
  authorName: z.string(),
  authorEmail: z.string(),
  authorDate: z.string(),
});

const GitLogRequestMessage = BaseMessage.extend({
  type: z.literal("git:log"),
  projectId: z.string(),
  skip: z.number().int().nonnegative().default(0),
  limit: z.number().int().positive().default(50),
  ...CheckoutScoped,
});

const GitLogResultMessage = BaseMessage.extend({
  type: z.literal("git:log-result"),
  projectId: z.string(),
  commits: z.array(GitLogEntrySchema),
  skip: z.number().int().nonnegative(),
  /** Whether a further page exists past `skip + commits.length` — what the
   *  History tab's scroll-triggered fetch checks before asking for more. */
  hasMore: z.boolean(),
  error: z.string().optional(),
  ...CheckoutScoped,
});

const GitCommitFileEntrySchema = z.object({
  path: z.string(),
  status: z.enum(["M", "A", "D", "R"]),
  oldPath: z.string().optional(),
  additions: z.number().int(),
  deletions: z.number().int(),
});

const GitCommitFilesRequestMessage = BaseMessage.extend({
  type: z.literal("git:commit-files"),
  projectId: z.string(),
  sha: z.string(),
  ...CheckoutScoped,
});

const GitCommitFilesResultMessage = BaseMessage.extend({
  type: z.literal("git:commit-files-result"),
  projectId: z.string(),
  sha: z.string(),
  files: z.array(GitCommitFileEntrySchema),
  error: z.string().optional(),
  ...CheckoutScoped,
});

const GitCommitDiffRequestMessage = BaseMessage.extend({
  type: z.literal("git:commit-diff"),
  projectId: z.string(),
  sha: z.string(),
  path: z.string(),
  ...CheckoutScoped,
});

const GitCommitDiffContentMessage = BaseMessage.extend({
  type: z.literal("git:commit-diff-content"),
  projectId: z.string(),
  sha: z.string(),
  path: z.string(),
  diff: z.string().nullable(),
  additions: z.number().int(),
  deletions: z.number().int(),
  ...CheckoutScoped,
});

/** Why a push/pull did not happen. Mirrors [GitSyncFailureKind] in git-sync.ts
 *  and `GitSyncFailureKind` in the Dart model BY HAND; a receiver that meets an
 *  unrecognized value must read it as "unknown" rather than reject the frame,
 *  which is what lets a newer bridge add a kind without an app release. */
const GitSyncFailureKindSchema = z.enum([
  "no-remote", "no-upstream", "ambiguous-remote", "not-fast-forward",
  "rejected", "diverged", "auth", "conflict", "dirty-tree", "detached", "unknown",
]);

const GitSyncMessage = BaseMessage.extend({
  type: z.literal("git:sync"),
  projectId: z.string(),
  op: z.enum(["push", "pull"]),
  ...CheckoutScoped,
});

const GitSyncResultMessage = BaseMessage.extend({
  type: z.literal("git:sync-result"),
  projectId: z.string(),
  op: z.enum(["push", "pull"]),
  success: z.boolean(),
  /** Null on a detached HEAD — the one shape with no branch to name. */
  branch: z.string().nullable(),
  remote: z.string().optional(),
  remoteBranch: z.string().optional(),
  summary: z.string().optional(),
  error: z.string().optional(),
  failureKind: GitSyncFailureKindSchema.optional(),
  /** The git invocation and its verbatim stderr, present only on failure. They
   *  are carried rather than summarized because they are what the agent handoff
   *  forwards — the app never re-parses git's prose to build its own copy. */
  command: z.string().optional(),
  stderr: z.string().optional(),
  ...CheckoutScoped,
});

const GitSyncStatusMessage = BaseMessage.extend({
  type: z.literal("git:sync-status"),
  projectId: z.string(),
  /** Ask the REMOTE, not just the local upstream ref (see [readSyncState] vs
   *  [checkBranchAgainstRemote]). Costs a network round trip, so it is opt-in
   *  and never set by the refresh that rides git:status. */
  probeRemote: z.boolean().optional(),
  ...CheckoutScoped,
});

const GitSyncStateMessage = BaseMessage.extend({
  type: z.literal("git:sync-state"),
  projectId: z.string(),
  branch: z.string().nullable(),
  remote: z.string().nullable(),
  remoteBranch: z.string().nullable(),
  ahead: z.number().int().nonnegative(),
  behind: z.number().int().nonnegative(),
  hasUpstream: z.boolean(),
  hasRemote: z.boolean(),
  /** Present only when a probe actually reached the remote; the same wire
   *  strings [BranchRemoteState] already uses. Absent means the counts are
   *  local-only — as fresh as the last fetch, which is what the up/down
   *  indicator promises. */
  state: z.enum([
    "no-remote", "no-upstream", "gone", "in-sync",
    "behind", "ahead", "diverged", "differs", "unreachable",
  ]).optional(),
  ...CheckoutScoped,
});

// Port scanning & preview messages
const PortInfoSchema = z.object({
  port: z.number().int().positive(),
  pid: z.number().optional(),
  processName: z.string().optional(),
  label: z.string().optional(),
  // Detected dev-server scheme (from terminal-output URL sightings). Absent
  // means unknown; consumers should fall back to http.
  scheme: z.enum(["http", "https"]).optional(),
  // Only set for a config-declared port. Absent means undeclared (terminal-
  // detected only) — consumers should treat that the same as "notify".
  onDetect: z.enum(["notify", "openPreview", "silent", "ignore"]).optional(),
});

const PortsUpdateMessage = BaseMessage.extend({
  type: z.literal("ports:update"),
  projectId: z.string(),
  ports: z.array(PortInfoSchema),
  ...CheckoutScoped,
});

const PreviewUrlMessage = BaseMessage.extend({
  type: z.literal("preview:url"),
  projectId: z.string(),
  port: z.number(),
  url: z.string(),
  label: z.string().optional(),
  // Keep in lockstep with PreviewUrlEntrySchema.scheme: the live push and the
  // welcome-replayed snapshot carry the same entry, so a consumer must not need
  // to know which one it got (absent = no URL sighting yet, treat as http).
  scheme: z.enum(["http", "https"]).optional(),
  ...CheckoutScoped,
});

const AgentDisconnectingMessage = BaseMessage.extend({
  type: z.literal("agent:disconnecting"),
  reason: z.string().optional(),
});

// Per-project agent work status carried on the always-on control plane so the
// app's Recent/sidebar reflect live activity WITHOUT opening (warming) a
// project. Distinct from `running` (which means "dialable / holds a relay
// slot"): `attention` is the call-to-action (agent blocked on a permission/
// prompt). Optional on the wire — an older bridge omits it and the app falls
// back to `running`; an older app ignores it. Precedence when a project has
// multiple live signals: attention > error > working > unread > done.
//
// `unread` is the read-state half: the agent finished and nobody has visited
// the session since (work-status.ts owns the rule). It is per-session state
// that only the BRIDGE can answer — it sees every turn end and every
// `session:focus` from every client — so the app renders what it is told here
// and never derives or persists a read state of its own. An older app parses it
// as an unknown string and falls back to its own "no status" branch, which is
// why it ranks just above `done`: a stale reading of "idle" is the harmless one.
export const WorkStatusSchema = z.enum(["working", "attention", "unread", "done", "error"]);
export type WorkStatus = z.infer<typeof WorkStatusSchema>;

// Outbound agent→app: the always-on control plane advertises which of the
// phone's allowed projects exist (allowed ∩ catalog), with a running flag per
// project. E2E-opaque to the relay (like preview:url). No inbound switch case.
const AgentProjectsMessage = BaseMessage.extend({
  type: z.literal("agent:projects"),
  projects: z.array(
    z.object({
      projectId: z.string(),
      label: z.string().optional(),
      path: z.string().optional(),
      running: z.boolean(),
      status: WorkStatusSchema.optional(),
      // Live non-archived running-session count for warm cores (absent when
      // cold, like `status`). The app re-peeks a project's session list when
      // this changes — `status` alone can't signal it: a 2nd session starting
      // while one is already working stays "working", and done→working is
      // ambiguous between new-session and re-prompt (see app_shell's
      // _onControlPlaneState).
      runningSessions: z.number().int().nonnegative().optional(),
      // Per-running-session status, keyed by session id — what the app dots each
      // SESSION row with, since `status` above is only their rollup and would
      // otherwise paint a working session with its blocked sibling's amber.
      // PRESENCE is the capability signal: `{}` means "warm core, nothing
      // running", absent means an older bridge and the app falls back to
      // `status` for every session.
      sessionStatuses: z.record(z.string(), WorkStatusSchema).optional(),
      lastActiveAt: z.string().optional(),
    }),
  ),
  // Machine-level: the remote-access switch's live state, stamped on every
  // advert by current bridges (absent = older bridge). `false` is what lets a
  // phone explain an empty catalog ("remote access is off on that machine")
  // instead of rendering a neutral empty machine; `true` + empty projects
  // disambiguates "online, no projects yet" from offline. Must stay listed
  // here: this schema is what parseMessage keeps, so an undeclared field is
  // silently stripped off any re-parsed frame.
  remoteAccessEnabled: z.boolean().optional(),
});

/**
 * One agent as the registry describes it, independent of whether this machine
 * has it installed. The static half of the tools advertisement: `tools` says
 * what is on PATH here, this says what each agent IS. Every field is required
 * WITHIN the descriptor — a bridge that sends the array has answered all of it;
 * the array itself is what is optional.
 */
const AgentDescriptorSchema = z.object({
  tool: z.string(),
  label: z.string(),
  chatCapable: z.boolean(),
  judgeCapable: z.boolean(),
  handler: z.object({ terminal: z.boolean(), chat: z.boolean() }),
  approvalPolicies: z.object({
    terminal: z.array(z.enum(["default", "bypass"])),
    chat: z.array(z.enum(["default", "bypass"])),
  }),
  approvalPolicyRisk: z.enum(["bypasses-approvals", "bypasses-approvals-and-sandbox"]).optional(),
});
export type AgentDescriptor = z.infer<typeof AgentDescriptorSchema>;

// Outbound agent→app, control plane only: the machine's installed coding-agent
// tools (AGENTS ∩ PATH). Machine-level, NOT project-scoped — so it is not
// gated by the per-phone allowlist (which scopes projects, not tools). E2E-opaque
// to the relay. No inbound switch case.
const AgentToolsMessage = BaseMessage.extend({
  type: z.literal("agent:tools"),
  // `chatCapable`/`label` are optional for back-compat only — a current bridge
  // always sends both. Both must stay listed: this schema is what parseMessage
  // keeps, so a field missing here is silently stripped off the frame the app
  // reads it from.
  tools: z.array(
    z.object({
      tool: z.string(),
      path: z.string().optional(),
      chatCapable: z.boolean().optional(),
      label: z.string().optional(),
    }),
  ),
  // The whole registry, not just what is on PATH — see AgentDescriptorSchema.
  // A cached session row from another machine, and a picker that must offer
  // agents this machine lacks, both need facts the PATH probe structurally
  // cannot carry. Optional so a bridge predating it still parses; an app with no
  // descriptor falls back to its own last-known catalog.
  agents: z.array(AgentDescriptorSchema).optional(),
});

// Outbound agent→app, control plane only (A4): the project is ready to open a
// stream for. Two meanings share the one frame — a Hazard-J ready notice
// (gates the app's project-stream open: opening before this arrives gets an
// in-band `NOT_READY` refusal, never a park) and, per `ProjectStreamRegistry`
// (`project-streams.ts`), the bridge's own FIRST record on an admitted project
// stream, so the bind itself is observable to the app. An `agent:projects`
// entry with `running:true` is the same ready notice for a project the app
// learns about from the advert. No inbound switch case.
const StreamReadyMessage = BaseMessage.extend({
  type: z.literal("stream-ready"),
  projectId: z.string(),
});

// Outbound result for a control-plane verb (e.g. project:start). Success is
// usually conveyed by a fresh agent:projects re-advertisement; this carries the
// FAILURE feedback (NOT_ALLOWED / UNKNOWN_PROJECT / OPEN_FAILED) back to the
// phone so a rejected verb isn't silently dropped. `verb` echoes the request
// type for correlation. The phone keys error handling off `ok === false`.
const ControlResultMessage = BaseMessage.extend({
  type: z.literal("control:result"),
  ok: z.boolean(),
  verb: z.string().optional(),
  projectId: z.string().optional(),
  error: z.object({ code: z.string(), message: z.string() }).optional(),
  ...CheckoutScoped,
});

// File tree & code viewer messages
const TreeFullMessage = BaseMessage.extend({
  type: z.literal("tree:full"),
  projectId: z.string(),
  root: FileTreeNodeSchema,
  // Which revision of the watcher's tree this is. A resync push is the only
  // full tree that still reaches an app unasked, and an app that cannot name
  // the revision it holds cannot ask "still this one?" on the next resume —
  // see `sinceSeq` below. Optional so a pre-seq bridge still parses.
  seq: z.number().int().nonnegative().optional(),
  ...CheckoutScoped,
});

const TreeUpdateMessage = BaseMessage.extend({
  type: z.literal("tree:update"),
  projectId: z.string(),
  added: z.array(FileTreeNodeSchema),
  modified: z.array(FileTreeNodeSchema),
  removed: z.array(z.string()),
  seq: z.number().int().nonnegative().optional(),
  ...CheckoutScoped,
});

const FileReadMessage = BaseMessage.extend({
  type: z.literal("file:read"),
  projectId: z.string(),
  path: z.string(),
  ...CheckoutScoped,
});

const FileContentMessage = BaseMessage.extend({
  type: z.literal("file:content"),
  projectId: z.string(),
  path: z.string(),
  content: z.string().nullable(),
  size: z.number(),
  encoding: z.enum(["utf8", "base64"]).default("utf8"),
  mimeType: z.string().optional(),
  error: z.string().optional(),
  ...CheckoutScoped,
});

const FileResolvePathMessage = BaseMessage.extend({
  type: z.literal("file:resolve-path"),
  projectId: z.string(),
  requestId: z.string(),
  // Raw path as it appeared in terminal output (an OSC 8 `file://` hyperlink
  // target) — absolute on the bridge machine, or already checkout-relative.
  path: z.string(),
  ...CheckoutScoped,
});

const FileResolvePathResultMessage = BaseMessage.extend({
  type: z.literal("file:resolve-path-result"),
  projectId: z.string(),
  requestId: z.string(),
  // Checkout-relative, `/`-separated — the only form the app's file tree
  // understands. Null when the path does not resolve inside this checkout (a
  // path from elsewhere, a symlink escape, or unparsable garbage).
  relPath: z.string().nullable(),
  isDirectory: z.boolean(),
  // Absolute path, set only when relPath is null AND the path is a
  // recognized image outside the checkout (see file-tree.ts's
  // EXTERNAL_SAFE_IMAGE_MIME) — an image-generation tool's own output
  // directory, typically. Lets the app preview it read-only via `file:read`
  // (which applies the same extension gate again) instead of refusing the
  // link outright.
  externalImagePath: z.string().nullable(),
  ...CheckoutScoped,
});

const FileSearchMessage = BaseMessage.extend({
  type: z.literal("file:search"),
  projectId: z.string(),
  query: z.string(),
  caseSensitive: z.boolean(),
  regex: z.boolean(),
  wholeWord: z.boolean(),
  requestId: z.string(),
  ...CheckoutScoped,
});

const FileSearchCancelMessage = BaseMessage.extend({
  type: z.literal("file:search-cancel"),
  projectId: z.string(),
  requestId: z.string(),
  ...CheckoutScoped,
});

const SearchMatchSchema = z.object({
  path: z.string(),
  line: z.number(),
  column: z.number(),
  lineContent: z.string(),
  contextBefore: z.array(z.string()),
  contextAfter: z.array(z.string()),
});

const FileSearchResultMessage = BaseMessage.extend({
  type: z.literal("file:search-result"),
  projectId: z.string(),
  requestId: z.string(),
  matches: z.array(SearchMatchSchema),
  ...CheckoutScoped,
});

const FileSearchDoneMessage = BaseMessage.extend({
  type: z.literal("file:search-done"),
  projectId: z.string(),
  requestId: z.string(),
  totalMatches: z.number(),
  totalFiles: z.number(),
  duration: z.number(),
  engine: z.enum(["ripgrep", "git-grep"]),
  error: z.string().optional(),
  ...CheckoutScoped,
});

const FileUploadStartMessage = BaseMessage.extend({
  type: z.literal("file:upload-start"),
  projectId: z.string(),
  requestId: z.string(),
  fileName: z.string(),
  size: z.number().int().nonnegative(),
  mimeType: z.string().optional(),
  ...CheckoutScoped,
});

const FileUploadReadyMessage = BaseMessage.extend({
  type: z.literal("file:upload-ready"),
  requestId: z.string(),
  uploadId: z.string(),
  ...CheckoutScoped,
});

// 512 KiB payload → base64 is ~4/3 larger; 768 KiB caps a full chunk with room
// to spare while keeping a single frame well under the 1 MiB transport limit and
// bounding how much a malicious chunk can allocate before the size check runs.
const MAX_UPLOAD_CHUNK_DATA = 768 * 1024;

const FileUploadChunkMessage = BaseMessage.extend({
  type: z.literal("file:upload-chunk"),
  uploadId: z.string(),
  seq: z.number().int().nonnegative(),
  data: z.string().max(MAX_UPLOAD_CHUNK_DATA), // base64
  ...CheckoutScoped,
});

const FileUploadAckMessage = BaseMessage.extend({
  type: z.literal("file:upload-ack"),
  uploadId: z.string(),
  seq: z.number().int().nonnegative(),
  ...CheckoutScoped,
});

const FileUploadDoneMessage = BaseMessage.extend({
  type: z.literal("file:upload-done"),
  uploadId: z.string(),
  ...CheckoutScoped,
});

const FileUploadResultMessage = BaseMessage.extend({
  type: z.literal("file:upload-result"),
  requestId: z.string(),
  uploadId: z.string().optional(),
  ok: z.boolean(),
  path: z.string().optional(), // absolute path on the bridge machine
  // Project-relative twin of `path`, the only form `file:read` accepts — the
  // app never learns the checkout root, so it cannot derive this itself.
  relPath: z.string().optional(),
  // Set only when the staged file is one the app can render (same table as
  // file:read's own), so a client can offer a preview without duplicating the
  // allowlist. Absent = no viewer for it.
  mimeType: z.string().optional(),
  error: z.string().optional(), // machine code: TOO_LARGE | INVALID_NAME | WRITE_FAILED | UPLOAD_NOT_FOUND | BAD_SEQUENCE | SIZE_MISMATCH | TIMEOUT | BUSY
  message: z.string().optional(), // human-readable detail
  ...CheckoutScoped,
});

const CommandRunMessage = BaseMessage.extend({
  type: z.literal("command:run"),
  projectId: z.string(),
  commandName: z.string(),
  confirmed: z.boolean().optional(),
  ...CheckoutScoped,
});

const CommandOutputMessage = BaseMessage.extend({
  type: z.literal("command:output"),
  projectId: z.string(),
  commandName: z.string(),
  data: z.string(),
  ...CheckoutScoped,
});

const CommandDoneMessage = BaseMessage.extend({
  type: z.literal("command:done"),
  projectId: z.string(),
  commandName: z.string(),
  exitCode: z.number().int().nullable(),
  ...CheckoutScoped,
});

export const NotificationTypeSchema = z.enum(["task_complete", "permission_request", "awaiting_input", "question", "idle", "error"]);
export type NotificationType = z.infer<typeof NotificationTypeSchema>;

const NotificationPushMessage = BaseMessage.extend({
  type: z.literal("notification:push"),
  notificationType: NotificationTypeSchema,
  message: z.string().optional(),
  // Names the session that fired this (SessionEntry.name). Hand-mirrored in the
  // app's NotificationPushMessage — keep the two in lockstep.
  sessionTitle: z.string().optional(),
  // IDENTIFIES the session that fired this (SessionEntry.id == the hook's
  // terminalId), which `sessionTitle` cannot: a title is renameable and two
  // sessions may carry the same one. Hand-mirrored in the app's
  // NotificationPushMessage — keep the two in lockstep. Optional because a
  // notification need not name a slot at all (a service PTY, an older sender):
  // the reduction then falls back to its project-wide key (work-status.ts), and
  // the app cannot suppress the toast for a session you are already reading
  // (notification_routing.dart).
  sessionId: z.string().optional(),
  projectId: z.string().optional(),
});

/** The app encodes its persistent X25519 push key as standard base64 of the raw
 *  32 bytes (`base64Encode(pub.bytes)` in push_identity.dart); the bridge decodes
 *  it the same way in sealPush (`Buffer.from(b64, "base64")`). Validate that shape
 *  at parse time so a malformed key can't reach key-exchange.ts's createPublicKey,
 *  which throws SYNCHRONOUSLY and would abort the whole message-bus emit. Empty
 *  string is the CLEAR signal (sign-out) and stays valid. */
const PushPubkeyB64 = z.string().refine(
  (s) => {
    if (s === "") return true; // CLEAR signal
    // Buffer's base64 decode is lenient (silently drops stray chars), so also
    // require a clean round-trip to reject malformed/wrong-length input.
    const buf = Buffer.from(s, "base64");
    return buf.length === 32 && buf.toString("base64") === s;
  },
  { message: "pushPubkey must be base64 of a 32-byte X25519 key (or empty to clear)" },
);

const PushRegisterMessage = BaseMessage.extend({
  type: z.literal("push:register"),
  // Empty string is the CLEAR signal (sign-out) — do not use .min(1). See the
  // clear branch in the agent-core handler and Task 10's clearToken().
  pushToken: z.string(),
  provider: z.enum(["fcm", "apns"]),
  pushPubkey: PushPubkeyB64,
});

// Wire mirror of InstructionItem (handler/backlog.ts) — the live instruction
// stack, shared by configure (set) and status (per-session snapshot). Mirrored
// by hand rather than imported, for the same reason the Dart app mirrors it a
// third time: bridge-internal storage must not be able to move the wire
// contract silently. Keep the three in lockstep.
export const InstructionItemWire = z.object({
  id: z.string(),
  text: z.string(),
  dependsOn: z.array(z.string()).optional(),
  condition: z.string().optional(),
  status: z.enum(["queued", "active", "done", "blocked", "skipped", "failed"]),
  outcome: z.string().optional(),
  evidence: z.string().optional(),
  createdAt: z.number(),
});

// Every backlog operation resolves an id to at most one item, so a duplicate id
// leaves the shadowed copy unreachable by any transition and `allTerminal` false
// forever — a session that can never wrap up. backlog.ts checks uniqueness at
// the boundary rather than assuming it, and for anything the app sends this is
// that boundary.
const BacklogWire = z.array(InstructionItemWire).refine(
  (items) => new Set(items.map((i) => i.id)).size === items.length,
  { message: "duplicate item id" },
);

// Payload-only schema for the parseMessageFast hot path, which matches
// KNOWN_TYPES and checks NOTHING else; agent-core re-parses the whole payload
// with this before arming. It re-parses the payload wholesale rather than the
// fields it acts on one by one because BacklogWire's duplicate-id refine has to
// run over the list before it is stored — a shadowed item is unreachable by any
// transition, leaving a session that can never wrap up.
//
// Arming deliberately carries no required payload: one tap arms with whatever
// the session already holds. Any rule making `armed: true` demand a filled-in
// field puts a form back in front of that tap, which is the thing 1-tap arming
// exists to remove — so keep this schema free of whole-payload rules.
//
// HandlerConfigureMessage below is this shape inside a message envelope and must
// stay in lockstep, or the hot path admits what the union rejects. Field-level
// rules (BacklogWire) ride along through `.shape`; a whole-payload `.refine`
// would have to be written on both.

// The judge's lens: what it LOOKS FOR and ASKS ABOUT, added on top of the rules.
// A lens only adds questions — autonomy is derived from the rules, so no value
// here moves where the line between handling and escalating sits, changes what a
// transition must cite, or withholds a transition the evidence supports.
//
// A bounded enum rather than free text because the value selects BRIDGE-AUTHORED
// prompt text: nothing a sender types is interpolated by choosing one. The user's
// own words travel separately as `brief`, fenced as user text.
//
// `brief` is therefore the ONE free-text field of this schema that reaches the
// judge prompt, and it is defended in depth: the sanity cap below, a clip to the
// prompt budget in the engine, a collapse to one line so it cannot forge a header,
// a bullet naming it as the user's words, a standing sentence saying it authorises
// nothing, and — mechanically, not by wording — no path from it to
// authorizeInstruction (see the invariants on HandlerEngine.instruct).
export const HandlerLensSchema = z.enum(["pm", "qa", "critic", "release"]);
export type HandlerLens = z.infer<typeof HandlerLensSchema>;

export const HandlerConfigureWire = z.object({
  terminalId: z.string(),
  armed: z.boolean(),
  // The session objective in the user's own words.
  goal: z.string().optional(),
  // Absent = leave the stored backlog untouched, `[]` = clear it — the same
  // absent-vs-empty split as judgeTool below. Extraction appends to the
  // bridge's copy behind a non-blocking arm, so a sender that always shipped a
  // full backlog would overwrite items it never saw.
  backlog: BacklogWire.optional(),
  // Per-SESSION judge choice, persisted in the terminal's handler-session
  // record by arm(). Empty string = clear back to default (the session's own
  // tool / CLI default model); absent = leave the stored choice untouched.
  judgeTool: z.string().optional(),
  judgeModel: z.string().optional(),
  // The retired posture key, still shipped by an app that predates the lens.
  // Declared as a plain unbounded string, and read only to say once that it
  // selected nothing: agent-core re-parses this whole payload before arming, so
  // a value refused here — an unrecognised preset, or a length — would drop the
  // goal, the backlog, the judge picks and the arm itself. It aliases to the
  // unnamed default and never to a lens; a posture was an autonomy dial, and
  // autonomy is derived from the rules.
  personality: z.string().optional(),
  // The lens this session judges under. Absent = leave the stored lens
  // untouched, the same absent-keeps rule judgeTool follows; "" = back to the
  // unnamed default, which is the rules alone. An empty string rather than a
  // JSON null because a sender that omits null-valued keys from its payload
  // could not then say "clear" at all — only "keep".
  role: z.union([HandlerLensSchema, z.literal("")]).optional(),
  // The user's own words for what else to look for, added beneath the lens.
  // Absent = keep, "" = clear.
  //
  // The bound is HandlerInstructWire.text's refuse-only-the-absurd one, NOT the
  // prompt budget (MAX_BRIEF_CHARS, handler/decision.ts), which the engine applies
  // by CLIPPING. agent-core re-parses the whole configure payload with this schema
  // before arming, so a length refused here would drop the goal, the backlog, the
  // judge picks and the arm itself — a user who tapped Arm Handler over a long
  // sentence and walked away unwatched.
  brief: z.string().max(10_000).optional(),
});

const HandlerConfigureMessage = BaseMessage.extend({
  type: z.literal("handler:configure"),
  projectId: z.string(),
}).extend(HandlerConfigureWire.shape);

// Mid-flight instruction stacking: one sentence in, extracted items appended to
// the session's backlog. Payload-only schema for the same reason as
// HandlerConfigureWire — parseMessageFast admits it on the discriminator alone,
// so agent-core re-parses with this before the text reaches extraction, and the
// envelope below rides on `.shape` so the two cannot drift apart.
//
// Keep whole-payload rules off this schema too: stacking is one line typed on a
// phone, and a cross-field precondition would put a form in front of it.
export const HandlerInstructWire = z.object({
  terminalId: z.string(),
  // Untrusted remote text that ends up interpolated into the extraction prompt.
  // Extraction truncates for prompt budget; the cap is here so an absurd payload
  // is refused at the wire instead of being carried that far.
  text: z.string().max(10_000),
  // Present = this frame ANSWERS the standing ask with this id and is NOT a new
  // instruction. Optional because the schema is a plain non-strict z.object and
  // an older bridge strips it — which is only safe because the app never sends
  // it to a session whose snapshot did not advertise the capability the frame
  // relies on: `askAnswer` for an ask answered here alone, `escalationAnswer` for
  // the `delivered` note below. When it IS present and names nothing, instruct
  // fails CLOSED rather than falling through to today's path: an answer silently
  // promoted to an authorizing, extracting instruction is exactly the laundering
  // the ask shape exists to prevent.
  escalationId: z.string().max(64).optional(),
  // Present = the sender ALREADY typed this text into the session, and this frame
  // is a note so the judge learns its question was answered. Absent = the words
  // reached nobody but this bridge, which is what an ask's answer is.
  //
  // A property of the CHANNEL, never derived from the row it names: reconcileAsks
  // clears `nonBlocking` on any agent event while the app holds a cached row, so a
  // row-derived reading would tell the judge an ask's answer had reached the agent
  // when it reached nobody — and then forbid it from ever asking again.
  delivered: z.literal(true).optional(),
  // Which one-tap option on that row the user pressed. Only meaningful beside
  // `delivered`, and it names the option rather than carrying its words: those are
  // resolved from THIS bridge's own persisted row, exactly the way handler:answer
  // resolves an ask's option, so what is banked is the string the card actually
  // offered and never a string the frame supplied. `text` still carries what the
  // app put into the session — the frame stays self-describing — but on a tapped
  // note it is not what is banked.
  //
  // Absent = the sender typed the answer, which is what every frame written before
  // this field means. Present without `delivered`, instruct fails CLOSED rather
  // than guessing: the cross-field rule lives there and not in a `.refine()` here,
  // because whole-payload rules on this schema put a form in front of one line
  // typed on a phone (see the header above).
  choiceId: z.string().min(1).max(40).optional(),
});

const HandlerInstructMessage = BaseMessage.extend({
  type: z.literal("handler:instruct"),
  projectId: z.string(),
}).extend(HandlerInstructWire.shape);

// One tap on an ask's option. `escalationId` is REQUIRED and `choiceId` is
// REQUIRED: a dedicated verb whose id resolution fails CLOSED is what keeps a
// cross-language field-name typo, and a row retired between the render and the
// tap, from degrading into an authorizing handler:instruct. No `text` field, ever
// — the option's words are judge-authored, so they are resolved bridge-side from
// the persisted row and never travel back through the one channel that mints
// lifts (see quickChoicesFor in handler/engine.ts).
//
// Payload-only schema for the same reason as HandlerInstructWire: parseMessageFast
// admits it on the discriminator alone, so agent-core re-parses with this before
// the engine retires a row, and the envelope below rides on `.shape` so the two
// cannot drift apart.
export const HandlerAnswerWire = z.object({
  terminalId: z.string(),
  escalationId: z.string().max(64),
  choiceId: z.string().min(1).max(40),
});

const HandlerAnswerMessage = BaseMessage.extend({
  type: z.literal("handler:answer"),
  projectId: z.string(),
}).extend(HandlerAnswerWire.shape);

// One tap-to-answer option on a quick-choice escalation. `text` is sent as
// the USER's own reply through the ordinary reply transport, so it must be
// something a session can actually receive: whitespace alone is dropped by every
// consumer, which turns the chip into a button that silently does nothing.
// Control characters are rejected rather than flattened — a one-tap sends text the
// user never opened in an editable field, and an embedded CR would submit two lines
// into the PTY.
//
// `choiceId` names the intent so a notification action can round-trip back to the
// app; it is identity, never authority. Nothing may derive an authorization lift
// from it (see quickChoicesFor in handler/engine.ts).
//
// Hand-mirrors EscalationChoiceSchema (handler/session-store.ts); field-level
// rules ride into HandlerEscalationMessage through `.shape`, so they must live
// here rather than on the enclosing object.
const EscalationChoiceWire = z.object({
  choiceId: z.string().min(1).max(40),
  // Non-empty refined on top of `.min(1)`: a whitespace-only label is truthy but
  // draws a blank button on the card that stops the session.
  label: z.string().min(1).max(40).regex(/^[^\x00-\x1f\x7f]+$/).refine((t) => t.trim().length > 0),
  text: z.string().min(1).max(400).regex(/^[^\x00-\x1f\x7f]+$/).refine((t) => t.trim().length > 0),
  // What taking this chip commits to, one clause, shown under the button. New and
  // optional, so no bound any row already on disk was written under moves and an app
  // that predates it renders exactly what it renders today.
  cost: z.string().min(1).max(160).regex(/^[^\x00-\x1f\x7f]+$/)
    .refine((t) => t.trim().length > 0).optional(),
});

const uniqueChoiceIds = (cs: { choiceId: string }[]): boolean =>
  new Set(cs.map((c) => c.choiceId)).size === cs.length;

// Shared by the one-shot escalation push and the per-session status snapshot
// (which replays unanswered escalations so a reconnecting/restarted app can
// rebuild answerable rows, not just a pending count).
//
// Hand-mirrors OpenEscalationSchema (handler/session-store.ts), which persists the
// same payload, and the Dart mirror in app/lib/models/handler_state.dart.
const OpenEscalationWire = z.object({
  escalationId: z.string(),
  question: z.string(),
  reasoning: z.string(),
  draftReply: z.string(),
  urgency: z.enum(["normal", "high"]),
  floorRule: z.string().optional(),
  // How the app collects the answer: absent/"reply" = free-text reply sheet;
  // "resolve_in_session" = an option-based prompt (permission / structured
  // question) that must be resolved in the chat UI — injected text can't
  // answer it, and auto-approval is deliberately impossible (see engine).
  //
  // "guard_blocked" = a REPORT that a harness guard (reply shape, the HARD
  // floor, the runaway guard) refused an action Handler wanted to take. A typed
  // line does not answer it — the action was never taken — so only
  // `handler:dismiss` retires one, and the bridge never mints `choices` for it:
  // this row exists BECAUSE a guard refused this exact text, and a one-tap that
  // re-sent it would be the thinnest human in the loop there is.
  kind: z.enum(["reply", "resolve_in_session", "guard_blocked"]).optional(),
  // Quick choices, optional exactly the way `kind` is: absent means "free-text
  // reply", so an app that predates this renders its reply sheet unchanged. Two is
  // the floor because one chip is a card with no alternative, and the free-text
  // escape hatch is app-authored — never an entry here — so no bridge can ship a
  // card without one.
  //
  // The uniqueness refinement rides the ARRAY, not this object, so `.shape` below
  // still carries it into HandlerEscalationMessage: every surface resolves a tap
  // by first match, so a repeated choiceId sends text the user did not read.
  choices: z.array(EscalationChoiceWire).min(2).max(3)
    .refine(uniqueChoiceIds, "choiceId must be unique").optional(),
  at: z.number(),
  // The session did NOT stop for this one: it was raised on a pass that had
  // already replied to the agent, so the work went on and the user answers when
  // they can. Absent means what every row before this field meant — the session
  // stopped and is waiting.
  //
  // Spelled `nonBlocking` and not `blocking` on purpose: the naive truthiness
  // test (`if (e.nonBlocking)`) is then the SAFE reading on a row that predates
  // the field AND on one an older bridge stripped it from and re-persisted.
  // `blocking?: boolean` inverts that, and the failure is one character wide,
  // silent, and repeated at every reader in two languages.
  //
  // An app may only act on this when the session's own snapshot also advertised
  // `askAnswer`: a bridge can read this field off a record a newer bridge wrote
  // and re-emit it faithfully while having no verb that answers one, so the row
  // cannot be its own capability signal.
  nonBlocking: z.boolean().optional(),
  // Backlog ids the answer does not gate. The app re-derives the count from its
  // own copy of the backlog rather than trusting a number, so a stale id costs a
  // smaller count and never a wrong claim.
  unblocked: z.array(z.string().max(64)).max(10).optional(),
  // The tap-to-answer options on an ASK. A separate field from `choices` and
  // never a second producer into it: a `choices` entry carries `text` that the
  // ordinary reply transport types into the PTY, and an ask must send the agent
  // nothing. There is deliberately no `text` here — `label` IS the whole payload,
  // resolved bridge-side from the persisted row, so what the user reads on the
  // button is exactly what the judge is told they chose. See quickChoicesFor's
  // comment in handler/engine.ts for the authorization argument this shape rests
  // on.
  //
  // `label` is bounded at 80 rather than the 40 EscalationChoiceWire allows
  // because there a label only names a reply that travels separately, while here
  // it has to carry the whole answer as a sentence.
  //
  // The uniqueness refinement rides the ARRAY for the reason `choices`' does:
  // `.shape` below carries it into HandlerEscalationMessage, and a repeated
  // choiceId resolves a tap to an option the user did not read.
  askOptions: z.array(z.object({
    choiceId: z.string().min(1).max(40),
    label: z.string().min(1).max(80),
    cost: z.string().min(1).max(160),
    // z.literal(true), not z.boolean(): absent and `false` must mean one thing,
    // and a literal makes the second spelling unsayable.
    recommended: z.literal(true).optional(),
  })).min(2).max(4).refine(uniqueChoiceIds, "choiceId must be unique").optional(),
});

// One snapshot, as the app sees it. Shared by the one-shot advert and the
// per-project replay on `handler:status`, the same way OpenEscalationWire is
// shared — an app that reconnected (or restarted) after the advert must still be
// able to offer the undo.
//
// Project-scoped rather than session-scoped on purpose: a snapshot outlives the
// armed session that took it, because the wrap-up summary offering the undo is
// read long after the session disarmed.
export const HandlerSnapshotWire = z.object({
  snapshotId: z.string(),
  // The supervised slot the flagged reply was injected into.
  terminalId: z.string(),
  at: z.number(),
  action: z.enum(["reset_hard", "force_push", "rm_rf", "git_clean"]),
  // The command segment that triggered the snapshot.
  trigger: z.string(),
  // One line describing what was actually saved.
  summary: z.string(),
  // "available" = undoable now; "undone" = spent, a repeat tap is a no-op;
  // "failed" = the last attempt failed and may be retried (`detail` says why).
  // Only an entry the bridge actually captured is ever advertised: an action the
  // snapshot could not protect is an activity row, never an undo offer.
  state: z.enum(["available", "undone", "failed"]),
  detail: z.string().optional(),
});

const HandlerSnapshotMessage = BaseMessage.extend({
  type: z.literal("handler:snapshot"),
  projectId: z.string(),
}).extend(HandlerSnapshotWire.shape);

// One wrap-up report, as the app sees it — the summary the notification spends
// once, kept. Replayed on `handler:status` for a sharper version of the reason
// the snapshots are: the wrap-up is what DISARMS the session, so by the time the
// report is worth reading its session is gone from `sessions` and nothing else on
// this frame names it. The activity row that carries the same prose cannot stand
// in — `handler:activity` is not replayed, and its jsonl is never read back.
//
// What this shape freezes, deliberately: MAX_STORED_WRAPUPS (5) records, each up
// to 4 outcome groups x 8 sampled items x 120 chars, plus 3 blocked reasons and a
// goal at the same 120 — ~22K characters per status frame at the worst. That is
// why the item text is clipped at 120 rather than previewForUser's 300 default:
// handler:status is a REPLAY_TYPE, held by reference in the bus cache, emitted
// twice per handler event, and encrypted across the relay to a phone.
//
// The open-undo count is NOT here. It outlives the report — an undo taken
// afterwards spends the entry, a re-arm retires the offers outright — so the app
// derives it live from `snapshots` on this same frame. `blockedTotal` and
// `blockedReasons` are frozen for the opposite reason: the session that could
// re-derive them no longer exists.
export const HandlerWrapUpWire = z.object({
  wrapUpId: z.string(),
  // The supervised slot the session ran in.
  terminalId: z.string(),
  at: z.number(),
  goal: z.string(),
  outcomes: z.array(z.object({
    status: z.enum(["done", "failed", "blocked", "skipped"]),
    // The TRUE count `items` is sampled from, which is what makes "+N more"
    // recoverable without a second number that could disagree with it.
    total: z.number().int().nonnegative(),
    items: z.array(z.string()),
  })),
  blockedTotal: z.number().int().nonnegative(),
  blockedReasons: z.array(z.string()),
});

// One-tap undo of a snapshot the bridge advertised. Payload-only schema for the
// same reason as HandlerConfigureWire: parseMessageFast admits it on the
// discriminator alone, so agent-core re-parses with this before anything runs.
//
// No terminalId: the id names the entry, and the entry carries its own session
// and project path. Undo is deliberately NOT gated on authorization —
// anyone who can drive this project can already drive its terminal, and a second
// authorization concept would only make the safety net harder to reach than the
// action it reverses.
export const HandlerUndoWire = z.object({
  snapshotId: z.string(),
});

const HandlerUndoMessage = BaseMessage.extend({
  type: z.literal("handler:undo"),
  projectId: z.string(),
}).extend(HandlerUndoWire.shape);

// The user acknowledging a `guard_blocked` escalation — the only thing that
// retires one, since nothing the agent or the user does next answers a report
// about an action Handler never took. Payload-only for the same reason as
// HandlerUndoWire: parseMessageFast admits on the discriminator alone, so
// agent-core re-parses with this before the engine sees it.
//
// It carries a terminalId where handler:undo carries none, because an escalation
// lives on one supervised session while a snapshot is project-scoped and names
// its own session through the store.
export const HandlerDismissWire = z.object({
  terminalId: z.string(),
  escalationId: z.string(),
});

const HandlerDismissMessage = BaseMessage.extend({
  type: z.literal("handler:dismiss"),
  projectId: z.string(),
}).extend(HandlerDismissWire.shape);

export const HandlerAvailabilitySchema = z.object({
  state: z.enum(["unknown", "preparing", "available", "unavailable"]),
  reason: z.string().optional(),
});
export type HandlerAvailability = z.infer<typeof HandlerAvailabilitySchema>;

const HandlerSessionSnapshot = z.object({
  terminalId: z.string(),
  state: z.enum(["watching", "handling", "needs_you", "parked"]),
  pendingEscalations: z.number().int().nonnegative(),
  armedAt: z.number(),
  // Mirrors instructions[0], so it moves if the store ever trims past
  // MAX_INSTRUCTIONS (session-store.ts) — a live drift, documented rather than
  // fixed here.
  goal: z.string(),
  backlog: BacklogWire,
  escalations: z.array(OpenEscalationWire),
  // The BACKOFF POLICY the engine picked — how long to wait and on what curve —
  // never a reason; `parkCause` below carries that. With `parkedUntil` (epoch ms)
  // it drives the countdown chip. Present only while state is "parked".
  parkKind: z.enum(["limit", "outage"]).optional(),
  // Who the pause is ATTRIBUTABLE to, which `parkKind` cannot say: that field is
  // the backoff policy, and the two diverge on the case that named this one — a
  // judge call of ours timing out parks as `outage` and read on the bar as the
  // AGENT's provider being down. Optional because a park predating it, on disk or
  // from an older bridge, is honestly unattributed; an app with no cause falls
  // back to the policy's own copy.
  parkCause: z.enum(["agent_limit", "agent_failure", "judge_failure"]).optional(),
  parkedUntil: z.number().optional(),
  // Per-session judge choice (absent = session default tool / CLI default model).
  judgeTool: z.string().optional(),
  judgeModel: z.string().optional(),
  // How much of the Handler this session can actually get, so the app can tell
  // "cannot report at all" from "armed and quiet" (HandlerObservability in
  // handler/engine.ts). Optional and appended LAST: an older app still parses
  // the snapshot, and every key it reads keeps its position.
  observability: z.enum(["full", "escalate_only", "unsupported"]).optional(),
  availability: HandlerAvailabilitySchema.optional(),
  // Presence IS the capability signal, the way `observability`'s is and unlike
  // `wrapUps`, where absent and empty mean the same thing: this bridge accepts
  // handler:answer and an escalationId-bearing handler:instruct for this
  // session's asks. ABSENT means an app must treat every `nonBlocking` row as an
  // ordinary blocking escalation, because it has no way to answer one that would
  // not land in the PTY. This exists because the ask ROW cannot advertise
  // itself: a bridge that can READ the record field but not answer it (a Store
  // rollback onto a record a newer bridge wrote) re-emits `nonBlocking`
  // faithfully.
  askAnswer: z.literal(true).optional(),
  // An answer is parked and has not been relayed to the agent yet. State, not
  // capability — a bridge with nothing parked simply omits it.
  askAnswerPending: z.boolean().optional(),
  // The lens this session judges under, and the user's brief beneath it. Both
  // optional and appended LAST for the reason `observability` is: an older app
  // still parses the snapshot and every key it already reads keeps its position.
  //
  // STATE, not a capability signal, unlike `askAnswer`: an absent `role` is the
  // unnamed default rather than a bridge that cannot do lenses, and `brief` is
  // present only when non-empty. What this bridge ACCEPTS rides the status frame's
  // top-level `lenses` instead.
  role: HandlerLensSchema.optional(),
  brief: z.string().optional(),
  // A window onto the full instruction list the store keeps (session-store.ts),
  // not the list itself: `goal` above is the only other string this snapshot
  // spends on it, and the app has nowhere durable to put more than a few — this
  // is a REPLAY_TYPE and handler:activity, where a stacked sentence would
  // otherwise show up, is not. Entry #1 stays pinned rather than dropped even
  // when it falls out of the newest four: it is what names the session on the
  // card headline, the wrap-up card, and the wrap-up push (see firstInstruction,
  // engine.ts), and a window that could drop it would open a fresh divergence
  // from those surfaces one tap wide. `total - items.length` is exactly what got
  // elided BETWEEN position 0 and position 1 — always, since nothing between
  // position 1 and the end is ever missing — which is what makes a
  // non-contiguous window legible without a second count that could disagree
  // with it. `total` is the RETAINED count — the entries `items` was windowed
  // out of, so the two can never disagree — not a lifetime one: pushInstruction
  // splices the oldest away past MAX_INSTRUCTIONS and nothing counts what it
  // has already dropped. Optional
  // and appended LAST for the reason `observability` is: an older app still
  // parses the snapshot and every key it already reads keeps its position. A
  // bridge that HAS this field always sends it, including `{ total: 0, items:
  // [] }` for an armed session nobody has instructed — absence means "this
  // bridge predates the list", never "no instructions".
  instructions: z.object({
    total: z.number().int().nonnegative(),
    items: z.array(z.string().max(120)).max(5),
  }).optional(),
  // Presence IS the capability signal, the way `askAnswer`'s is: this bridge reads
  // a `delivered` note on handler:instruct that names a BLOCKING row and banks the
  // sentence for the judge instead of authorizing and extracting it as a new
  // instruction. An app that sends the note to a bridge without this gets the old
  // behaviour on the wrong verb — a session-long grant nobody read, plus a backlog
  // item no terminal status can resolve — which is why the app must never send it
  // uninvited. Absent means: send the reply and nothing else.
  escalationAnswer: z.literal(true).optional(),
});

// Why this machine will not run the Handler, in the words the app has to answer
// with. Mirrors `EntitlementRefusal` (./entitlement.ts) — the REFUSED half of
// the verdict only, which is what makes presence on a status frame mean
// "refused" with no second boolean to disagree with.
//
// A refusal is otherwise invisible: it leaves the slot in the ordinary
// not-armed state, which is exactly what a tap that never registered looks
// like, and the engine's warn line is on a machine the reader may not be
// sitting at. This is the one thing the bridge knows and the app cannot derive.
//
// The two reasons are two different sentences, and collapsing them would send
// half the users to the wrong fix: `not_entitled` is the paywall and the app
// offers the upgrade, `unreadable` is a machine whose credentials stopped
// answering and the app says to sign in again.
export const HandlerEntitlementWire = z.object({
  reason: z.enum(["not_entitled", "unreadable"]),
  // The tier the claim carried, when it carried a recognised one — so the
  // upgrade copy can name the plan the machine is actually on. Absent for
  // `unreadable`, which is the case of having no readable tier at all.
  tier: z.enum(KNOWN_TIERS).optional(),
});

const HandlerStatusMessage = BaseMessage.extend({
  type: z.literal("handler:status"),
  projectId: z.string(),
  // What an absent per-session judgeTool resolves to for PTY slots (the
  // project agent tool) — chat slots resolve from their own SessionEntry.tool
  // app-side. Judge overrides themselves are per-session (see snapshot).
  defaultTool: z.string().optional(),
  // The lens ids this bridge accepts. PRESENCE is the capability advert, the way a
  // snapshot's `observability` is; the contents say which ids, so a newer app can
  // offer the intersection and never send one this bridge would refuse.
  //
  // Top-level rather than per session because `sessions` holds ARMED sessions only,
  // and the surface that needs this most is the arm sheet — a slot with no snapshot
  // to read.
  lenses: z.array(HandlerLensSchema).optional(),
  sessions: z.array(HandlerSessionSnapshot),
  // Every snapshot this project still knows about, replayed for the same reason
  // escalations are: an app that restarted between the advert and the tap would
  // otherwise have no way to reach the undo. Not nested under a session — the
  // sessions array holds only ARMED sessions, and a wrapped-up one is exactly
  // when the offer matters most.
  snapshots: z.array(HandlerSnapshotWire),
  // Every wrap-up report this project still holds, appended LAST and optional
  // the way a session snapshot appends `observability`: an older app still
  // parses the frame and every key it already reads keeps its position. Absent
  // and [] mean the same thing — unlike `observability`, presence here is not a
  // capability signal, so a bridge with nothing to report simply omits it.
  wrapUps: z.array(HandlerWrapUpWire).optional(),
  // Present ONLY while this machine refuses Handler; absent is the ordinary
  // entitled machine AND every bridge predating the field, which want the same
  // rendering. Appended LAST for the reason `wrapUps` is — an older app still
  // parses the frame and every key it already reads keeps its position.
  //
  // Project-scoped rather than per session, because entitlement is neither: it
  // is a fact about the account behind the machine, and a session-shaped copy
  // would have nowhere to live on the surface that needs it most — the shield
  // over a session that is not armed and, while this is set, cannot become so.
  entitlement: HandlerEntitlementWire.optional(),
});

const HandlerEscalationMessage = BaseMessage.extend({
  type: z.literal("handler:escalation"),
  projectId: z.string(),
  terminalId: z.string(),
}).extend(OpenEscalationWire.shape);

const HandlerActivityMessage = BaseMessage.extend({
  type: z.literal("handler:activity"),
  projectId: z.string(),
  recordId: z.string(),
  at: z.number(),
  terminalId: z.string(),
  // Kept in lockstep with ActivityRecord.decision (handler/config.ts) and the
  // app's handler_state.dart. One kind per item outcome rather than a single
  // "item_resolved": a skip is as consequential as a completion, so the feed
  // distinguishes them without parsing the reason text.
  decision: z.enum([
    "continue", "handle", "escalate",
    "armed", "goal_edited",
    "item_done", "item_blocked", "item_skipped", "item_failed",
    "instruction_dropped", "instruction_authorized", "instruction_amended",
    "floor_warning", "evidence_rejected",
    "wrapped_up", "parked", "resumed",
    "asked", "ask_rejected", "answered",
  ]),
  reason: z.string(),
  detail: z.string().optional(),
});

const AgentHelloMessage = BaseMessage.extend({
  type: z.literal("agent:hello"),
  tool: z.string().optional(),
  command: z.string().optional(),
  version: z.string(),
  flags: z.array(z.string()).optional(),
});

const PortDetectedMessage = BaseMessage.extend({
  type: z.literal("port:detected"),
  port: z.number().int().positive(),
  url: z.string(),
  scheme: z.enum(["http", "https"]),
  source: z.enum(["process", "output", "declared"]),
  sourceSessionId: z.string().optional(),
  attributes: z.object({
    name: z.string().optional(),
    onDetect: z.enum(["notify", "openPreview", "silent", "ignore"]).default("notify"),
  }),
  ...CheckoutScoped,
});

// ── Local-mode promotion: App↔Agent control messages ─────────────────
//
// The App (already account-authenticated) triggers promotion via
// `agent:enableRelay`, passing the signed-in device's credentials. The agent
// stands up the enrolled native remote host with them and responds with the lifecycle messages
// below. Disabling tears the relay client down without touching the local
// loopback session.
// Mirror of the validators in auth/credentials.ts (kept inline to avoid an
// import cycle — credentials.ts must stay free of protocol.ts deps). base64-ish
// keys and a lenient UUID, so malformed creds fail at parse, not late in
// Ed25519 ops.
const Base64ish = z.string().min(1).regex(/^[A-Za-z0-9+/=_-]+$/, "base64-ish");
const DeviceUuid = z
  .string()
  .regex(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, "UUID format");
const AgentEnableRelayAuth = z.object({
  userId: z.string().min(1).optional(),
  endpointSecret: z.string().regex(/^[A-Za-z0-9+/]{43}=$/).optional(),
  deviceUuid: DeviceUuid,
  ed25519Pub: Base64ish,
  ed25519Priv: Base64ish,
  // Production path — agent mints + refreshes via OAuth client_credentials.
  clientId: z.string().min(1).optional(),
  clientSecret: z.string().min(1).optional(),
  // Offline/test path — caller supplies a pre-minted token (no refresh).
  licenseToken: z.string().min(1).optional(),
});

// Exported so the local-mode promotion controller can re-validate an
// `agent:enableRelay` that reached it over the loopback listener — which uses
// parseMessageFast (skips Zod). See relay-promotion.ts `start()`.
export const AgentEnableRelayMessage = BaseMessage.extend({
  type: z.literal("agent:enableRelay"),
  // App-supplied relay base. local-listener uses parseMessageFast (skips Zod),
  // so `.url()` only bites for relay-sourced messages until the controller
  // re-validates the whole message via `AgentEnableRelayMessage.safeParse`.
  relayUrl: z.string().url().optional(),
  // Web base used to mint OAuth tokens; required when `auth.clientId` is used.
  licenseApiUrl: z.string().url().optional(),
  // Account-device credentials, supplied by the app at enable-time. Optional so
  // older app builds and the bare/test forms still parse.
  auth: AgentEnableRelayAuth.optional(),
});
const AgentDisableRelayMessage = BaseMessage.extend({
  type: z.literal("agent:disableRelay"),
});
const AgentActivationPendingMessage = BaseMessage.extend({
  type: z.literal("agent:activationPending"),
  verificationUri: z.string(),
  userCode: z.string(),
  expiresAt: z.string(),
});
// The one success signal of the enable-relay path: the machine socket is up and
// the local core is attached as a stream. Its counterpart `agent:relayError`
// covers every failure, so without this the path is silent on success.
const AgentRelayReadyMessage = BaseMessage.extend({
  type: z.literal("agent:relayReady"),
  agentDeviceId: z.string(),
});
const AgentRelayErrorMessage = BaseMessage.extend({
  type: z.literal("agent:relayError"),
  code: z.string(),
  message: z.string(),
});

// Inbound app→agent control-plane verb: the paired phone asks the host to start
// one of its ALLOWED projects. SECURITY: carries `projectId` ONLY — never a
// path/folder. The host resolves the path from its own seenProjects catalog, so
// a phone cannot point a projectId at an arbitrary folder and run that folder's
// `terminals:` startup commands. Authorization is the per-phone allowlist,
// checked BEFORE the project is opened. (Zod strips unknown keys, so a smuggled
// path never reaches the host.)
export const ProjectStartMessage = BaseMessage.extend({
  type: z.literal("project:start"),
  projectId: z.string().min(1),
});

const ConfigReadMessage = BaseMessage.extend({
  type: z.literal("config:read"),
  ...CheckoutScoped,
});

const ConfigReadResultMessage = BaseMessage.extend({
  type: z.literal("config:read-result"),
  ok: z.boolean(),
  config: AbConfigSchema.optional(),
  raw: z.string().optional(),
  error: z.string().optional(),
  ...CheckoutScoped,
});

const ConfigWriteMessage = BaseMessage.extend({
  type: z.literal("config:write"),
  config: AbConfigSchema,
  ...CheckoutScoped,
});

const ConfigWriteResultMessage = BaseMessage.extend({
  type: z.literal("config:write-result"),
  ok: z.boolean(),
  errors: z.array(z.string()).optional(),
  ...CheckoutScoped,
});

const ConfigChangedMessage = BaseMessage.extend({
  type: z.literal("config:changed"),
  config: AbConfigSchema.optional(),
  agentRestartRequired: z.boolean(),
  invalid: z.boolean().optional(),
  error: z.string().optional(),
  ...CheckoutScoped,
});

const ConfigDetectToolsMessage = BaseMessage.extend({
  type: z.literal("config:detect-tools"),
  ...CheckoutScoped,
});

const ConfigDetectToolsResultMessage = BaseMessage.extend({
  type: z.literal("config:detect-tools-result"),
  tools: z.array(z.object({
    tool: z.string(),
    path: z.string().optional(),
  })),
  ...CheckoutScoped,
});

// Identity of one session on one machine, and the address every bus frame
// carries. `machineId` is the account device uuid — the value the app already
// addresses a machine by. Opaque to both bridges: neither derives it, the app
// supplies both halves, because neither bridge can dial the other.
export const SessionMemberKeySchema = z.object({
  machineId: z.string().min(1).max(200),
  projectId: z.string().min(1).max(200),
  sessionId: z.string().min(1).max(200),
});

// The Capability Card as it travels on an address (spec 5.3): the two MVP
// fields, both observed by that machine's own bridge before any agent ran
// there. Mirrors `OsCard`/`RepoCard` in capability-card.ts, which is where the
// values are actually read — a second shape would be two things to keep true.
//
// Every field is optional and tolerates an explicit null, top to bottom,
// because the reader that fills it already produces nulls (`readRepoCard`) and
// because a machine that could not answer must still be able to appear in the
// directory: withholding a row over a blank branch would cost the human the
// machine rather than the field. Bounded like every other label here — the
// values are rendered into an agent's prompt.
export const SessionMemberCardSchema = z.object({
  os: z.object({
    name: z.string().max(60).nullish(),
    version: z.string().max(200).nullish(),
    arch: z.string().max(30).nullish(),
  }).nullish(),
  repo: z.object({
    label: z.string().max(120).nullish(),
    // The normalized `host[:port]/path` match key, never the raw remote URL: a
    // raw one can carry a credential in its authority, and this value is
    // rendered into a delivery and into a tool answer.
    remote: z.string().max(300).nullish(),
    branch: z.string().max(250).nullish(),
  }).nullish(),
});

// Identity plus the labels a row renders from, so the other end of an exchange
// resolves with no lookup on a machine that cannot reach the one it names.
// Bounded because they ride every frame that names that end AND are
// interpolated into a Handler instruction, where the delivery template
// sanitizes them further.
//
// The card is the exception to that second half: hostnames and a repo path are
// exactly what the Handler's authorizer reads as a grant, so no template may put
// it in a WRAPPER. It travels as fenced data or as a tool answer, and never
// through `HandlerEngine.instruct` (see session-bus/delivery.ts).
export const SessionMemberRefSchema = SessionMemberKeySchema.extend({
  machineLabel: z.string().max(120).optional(),
  projectLabel: z.string().max(120).optional(),
  sessionName: z.string().max(120).optional(),
  card: SessionMemberCardSchema.optional(),
});

const SessionEntrySchema = z.object({
  id: z.string(),
  name: z.string(),
  createdAt: z.number(),
  lastUsedAt: z.number(),
  archived: z.boolean(),
  running: z.boolean(),
  // True only while this session's own delete is between its preflight and the
  // row disappearing — seconds of real work (worktree teardown, `git worktree
  // remove`) the app otherwise has no signal for. In-memory on the bridge and
  // deliberately absent from sessions.json: a persisted flag would survive a
  // crash mid-delete as a row that is permanently pending and undeletable.
  // `default(false)` is the safe read of an older bridge's omission — a row
  // that never shows pending beats one stuck pending forever.
  deleting: z.boolean().default(false),
  tool: z.string().optional(),
  command: z.string().optional(),
  // A current bridge derives this from the registry adapter. False by default
  // keeps the menu hidden against an older bridge that cannot parse session:fork.
  forkSupported: z.boolean().default(false),
  // The session this one was forked from. Provenance rather than a link: the
  // source may be renamed, archived or deleted, and no surface resolves it
  // back — it is what survives the derived name once either side is renamed.
  forkedFromSessionId: z.string().optional(),
  // Raw, shell-interpreted CLI-args string passed verbatim (not an argv array).
  args: z.string().optional(),
  mode: z.enum(["terminal", "chat"]).default("terminal"),
  approvalPolicy: z.enum(["default", "bypass"]).default("default"),
  // False when this session's agent-native conversation can no longer be
  // resumed, so a mode switch would silently start a fresh one. Deliberately
  // NOT "can this session switch mode" — that also depends on the tool having a
  // chat driver, which the app already knows from `chatCapable` on agent:tools
  // and which it must keep separable: missing history HIDES the control, an
  // agent without a driver DISABLES the Chat cell. Collapsing the two here
  // would make both look like one silent absence.
  // See docs/plans/2026-07-31-session-mode-toggle.md.
  agentSessionResumable: z.boolean().default(true),
  // This session's own work status, folded by the same reducer the per-project
  // advert uses (work-status.ts) from the notifications this slot fired plus its
  // own running flag. `attention` and `working` stay distinct on purpose:
  // killing an agent blocked on a permission request abandons the pending tool
  // call and a resume does not re-ask it, whereas a churning agent only loses
  // the current turn. Advisory only — `awaiting_input` cannot tell a genuine
  // mid-turn block from a post-turn idle nudge, so nothing may GATE on this.
  // Absent from the disk-only peek, which has no runtime to reduce.
  workStatus: WorkStatusSchema.optional(),
  agentSessionId: z.string().optional(),
  agentTranscriptPath: z.string().optional(),
  checkoutId: z.string().default("main"),
  checkoutKind: z.enum(["main", "managed-worktree", "external-worktree"]).default("main"),
  checkoutBranch: z.string().nullable().optional(),
  checkoutState: z.enum(["ready", "missing", "failed"]).default("ready"),
  sharedWorkspace: z.boolean().default(false),
  workspaceMemberCount: z.number().int().positive().default(1),
  // Provisioning of this session's own checkout (`worktree.setup`). Orthogonal
  // to `checkoutState`, deliberately: that answers "is this workspace usable",
  // this one "has provisioning finished" — a checkout is `ready` while setup is
  // still running, which is exactly what makes Skip meaningful. Folding it into
  // the checkoutState vocabulary would make the isolation badge claim the
  // workspace is broken in the common case.
  // Optional with no default: an older app ignores the key and sees exactly
  // today's behaviour. `running` never reaches disk — see checkout-store.ts.
  setup: z.object({
    state: z.enum(["running", "done", "failed", "skipped", "interrupted"]),
    // 0-based, the current step while running and the last one afterwards.
    stepIndex: z.number().int().nonnegative(),
    stepCount: z.number().int().nonnegative(),
    stepName: z.string().optional(),
    // Every step's name, in plan order — the ledger's only source. Optional so
    // an older bridge still parses, and absent for a state recovered from disk,
    // which knows how many steps ran but not what they were called.
    stepNames: z.array(z.string()).optional(),
    // The setup transcript's terminal, replayable via terminal:snapshot:request.
    terminalId: z.string().optional(),
    exitCode: z.number().int().optional(),
    // One-line failure summary.
    message: z.string().optional(),
    // A session:start is queued behind this run. The app reads it to tell
    // "queued" from "started" — the start reply is ok either way.
    pendingStart: z.boolean().default(false),
    startedAt: z.number(),
    finishedAt: z.number().optional(),
  }).optional(),
});

const SessionListMessage = BaseMessage.extend({
  type: z.literal("session:list"),
  requestId: z.string(),
  includeArchived: z.boolean().optional(),
});

const SessionListResultMessage = BaseMessage.extend({
  type: z.literal("session:list:result"),
  requestId: z.string(),
  sessions: z.array(SessionEntrySchema),
});

const SessionCreateMessage = BaseMessage.extend({
  type: z.literal("session:create"),
  requestId: z.string(),
  name: z.string().optional(),
  tool: z.string().optional(),
  command: z.string().optional(),
  // Raw, shell-interpreted CLI-args string passed verbatim (not an argv array).
  args: z.string().optional(),
  mode: z.enum(["terminal", "chat"]).optional(),
  approvalPolicy: z.enum(["default", "bypass"]).optional(),
  // Optional on the wire for an old client; handlers normalize omission to
  // shared before invoking SessionManager.
  isolation: z.enum(["shared", "worktree"]).optional(),
  baseBranch: z.string().min(1).optional(),
}).superRefine((value, ctx) => {
  if (value.baseBranch && value.isolation !== "worktree") {
    ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["baseBranch"], message: "baseBranch requires worktree isolation" });
  }
});

// A fork names only an existing bridge-owned session and its workspace policy.
// In particular it never accepts an agent-native id, transcript, path, command
// or argv from a client: all of those are local authority held by the bridge.
const SessionForkMessage = BaseMessage.extend({
  type: z.literal("session:fork"),
  requestId: z.string(),
  sourceSessionId: z.string(),
  workspace: z.enum(["copy", "current"]),
});

const SessionStartMessage = BaseMessage.extend({
  type: z.literal("session:start"),
  requestId: z.string(),
  sessionId: z.string(),
  // One-shot first prompt for THIS launch only (never persisted): chat mode
  // delivers it as the first user turn, terminal mode as per-agent spawn argv
  // (see initial-prompt.ts). Absent on restart, so a stop→start can't re-fire.
  initialPrompt: z.string().optional(),
});

const SessionStopMessage = BaseMessage.extend({
  type: z.literal("session:stop"),
  requestId: z.string(),
  sessionId: z.string(),
});

const SessionRenameMessage = BaseMessage.extend({
  type: z.literal("session:rename"),
  requestId: z.string(),
  sessionId: z.string(),
  name: z.string(),
});

const SessionArchiveMessage = BaseMessage.extend({
  type: z.literal("session:archive"),
  requestId: z.string(),
  sessionId: z.string(),
});

const SessionUnarchiveMessage = BaseMessage.extend({
  type: z.literal("session:unarchive"),
  requestId: z.string(),
  sessionId: z.string(),
});

const SessionDeleteMessage = BaseMessage.extend({
  type: z.literal("session:delete"),
  requestId: z.string(),
  sessionId: z.string(),
  force: z.boolean().optional(),
  removeCheckout: z.boolean().optional(),
  deleteBranch: z.boolean().optional(),
});

const SessionSetModeMessage = BaseMessage.extend({
  type: z.literal("session:set-mode"),
  requestId: z.string(),
  sessionId: z.string(),
  mode: z.enum(["terminal", "chat"]),
});

// Skip releases the queued start immediately and lets setup keep running;
// cancel kills the run; rerun starts a fresh one from a terminal state.
// Deliberately NOT in CHECKOUT_VARIABLE_MESSAGE_TYPES: every `session:*` verb
// routes by sessionId on the project stream and the bridge resolves the
// checkout from the session entry, so a checkoutId on the wire here would be a
// second, conflicting answer to a question already settled bridge-side.
const SessionSetupMessage = BaseMessage.extend({
  type: z.literal("session:setup"),
  requestId: z.string(),
  sessionId: z.string(),
  action: z.enum(["skip", "cancel", "rerun"]),
});

// App→agent: this session is what the user is looking at, sent on every focus
// change. Fire-and-forget (no requestId, no reply) — it feeds the work-status
// read state (`sessionFocus` in work-status.ts), which is advisory, so a
// dropped one costs a blue dot that clears on the next visit.
const SessionFocusMessage = BaseMessage.extend({
  type: z.literal("session:focus"),
  sessionId: z.string(),
});

const SessionResultMessage = BaseMessage.extend({
  type: z.literal("session:result"),
  requestId: z.string(),
  ok: z.boolean(),
  error: z.string().optional(),
  ...CheckoutScoped,
  errorCode: z.string().optional(),
  session: SessionEntrySchema.optional(),
});

const SessionUpdatedMessage = BaseMessage.extend({
  type: z.literal("session:updated"),
  sessions: z.array(SessionEntrySchema),
});

const ClientFocusStateMessage = BaseMessage.extend({
  type: z.literal("client:focus-state"),
  paused: z.boolean(),
});

const TerminalSnapshotRequestMessage = BaseMessage.extend({
  type: z.literal("terminal:snapshot:request"),
  terminalId: z.string(),
  // COLD attach: the client's engine has rendered nothing for this terminal, so
  // the reply should carry the emulator's scrollback as well as the screen and
  // erase before painting. Only the client can answer this — it is the only side
  // that knows what its engine holds — and answering it wrongly costs the user's
  // own (far deeper) history. Absent/false means re-attach: screen only.
  history: z.boolean().optional(),
  ...CheckoutScoped,
});

const TerminalSnapshotMessage = BaseMessage.extend({
  type: z.literal("terminal:snapshot"),
  terminalId: z.string(),
  scrollback: z.string(),
  seq: z.number().int().nonnegative(),
  // Absent/false: `scrollback` is a mode prelude plus a raw byte tail, and the
  // client must place its own erase (an older bridge). True: `scrollback` is a
  // COMPLETE attach sequence — preamble, serialized screen, supplemental modes —
  // to be applied verbatim with nothing prepended or appended.
  composed: z.boolean().optional(),
  // True: the body carries scrollback ABOVE the screen and its preamble
  // leads with `3J`. A reply is published on the project bus, so every
  // client attached to this terminal receives the one that ONE of them
  // asked for -- and that erase would take a warm client's own history
  // with it. The requester cannot be addressed (there is no per-client
  // routing on this path), so the frame is labelled instead and a client
  // whose engine is already painted drops it.
  history: z.boolean().optional(),
  ...CheckoutScoped,
});

// The frame display protocol (advertised as `terminalFramesV1`). These eight
// envelopes are declared HERE, as literal source text, rather than imported from
// terminal-frames/protocol.ts: checkout-protocol-contract.test.ts scrapes this
// file for `BaseMessage.extend({ ... ...CheckoutScoped ... })` blocks and
// asserts that set equals CHECKOUT_VARIABLE_MESSAGE_TYPES, and an import is
// invisible to a textual scraper. The payload sub-schemas and every byte/row
// budget stay in terminal-frames/protocol.ts, which owns them.
//
// All eight name a terminal INSIDE a checkout: PTY slots are namespaced
// `<checkoutId>:<terminalId>`, so two isolated checkouts legitimately hold
// same-named terminals. Hence `...CheckoutScoped` on every one, and hence all
// eight in CHECKOUT_VARIABLE_MESSAGE_TYPES.
//
// `sequence`, `revision`, `epoch`, `rowId` and `beforeRowId` are deliberately
// NOT bounded by the viewer/history budgets. Those budgets bound what may be in
// flight (TERMINAL_VIEWER_MAX_FRAMES) or how large one payload may be
// (TERMINAL_VIEWER_MAX_BYTES and TERMINAL_HISTORY_PAGE_ROWS, both enforced by
// the imported sub-schemas); the counters are monotonic for the life of an
// attachment or a run, so clamping them to a budget would reject a long-lived
// terminal's legitimate frames.

const TerminalSubscribeMessage = BaseMessage.extend({
  type: z.literal("terminal:subscribe"),
  terminalId: z.string(),
  // The highest frame protocol version the app can render. Deliberately a plain
  // int and not a literal: a version this bridge cannot serve is answered with
  // `terminal:display:status` UPGRADE_REQUIRED, which is only reachable if the
  // frame parses at all.
  version: z.number().int().nonnegative(),
  requestId: z.string().uuid(),
  ...CheckoutScoped,
});

const TerminalSubscribedMessage = BaseMessage.extend({
  type: z.literal("terminal:subscribed"),
  terminalId: z.string(),
  runId: z.string().uuid(),
  attachmentId: z.string().uuid(),
  version: z.literal(TERMINAL_PROTOCOL_VERSION),
  requestId: z.string().uuid(),
  ...CheckoutScoped,
});

const TerminalFrameMessage = BaseMessage.extend({
  type: z.literal("terminal:frame"),
  terminalId: z.string(),
  runId: z.string().uuid(),
  attachmentId: z.string().uuid(),
  sequence: z.number().int().nonnegative(),
  ...TerminalScreenFrameSchema.shape,
  ...CheckoutScoped,
});

const TerminalAckMessage = BaseMessage.extend({
  type: z.literal("terminal:ack"),
  terminalId: z.string(),
  runId: z.string().uuid(),
  attachmentId: z.string().uuid(),
  sequence: z.number().int().nonnegative(),
  ...CheckoutScoped,
});

const TerminalUnsubscribeMessage = BaseMessage.extend({
  type: z.literal("terminal:unsubscribe"),
  terminalId: z.string(),
  runId: z.string().uuid(),
  attachmentId: z.string().uuid(),
  ...CheckoutScoped,
});

const TerminalHistoryRequestMessage = BaseMessage.extend({
  type: z.literal("terminal:history:request"),
  terminalId: z.string(),
  runId: z.string().uuid(),
  attachmentId: z.string().uuid(),
  requestId: z.string().uuid(),
  epoch: z.number().int().nonnegative(),
  beforeRowId: z.number().int().nonnegative(),
  ...CheckoutScoped,
});

const TerminalHistoryPageMessage = BaseMessage.extend({
  type: z.literal("terminal:history:page"),
  terminalId: z.string(),
  runId: z.string().uuid(),
  attachmentId: z.string().uuid(),
  requestId: z.string().uuid(),
  history: TerminalHistoryBoundarySchema,
  expired: z.boolean(),
  beforeRowId: z.number().int().nonnegative(),
  rows: z.array(TerminalHistoryRowSchema).max(TERMINAL_HISTORY_PAGE_ROWS),
  ...CheckoutScoped,
});

const TerminalDisplayStatusMessage = BaseMessage.extend({
  type: z.literal("terminal:display:status"),
  terminalId: z.string(),
  // Optional, and it must stay optional: UPGRADE_REQUIRED answers a subscribe
  // that never produced an attachment, so there is no run or attachment to
  // name. Requiring either would leave the one failure an old app can trigger
  // unreportable.
  runId: z.string().uuid().optional(),
  attachmentId: z.string().uuid().optional(),
  requestId: z.string().uuid().optional(),
  code: z.enum(["UPGRADE_REQUIRED", "UNKNOWN_TERMINAL", "DISPLAY_FAILED", "ACK_TIMEOUT", "HISTORY_DISABLED", "ENDED"]),
  message: z.string().max(1024),
  finalSequence: z.number().int().nonnegative().optional(),
  exitCode: z.number().int().nullable().optional(),
  ...CheckoutScoped,
});

const FileTreeSnapshotRequestMessage = BaseMessage.extend({
  type: z.literal("file:tree:snapshot:request"),
  /** The revision the caller's tree is already at. Matched against the
   *  watcher's current seq: still equal means the caller is current and is
   *  answered `file:tree:unchanged` instead of the whole tree. Only a caller
   *  that can vouch the seq came from THIS agent process may send it — a
   *  restarted agent counts from zero again, so a stale claim would be
   *  confirmed rather than corrected (see file_service.dart). */
  sinceSeq: z.number().int().nonnegative().optional(),
  ...CheckoutScoped,
});

const FileTreeSnapshotMessage = BaseMessage.extend({
  type: z.literal("file:tree:snapshot"),
  tree: FileTreeNodeSchema,
  seq: z.number().int().nonnegative(),
  ...CheckoutScoped,
});

/** The cheap answer to a `sinceSeq` request the watcher has not moved past.
 *  Its own type rather than a tree-less `file:tree:snapshot`: a snapshot whose
 *  tree is sometimes absent puts a "when is this null?" question on every
 *  future reader of the frame that normally carries the tree. */
const FileTreeUnchangedMessage = BaseMessage.extend({
  type: z.literal("file:tree:unchanged"),
  seq: z.number().int().nonnegative(),
  ...CheckoutScoped,
});

const PreviewSnapshotRequestMessage = BaseMessage.extend({
  type: z.literal("preview:snapshot:request"),
  ...CheckoutScoped,
});

const PreviewUrlEntrySchema = z.object({
  port: z.number().int().positive(),
  url: z.string(),
  label: z.string().optional(),
  // Detected dev-server scheme — mirrors PortInfoSchema.scheme so a
  // welcome-replayed snapshot doesn't lose it (absent = unknown → http).
  scheme: z.enum(["http", "https"]).optional(),
});

const PreviewSnapshotMessage = BaseMessage.extend({
  type: z.literal("preview:snapshot"),
  urls: z.array(PreviewUrlEntrySchema),
  ...CheckoutScoped,
});

const RpcErrorSchema = z.object({
  code: z.string(),
  message: z.string(),
});

const RequestMessage = BaseMessage.extend({
  type: z.literal("request"),
  requestId: z.string(),
  method: z.string(),
  params: z.unknown().optional(),
});

const ResponseMessage = BaseMessage.extend({
  type: z.literal("response"),
  requestId: z.string(),
  ok: z.boolean(),
  result: z.unknown().optional(),
  error: RpcErrorSchema.optional(),
});

// ── Normalized agent event model ──────────────────────────────────────────────
// Item taxonomy is nested inside item-added/item-updated so new item kinds
// never require touching KNOWN_TYPES. AgentItem uses z.string() for `kind` so
// the bridge can forward unknown kinds without a schema change.
// ---------------------------------------------------------------------------
// Session bus (`docs/session-messaging.md`) — the agent-to-agent frames.
//
// The envelope lives HERE rather than in bridge/src/session-bus/, which is
// where the rest of the bus lives: it is a wire schema, the stores under
// session-bus/ import `SessionMemberRefSchema` from this file, and a schema
// module importing back would put this file's top-level `z.object` calls
// behind a TDZ binding. Those modules re-export these names so a bus caller
// still has one import site.
// ---------------------------------------------------------------------------

/** One unit of content. `artifact` carries the HANDLE only — spec 6.3's
 *  reference-over-value: the bytes stay on the machine that made them and are
 *  pulled with `session-bus:fetch` when the other side decides it wants them. */
export const BusPartSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("text"), text: z.string().max(MAX_PART_CHARS) }),
  z.object({ kind: z.literal("data"), data: z.record(z.string(), z.unknown()) }),
  z.object({
    kind: z.literal("artifact"),
    artifactId: z.string().min(1).max(200),
    name: z.string().min(1).max(200),
    mediaType: z.string().min(1).max(120),
    bytes: z.number().int().nonnegative(),
    sha256: z.string().length(64),
    summary: z.string().min(1).max(MAX_SUMMARY_CHARS),
  }),
]);
export type BusPart = z.infer<typeof BusPartSchema>;

export const BusEnvelopeSchema = z.object({
  messageId: z.string().min(1).max(200),
  /** The thread this belongs to, or null to open a new one. A correlation id
   *  with no state machine (spec 4.2): it is carried and never validated, and
   *  a thread is simply garbage once both sides stop writing to it. */
  threadId: z.string().min(1).max(200).nullable(),
  contextId: z.string().min(1).max(200),
  parts: z.array(BusPartSchema).min(1).max(MAX_PARTS),
  metadata: z.object({
    /** Stamped from the connection by the receiving bridge, never a tool
     *  parameter: an agent must not be able to author its own provenance. */
    peer: SessionMemberRefSchema,
    /** The one agent-authored envelope field (spec 3.4). MANDATORY, and never
     *  defaulted — it is what the human and the other agent read first, so
     *  inventing one would hide the omission instead of reporting it. */
    summary: z.string().min(1).max(MAX_SUMMARY_CHARS),
    timestamp: z.number().int().nonnegative(),
    /** Spec 6.2's first-class channel for "here is what you asked for, and
     *  separately, here is something you did not ask about". First-class so it
     *  is not a smuggled instruction inside a text part. */
    unexpected: z.string().max(MAX_UNEXPECTED_CHARS).optional(),
  }),
});
export type BusEnvelope = z.infer<typeof BusEnvelopeSchema>;

/** Both endpoints on every frame. Nothing shorter is an address: a machine holds
 *  several projects and a project several sessions, and the carrier picks the
 *  relay session to forward on out of `to`. */
const SessionBusBaseWire = {
  from: SessionMemberKeySchema,
  to: SessionMemberKeySchema,
  contextId: z.string().min(1).max(200),
};

/** The body both verbs carry, since spec 6.2 makes everything after the send
 *  decision identical for the two. No `seq`: spec 6 makes messages lossy on
 *  purpose, and reliable delivery behind text that changes no state would be
 *  unbounded retry buying nothing. The E6 receipt witnesses arrival without
 *  making it reliable — it is never retried either. */
export const SessionBusMessageWire = z.object({
  ...SessionBusBaseWire,
  threadId: z.string().min(1).max(200).nullable(),
  envelope: BusEnvelopeSchema,
});

export const SessionBusFetchWire = z.object({
  ...SessionBusBaseWire,
  requestId: z.string().min(1).max(200),
  artifactId: z.string().min(1).max(200),
  offset: z.number().int().nonnegative(),
  length: z.number().int().positive().max(ARTIFACT_CHUNK_BYTES),
});

export const SessionBusFetchResultWire = z.object({
  ...SessionBusBaseWire,
  requestId: z.string().min(1).max(200),
  ok: z.boolean(),
  error: z.string().max(500).optional(),
  errorCode: z.string().max(80).optional(),
  artifactId: z.string().min(1).max(200),
  offset: z.number().int().nonnegative(),
  eof: z.boolean(),
  dataBase64: z.string().max(ARTIFACT_CHUNK_B64_MAX),
});

/** The delivery receipt (E6), keyed by the id of the message it answers — the
 *  only honest witness that a frame arrived, since everything this side of the
 *  relay reports only that it left. It is fire-and-forget: an unacked ack is
 *  never retried, and `ok: false` is still a receipt — "this reached me", not
 *  "I liked it". No `seq`, because messages have none. */
export const SessionBusAckWire = z.object({
  ...SessionBusBaseWire,
  messageId: z.string().min(1).max(200),
  ok: z.boolean(),
  error: z.string().max(500).optional(),
});

/** Two verbs rather than one verb and a flag (spec 7.1), and the shape is
 *  identical because everything after the send decision is: a bridge that does
 *  not know a verb REFUSES it, where a bridge that does not know a flag would
 *  silently do the wrong thing — and a required Zod field is only fail-closed
 *  in the old→new direction, which is the wrong one. */
const SessionBusPostMessage = BaseMessage.extend({
  type: z.literal("session-bus:post"),
}).extend(SessionBusMessageWire.shape);

const SessionBusNotifyMessage = BaseMessage.extend({
  type: z.literal("session-bus:notify"),
}).extend(SessionBusMessageWire.shape);

const SessionBusFetchMessage = BaseMessage.extend({
  type: z.literal("session-bus:fetch"),
}).extend(SessionBusFetchWire.shape);

const SessionBusFetchResultMessage = BaseMessage.extend({
  type: z.literal("session-bus:fetch:result"),
}).extend(SessionBusFetchResultWire.shape);

const SessionBusAckMessage = BaseMessage.extend({
  type: z.literal("session-bus:ack"),
}).extend(SessionBusAckWire.shape);


// ── Session bus: what the APP reads of its OWN bridge ────────────────────────
// The five frames above are agent-to-agent traffic the app only CARRIES between
// two bridges that cannot dial each other. These are the opposite: an app
// asking the bridge it is attached to about its own sessions, and consuming the
// answer. Same plane all the same — `SessionBusApi` is built inside the project
// core with the machine-level directory injected into it, so machine-scoped
// STATE never implied machine-scoped transport (`docs/session-messaging.md`
// §5.4: "The transport did not move with it").
//
// Every one is answered from that single api rather than re-derived here. A
// human surface and an agent tool that each computed who is reachable would
// eventually disagree, and nothing would say which of the two was right.

/** The bus's one refusal vocabulary (`session-bus/errors.ts`) as it rides a
 *  result frame. `code` is a bare string rather than an enum over that map's
 *  keys: a reader branches on the code and renders the `error` text authored at
 *  the point of refusal, and one that dropped a whole frame over a code it had
 *  not learned yet would turn a NEW refusal into silence.
 *
 *  Present exactly when the answer fields are absent. Collapsing a refusal into
 *  an empty answer instead would render "this terminal names no session" as
 *  "nobody has written to you", which is the one wrong thing an inbox can say. */
const SessionBusRefusalWire = {
  error: z.string().max(500).optional(),
  code: z.string().max(80).optional(),
};

/** One directory row (§5.5). Mirrors `SessionDirectoryRow`
 *  (`session-bus/directory.ts`) field for field rather than importing it, the
 *  same one-way edge that module already keeps against the remote mirror's row:
 *  the wire vocabulary lives here and the bus's internals must be free to gain
 *  a field this does not carry. */
const SessionBusDirectoryRowSchema = z.object({
  /** Null in local mode, where no frame can leave the machine to need one. */
  machineId: z.string().max(200).nullable(),
  machineLabel: z.string().max(120).optional(),
  projectId: z.string().max(200),
  projectLabel: z.string().max(120).optional(),
  sessionId: z.string().max(200),
  title: z.string().max(200),
  branch: z.string().max(250).nullable(),
  activity: z.enum(["running", "idle", "stopped"]),
  workStatus: WorkStatusSchema.optional(),
  lastActiveAt: z.number(),
  /** Whether that session's agent can be messaged back at all (§9). A
   *  receive-only vendor is offered saying so, never as a peer that will
   *  silently never answer. */
  canReply: z.boolean(),
});

/** One machine in the reach report. It rides beside the rows and never in them:
 *  a peer whose rows have all expired contributes nothing to the list and must
 *  still be NAMED, or "that machine is not reachable from here" renders as
 *  "that machine has nothing running". */
const SessionBusReachMachineSchema = z.object({
  machineId: z.string().max(200),
  machineLabel: z.string().max(120).optional(),
  status: z.enum(["answered", "no-card", "refused", "reach-refused", "unreachable"]),
  rows: z.number(),
  droppedRows: z.number(),
  truncatedCard: z.number(),
  ageMs: z.number(),
});

/** `DirectoryReach` (`session-bus/directory.ts`): either this answer never left
 *  the machine, and why, or it spans the network and says what each peer
 *  contributed. */
const SessionBusDirectoryReachSchema = z.discriminatedUnion("scope", [
  z.object({
    scope: z.literal("machine"),
    why: z.enum(["remote-access-off", "no-machine-id", "no-carrier"]),
  }),
  z.object({
    scope: z.literal("network"),
    lastPushAgoMs: z.number(),
    machines: z.array(SessionBusReachMachineSchema),
    staleMachines: z.number(),
    notConnected: z.number(),
  }),
]);

const SessionBusInboxArtifactSchema = z.object({
  artifactId: z.string().max(200),
  name: z.string().max(200),
  mediaType: z.string().max(120),
  bytes: z.number(),
  sha256: z.string().max(64),
  summary: z.string().max(MAX_SUMMARY_CHARS),
});

/** One unread post, rendered whole so a reader needs no second call per row. */
const SessionBusInboxPostSchema = z.object({
  messageId: z.string().max(200),
  threadId: z.string().max(200).nullable(),
  contextId: z.string().max(200),
  at: z.number(),
  from: SessionMemberKeySchema,
  summary: z.string().max(MAX_SUMMARY_CHARS),
  text: z.array(z.string()),
  unexpected: z.string().max(MAX_UNEXPECTED_CHARS).optional(),
  artifacts: z.array(SessionBusInboxArtifactSchema),
});

const SessionBusThreadEntrySchema = z.object({
  direction: z.enum(["in", "out"]),
  at: z.number(),
  peer: SessionMemberKeySchema,
  summary: z.string().max(MAX_SUMMARY_CHARS),
  text: z.array(z.string()),
  /** Outbound entries only, and its absence is "no receipt yet" rather than a
   *  failure: a receipt is fire-and-forget and an unacked message is never
   *  retried. This read is the only surface that stamp is visible on. */
  deliveredAt: z.number().optional(),
});

const SessionBusDirectoryMessage = BaseMessage.extend({
  type: z.literal("session-bus:directory"),
  requestId: z.string(),
  /** Whose directory this is. Every bus read is asked ON BEHALF of one session
   *  — there is no machine-wide "who is out there" answer, because reachability
   *  is computed from the asking session's own repo key and branch. */
  sessionId: z.string(),
});

const SessionBusDirectoryResultMessage = BaseMessage.extend({
  type: z.literal("session-bus:directory:result"),
  requestId: z.string(),
  sessions: z.array(SessionBusDirectoryRowSchema).optional(),
  /** Rows the bound dropped. Never silent: a truncated list that claims to be
   *  complete reads as "there is nobody else". */
  truncated: z.number().optional(),
  reach: SessionBusDirectoryReachSchema.optional(),
  /** The asking machine's own id, so a renderer can tell a local row from a
   *  peer's. Deriving it by elimination from `reach` would be wrong in exactly
   *  the state that matters — a peer whose rows expired is named there while
   *  contributing none. */
  machineId: z.string().nullable().optional(),
  ...SessionBusRefusalWire,
});

const SessionBusInboxMessage = BaseMessage.extend({
  type: z.literal("session-bus:inbox"),
  requestId: z.string(),
  sessionId: z.string(),
});

const SessionBusInboxResultMessage = BaseMessage.extend({
  type: z.literal("session-bus:inbox:result"),
  requestId: z.string(),
  /** A PEEK: answering this does not mark anything read. The agent's own read
   *  is what spends the unread flag — see `SessionBusApi.inboxPeek`. */
  posts: z.array(SessionBusInboxPostSchema).optional(),
  /** Posts this session will never see, zero included (§7.4): a reader that
   *  cannot tell an empty inbox from an emptied one has been told the wrong
   *  thing, not merely told less. */
  dropped: z.number().optional(),
  ...SessionBusRefusalWire,
});

const SessionBusThreadMessage = BaseMessage.extend({
  type: z.literal("session-bus:thread"),
  requestId: z.string(),
  sessionId: z.string(),
  threadId: z.string(),
});

const SessionBusThreadResultMessage = BaseMessage.extend({
  type: z.literal("session-bus:thread:result"),
  requestId: z.string(),
  /** Echoed even on a refusal: a surface holding several open threads has to
   *  know which one was refused, and `requestId` alone says that only to the
   *  caller that still remembers what it asked. */
  threadId: z.string(),
  contextId: z.string().optional(),
  entries: z.array(SessionBusThreadEntrySchema).optional(),
  ...SessionBusRefusalWire,
});

/** Unsolicited: a mailbox grew. Carries WHOSE and nothing else — no count,
 *  because nothing renders one: a session's peers are not the user's business
 *  and no surface announces their mail. What still needs the signal is a sheet
 *  ALREADY open on that mailbox, which re-reads on it, and the kebab row that
 *  is the one door to it. Coalesced per session on the bridge, so a burst of
 *  arrivals is one push rather than one per post. */
const SessionBusArrivedMessage = BaseMessage.extend({
  type: z.literal("session-bus:arrived"),
  sessionId: z.string(),
});

// ── Netwatch: shipping a remote app's half of the frame capture ───────────────
// Both ride the machine CONTROL plane and are consumed by relay-client.ts before
// anything project-scoped sees them. Deliberately absent from
// CHECKOUT_VARIABLE_MESSAGE_TYPES: neither reads nor writes a working tree.

// Agent -> app: arm or disarm the app's own frame capture. A phone has no env
// var and no UI for this, so `antgrid watch --remote` is the only control
// surface. `ttlMs` is a DEAD-MAN SWITCH, not a preference: a CLI killed with
// SIGKILL sends no disarm, and a phone left capturing forever costs battery and
// bandwidth with nothing on the device able to stop it. The watcher re-arms
// well inside the window while it runs.
const NetwatchConfigureMessage = BaseMessage.extend({
  type: z.literal("netwatch:configure"),
  enabled: z.boolean(),
  ttlMs: z.number().int().positive().optional(),
});

// App -> agent: a batch of the app's own capture events. The element shape is
// `NetwatchEvent` (netwatch.ts) minus the fields this side stamps itself, and is
// passthrough on purpose — a bridge must forward an event from a NEWER app
// without understanding every field, since the whole point is reading what that
// app saw. `dropped` counts what the app's own budget discarded, so a gap in
// `seq` is never mistaken for a frame that went missing on the wire.
const NetwatchEventsMessage = BaseMessage.extend({
  type: z.literal("netwatch:events"),
  events: z.array(z.record(z.string(), z.unknown())).max(1000),
  dropped: z.number().int().nonnegative().optional(),
  /** The app's own clock when it sent this batch. The bridge subtracts it from
   *  its own receive time to shift every `at` in the batch onto ONE clock — see
   *  `Netwatch.ingestRemote`. Absent means no correction, which is right for an
   *  app on this same machine. */
  sentAt: z.number().optional(),
});

export const AbMessageSchema = z.discriminatedUnion("type", [
  AgentHelloMessage,
  PortDetectedMessage,
  TerminalOutputMessage,
  TerminalInputMessage,
  TerminalStartedMessage,
  TerminalExitedMessage,
  TerminalNotificationMessage,
  TerminalBellMessage,
  TerminalStartCommand,
  TerminalStopCommand,
  TerminalResizeCommand,
  TerminalSizeMessage,
  AgentStatusMessage,
  PingMessage,
  PongMessage,
  TreeFullMessage,
  TreeUpdateMessage,
  FileReadMessage,
  FileContentMessage,
  FileResolvePathMessage,
  FileResolvePathResultMessage,
  FileSearchMessage,
  FileSearchCancelMessage,
  FileSearchResultMessage,
  FileSearchDoneMessage,
  FileUploadStartMessage,
  FileUploadReadyMessage,
  FileUploadChunkMessage,
  FileUploadAckMessage,
  FileUploadDoneMessage,
  FileUploadResultMessage,
  PortsUpdateMessage,
  PreviewUrlMessage,
  AgentDisconnectingMessage,
  AgentProjectsMessage,
  AgentToolsMessage,
  StreamReadyMessage,
  ControlResultMessage,
  CommandRunMessage,
  CommandOutputMessage,
  CommandDoneMessage,
  NotificationPushMessage,
  PushRegisterMessage,
  HandlerConfigureMessage,
  HandlerInstructMessage,
  HandlerStatusMessage,
  HandlerEscalationMessage,
  HandlerActivityMessage,
  HandlerSnapshotMessage,
  HandlerUndoMessage,
  HandlerDismissMessage,
  HandlerAnswerMessage,
  GitStatusMessage,
  GitDiffRequestMessage,
  GitDiffContentMessage,
  GitListBranchesMessage,
  GitBranchesMessage,
  GitCheckoutMessage,
  GitCheckoutResultMessage,
  GitCommitMessage,
  GitCommitResultMessage,
  GitDiscardMessage,
  GitDiscardResultMessage,
  GitStageMessage,
  GitStageResultMessage,
  GitUnstageMessage,
  GitUnstageResultMessage,
  GitStashListRequestMessage,
  GitStashListResultMessage,
  GitStashPopMessage,
  GitStashPopResultMessage,
  GitStashDropMessage,
  GitStashDropResultMessage,
  GitLogRequestMessage,
  GitLogResultMessage,
  GitCommitFilesRequestMessage,
  GitCommitFilesResultMessage,
  GitCommitDiffRequestMessage,
  GitCommitDiffContentMessage,
  GitSyncMessage,
  GitSyncResultMessage,
  GitSyncStatusMessage,
  GitSyncStateMessage,
  AgentEnableRelayMessage,
  AgentDisableRelayMessage,
  AgentActivationPendingMessage,
  AgentRelayReadyMessage,
  AgentRelayErrorMessage,
  ProjectStartMessage,
  ConfigReadMessage,
  ConfigReadResultMessage,
  ConfigWriteMessage,
  ConfigWriteResultMessage,
  ConfigChangedMessage,
  ConfigDetectToolsMessage,
  ConfigDetectToolsResultMessage,
  SessionListMessage,
  SessionListResultMessage,
  SessionCreateMessage,
  SessionForkMessage,
  SessionStartMessage,
  SessionStopMessage,
  SessionRenameMessage,
  SessionArchiveMessage,
  SessionUnarchiveMessage,
  SessionDeleteMessage,
  SessionSetModeMessage,
  SessionSetupMessage,
  SessionFocusMessage,
  SessionResultMessage,
  SessionUpdatedMessage,
  ClientFocusStateMessage,
  TerminalSnapshotRequestMessage,
  TerminalSnapshotMessage,
  TerminalSubscribeMessage,
  TerminalSubscribedMessage,
  TerminalFrameMessage,
  TerminalAckMessage,
  TerminalUnsubscribeMessage,
  TerminalHistoryRequestMessage,
  TerminalHistoryPageMessage,
  TerminalDisplayStatusMessage,
  FileTreeSnapshotRequestMessage,
  FileTreeSnapshotMessage,
  FileTreeUnchangedMessage,
  PreviewSnapshotRequestMessage,
  PreviewSnapshotMessage,
  RequestMessage,
  ResponseMessage,
  AgentTurnStartMessage,
  AgentSessionResetMessage,
  AgentTurnEndMessage,
  AgentTranscriptReplayMessage,
  AgentItemAddedMessage,
  AgentItemDeltaMessage,
  AgentItemUpdatedMessage,
  AgentSnapshotMessage,
  AgentCapabilitiesMessage,
  AgentUpdateAvailableMessage,
  AgentUpdateMessage,
  AgentUpdateResultMessage,
  AgentPermissionRequestMessage,
  AgentQuestionMessage,
  AgentRequestRetractedMessage,
  AgentErrorMessage,
  AgentUsageMessage,
  AgentBackgroundTasksMessage,
  AgentPromptMessage,
  AgentCancelMessage,
  AgentSetConfigMessage,
  AgentSessionActionMessage,
  AgentPermissionResolveMessage,
  AgentQuestionResolveMessage,
  AgentTaskStopMessage,
  SessionBusPostMessage,
  SessionBusNotifyMessage,
  SessionBusFetchMessage,
  SessionBusFetchResultMessage,
  SessionBusAckMessage,
  SessionBusDirectoryMessage,
  SessionBusDirectoryResultMessage,
  SessionBusInboxMessage,
  SessionBusInboxResultMessage,
  SessionBusThreadMessage,
  SessionBusThreadResultMessage,
  SessionBusArrivedMessage,
  NetwatchConfigureMessage,
  NetwatchEventsMessage,
]);

export type AbMessage = z.infer<typeof AbMessageSchema>;

export type NetwatchConfigure = z.infer<typeof NetwatchConfigureMessage>;
export type NetwatchEvents = z.infer<typeof NetwatchEventsMessage>;

export type TerminalNotificationMessage = z.infer<typeof TerminalNotificationMessage>;
export type TerminalBellMessage = z.infer<typeof TerminalBellMessage>;

export type TerminalOutput = z.infer<typeof TerminalOutputMessage>;
export type TerminalInput = z.infer<typeof TerminalInputMessage>;
export type TerminalStarted = z.infer<typeof TerminalStartedMessage>;
export type TerminalExited = z.infer<typeof TerminalExitedMessage>;
export type SessionHello = z.infer<typeof SessionHelloFrame>;
export type SessionEstablished = z.infer<typeof SessionEstablishedFrame>;
export type TerminalStart = z.infer<typeof TerminalStartCommand>;
export type TerminalStop = z.infer<typeof TerminalStopCommand>;
export type TerminalResize = z.infer<typeof TerminalResizeCommand>;
export type TerminalSize = z.infer<typeof TerminalSizeMessage>;
export type AgentStatus = z.infer<typeof AgentStatusMessage>;
export type TreeFull = z.infer<typeof TreeFullMessage>;
export type TreeUpdate = z.infer<typeof TreeUpdateMessage>;
export type FileRead = z.infer<typeof FileReadMessage>;
export type FileContent = z.infer<typeof FileContentMessage>;
export type FileResolvePath = z.infer<typeof FileResolvePathMessage>;
export type FileResolvePathResult = z.infer<typeof FileResolvePathResultMessage>;
export type PortInfo = z.infer<typeof PortInfoSchema>;
export type PortsUpdate = z.infer<typeof PortsUpdateMessage>;
export type PreviewUrl = z.infer<typeof PreviewUrlMessage>;
export type AgentDisconnecting = z.infer<typeof AgentDisconnectingMessage>;
export type AgentProjects = z.infer<typeof AgentProjectsMessage>;
export type ProjectAdvertEntry = AgentProjects["projects"][number];
export type AgentTools = z.infer<typeof AgentToolsMessage>;
export type StreamReady = z.infer<typeof StreamReadyMessage>;
export type ControlResult = z.infer<typeof ControlResultMessage>;
export type CommandRun = z.infer<typeof CommandRunMessage>;
export type CommandOutput = z.infer<typeof CommandOutputMessage>;
export type CommandDone = z.infer<typeof CommandDoneMessage>;
export type NotificationPush = z.infer<typeof NotificationPushMessage>;
export type PushRegister = z.infer<typeof PushRegisterMessage>;
export type HandlerInstructionItem = z.infer<typeof InstructionItemWire>;
export type HandlerConfigureMsg = z.infer<typeof HandlerConfigureMessage>;
export type HandlerInstructMsg = z.infer<typeof HandlerInstructMessage>;
export type HandlerSessionSnapshot = z.infer<typeof HandlerSessionSnapshot>;
export type HandlerStatusMsg = z.infer<typeof HandlerStatusMessage>;
export type HandlerEntitlement = z.infer<typeof HandlerEntitlementWire>;
export type HandlerEscalationMsg = z.infer<typeof HandlerEscalationMessage>;
export type HandlerActivityMsg = z.infer<typeof HandlerActivityMessage>;
export type HandlerSnapshotMsg = z.infer<typeof HandlerSnapshotMessage>;
export type HandlerUndoMsg = z.infer<typeof HandlerUndoMessage>;
export type HandlerDismissMsg = z.infer<typeof HandlerDismissMessage>;
export type HandlerAnswerMsg = z.infer<typeof HandlerAnswerMessage>;
export type GitStatus = z.infer<typeof GitStatusMessage>;
export type GitDiffRequest = z.infer<typeof GitDiffRequestMessage>;
export type GitDiffContent = z.infer<typeof GitDiffContentMessage>;
export type GitListBranches = z.infer<typeof GitListBranchesMessage>;
export type GitBranches = z.infer<typeof GitBranchesMessage>;
export type GitCheckout = z.infer<typeof GitCheckoutMessage>;
export type GitCheckoutResult = z.infer<typeof GitCheckoutResultMessage>;
export type GitCommit = z.infer<typeof GitCommitMessage>;
export type GitCommitResult = z.infer<typeof GitCommitResultMessage>;
export type GitDiscard = z.infer<typeof GitDiscardMessage>;
export type GitDiscardResult = z.infer<typeof GitDiscardResultMessage>;
export type GitStage = z.infer<typeof GitStageMessage>;
export type GitStageResult = z.infer<typeof GitStageResultMessage>;
export type GitUnstage = z.infer<typeof GitUnstageMessage>;
export type GitUnstageResult = z.infer<typeof GitUnstageResultMessage>;
export type GitStashEntryWire = z.infer<typeof GitStashEntrySchema>;
export type GitStashListRequest = z.infer<typeof GitStashListRequestMessage>;
export type GitStashListResult = z.infer<typeof GitStashListResultMessage>;
export type GitStashPop = z.infer<typeof GitStashPopMessage>;
export type GitStashPopResult = z.infer<typeof GitStashPopResultMessage>;
export type GitStashDrop = z.infer<typeof GitStashDropMessage>;
export type GitStashDropResult = z.infer<typeof GitStashDropResultMessage>;
export type GitLogEntryWire = z.infer<typeof GitLogEntrySchema>;
export type GitLogRequest = z.infer<typeof GitLogRequestMessage>;
export type GitLogResult = z.infer<typeof GitLogResultMessage>;
export type GitCommitFileEntryWire = z.infer<typeof GitCommitFileEntrySchema>;
export type GitCommitFilesRequest = z.infer<typeof GitCommitFilesRequestMessage>;
export type GitCommitFilesResult = z.infer<typeof GitCommitFilesResultMessage>;
export type GitCommitDiffRequest = z.infer<typeof GitCommitDiffRequestMessage>;
export type GitCommitDiffContent = z.infer<typeof GitCommitDiffContentMessage>;
export type GitSync = z.infer<typeof GitSyncMessage>;
export type GitSyncResult = z.infer<typeof GitSyncResultMessage>;
export type GitSyncStatus = z.infer<typeof GitSyncStatusMessage>;
export type GitSyncState = z.infer<typeof GitSyncStateMessage>;
export type FileSearch = z.infer<typeof FileSearchMessage>;
export type FileSearchCancel = z.infer<typeof FileSearchCancelMessage>;
export type SearchMatch = z.infer<typeof SearchMatchSchema>;
export type FileSearchResult = z.infer<typeof FileSearchResultMessage>;
export type FileSearchDone = z.infer<typeof FileSearchDoneMessage>;
export type FileUploadStart = z.infer<typeof FileUploadStartMessage>;
export type FileUploadReady = z.infer<typeof FileUploadReadyMessage>;
export type FileUploadChunk = z.infer<typeof FileUploadChunkMessage>;
export type FileUploadAck = z.infer<typeof FileUploadAckMessage>;
export type FileUploadDone = z.infer<typeof FileUploadDoneMessage>;
export type FileUploadResult = z.infer<typeof FileUploadResultMessage>;
export type AgentHelloMessage = z.infer<typeof AgentHelloMessage>;
export type PortDetectedMessage = z.infer<typeof PortDetectedMessage>;
export type AgentEnableRelay = z.infer<typeof AgentEnableRelayMessage>;
export type AgentEnableRelayAuth = z.infer<typeof AgentEnableRelayAuth>;
export type AgentDisableRelay = z.infer<typeof AgentDisableRelayMessage>;
export type AgentActivationPending = z.infer<typeof AgentActivationPendingMessage>;
export type AgentRelayReady = z.infer<typeof AgentRelayReadyMessage>;
export type AgentRelayError = z.infer<typeof AgentRelayErrorMessage>;
export type ProjectStart = z.infer<typeof ProjectStartMessage>;
export type ConfigRead = z.infer<typeof ConfigReadMessage>;
export type ConfigReadResult = z.infer<typeof ConfigReadResultMessage>;
export type ConfigWrite = z.infer<typeof ConfigWriteMessage>;
export type ConfigWriteResult = z.infer<typeof ConfigWriteResultMessage>;
export type ConfigChanged = z.infer<typeof ConfigChangedMessage>;
export type ConfigDetectTools = z.infer<typeof ConfigDetectToolsMessage>;
export type ConfigDetectToolsResult = z.infer<typeof ConfigDetectToolsResultMessage>;
export type SessionEntry = z.infer<typeof SessionEntrySchema>;
export type SessionList = z.infer<typeof SessionListMessage>;
export type SessionListResult = z.infer<typeof SessionListResultMessage>;
export type SessionCreate = z.infer<typeof SessionCreateMessage>;
export type SessionMemberRef = z.infer<typeof SessionMemberRefSchema>;
export type SessionMemberCard = z.infer<typeof SessionMemberCardSchema>;
export type SessionMemberKey = z.infer<typeof SessionMemberKeySchema>;
export type SessionFork = z.infer<typeof SessionForkMessage>;
export type SessionStart = z.infer<typeof SessionStartMessage>;
export type SessionStop = z.infer<typeof SessionStopMessage>;
export type SessionRename = z.infer<typeof SessionRenameMessage>;
export type SessionArchive = z.infer<typeof SessionArchiveMessage>;
export type SessionUnarchive = z.infer<typeof SessionUnarchiveMessage>;
export type SessionDelete = z.infer<typeof SessionDeleteMessage>;
export type SessionSetMode = z.infer<typeof SessionSetModeMessage>;
export type SessionSetup = z.infer<typeof SessionSetupMessage>;
export type SessionFocus = z.infer<typeof SessionFocusMessage>;
export type SessionResult = z.infer<typeof SessionResultMessage>;
export type SessionUpdated = z.infer<typeof SessionUpdatedMessage>;
export type ClientFocusState = z.infer<typeof ClientFocusStateMessage>;
export type TerminalSnapshotRequest = z.infer<typeof TerminalSnapshotRequestMessage>;
export type TerminalSnapshot = z.infer<typeof TerminalSnapshotMessage>;
// The wire types for the frame display protocol. This file is their single
// home — the same eight names are also exported from terminal-frames/protocol.ts
// (whose envelopes predate registration and lack CheckoutScoped's `main`
// default), and `TerminalFrame` is a third name in terminal-frames/source.ts,
// where it means the CAPTURE payload rather than a wire message. Import the
// wire types from here; anything created by `createMessage` has these shapes.
export type TerminalSubscribe = z.infer<typeof TerminalSubscribeMessage>;
export type TerminalSubscribed = z.infer<typeof TerminalSubscribedMessage>;
export type TerminalFrame = z.infer<typeof TerminalFrameMessage>;
export type TerminalAck = z.infer<typeof TerminalAckMessage>;
export type TerminalUnsubscribe = z.infer<typeof TerminalUnsubscribeMessage>;
export type TerminalHistoryRequest = z.infer<typeof TerminalHistoryRequestMessage>;
export type TerminalHistoryPage = z.infer<typeof TerminalHistoryPageMessage>;
export type TerminalDisplayStatus = z.infer<typeof TerminalDisplayStatusMessage>;
export type FileTreeSnapshotRequest = z.infer<typeof FileTreeSnapshotRequestMessage>;
export type FileTreeSnapshot = z.infer<typeof FileTreeSnapshotMessage>;
export type FileTreeUnchanged = z.infer<typeof FileTreeUnchangedMessage>;
export type PreviewSnapshotRequest = z.infer<typeof PreviewSnapshotRequestMessage>;
export type PreviewSnapshot = z.infer<typeof PreviewSnapshotMessage>;
export type PreviewUrlEntry = z.infer<typeof PreviewUrlEntrySchema>;
export type RpcRequest = z.infer<typeof RequestMessage>;
export type RpcResponse = z.infer<typeof ResponseMessage>;
export type AgentItem = z.infer<typeof AgentItemSchema>;
export type AgentError = z.infer<typeof AgentErrorSchema>;
export type ToolContent = z.infer<typeof ToolContentSchema>;
export type AgentUsage = z.infer<typeof AgentUsageSchema>;
export type AgentTurnStart = z.infer<typeof AgentTurnStartMessage>;
export type AgentSessionReset = z.infer<typeof AgentSessionResetMessage>;
export type AgentTurnEnd = z.infer<typeof AgentTurnEndMessage>;
export type AgentTranscriptReplay = z.infer<typeof AgentTranscriptReplayMessage>;
export type AgentItemAdded = z.infer<typeof AgentItemAddedMessage>;
export type AgentItemDelta = z.infer<typeof AgentItemDeltaMessage>;
export type AgentItemUpdated = z.infer<typeof AgentItemUpdatedMessage>;
export type AgentSnapshot = z.infer<typeof AgentSnapshotMessage>;
export type AgentCapabilities = z.infer<typeof AgentCapabilitiesMessage>;
export type AgentUpdateAvailable = z.infer<typeof AgentUpdateAvailableMessage>;
export type AgentUpdate = z.infer<typeof AgentUpdateMessage>;
export type AgentUpdateResult = z.infer<typeof AgentUpdateResultMessage>;
export type AgentPermissionRequest = z.infer<typeof AgentPermissionRequestMessage>;
export type AgentQuestion = z.infer<typeof AgentQuestionMessage>;
export type AgentRequestRetracted = z.infer<typeof AgentRequestRetractedMessage>;
export type AgentErrorEvent = z.infer<typeof AgentErrorMessage>;
export type AgentUsageEvent = z.infer<typeof AgentUsageMessage>;
export type AgentBackgroundTask = z.infer<typeof AgentBackgroundTaskSchema>;
export type AgentBackgroundTasksEvent = z.infer<typeof AgentBackgroundTasksMessage>;
export type AgentTaskStop = z.infer<typeof AgentTaskStopMessage>;
export type AgentPrompt = z.infer<typeof AgentPromptMessage>;
export type AgentCancel = z.infer<typeof AgentCancelMessage>;
export type AgentSetConfig = z.infer<typeof AgentSetConfigMessage>;
export type AgentSessionAction = z.infer<typeof AgentSessionActionMessage>;
export type AgentPermissionResolve = z.infer<typeof AgentPermissionResolveMessage>;
export type AgentQuestionResolve = z.infer<typeof AgentQuestionResolveMessage>;
export type SessionBusPost = z.infer<typeof SessionBusPostMessage>;
export type SessionBusNotify = z.infer<typeof SessionBusNotifyMessage>;
export type SessionBusFetch = z.infer<typeof SessionBusFetchMessage>;
export type SessionBusFetchResult = z.infer<typeof SessionBusFetchResultMessage>;
export type SessionBusAck = z.infer<typeof SessionBusAckMessage>;
export type SessionBusDirectoryRead = z.infer<typeof SessionBusDirectoryMessage>;
export type SessionBusDirectoryResult = z.infer<typeof SessionBusDirectoryResultMessage>;
export type SessionBusInboxRead = z.infer<typeof SessionBusInboxMessage>;
export type SessionBusInboxResult = z.infer<typeof SessionBusInboxResultMessage>;
export type SessionBusThreadRead = z.infer<typeof SessionBusThreadMessage>;
export type SessionBusThreadResult = z.infer<typeof SessionBusThreadResultMessage>;
export type SessionBusArrived = z.infer<typeof SessionBusArrivedMessage>;

/**
 * Types whose wire text must never be recorded verbatim, however loudly an
 * operator asks for bodies.
 *
 * `antgrid watch --bodies` exists to show what crossed a socket, and its output
 * is printed to a terminal, streamed over `/netwatch`, and appended to an
 * `--export` file that ends up pasted into bug reports. That is fine for a
 * `tree:full` and catastrophic for these three: `agent:enableRelay` carries the
 * account device's Ed25519 PRIVATE key plus `clientSecret` and `licenseToken`;
 * `agent:question-resolve` is the answer to a question the agent may have
 * flagged `isSecret`, which the UI masks on the way in; `terminal:input` is
 * literally the user's keystrokes, password prompts inside the PTY included.
 * The `tunnel:*` set is the preview proxy's own wire (tunnel-protocol.ts) and
 * carries the proxied site's request and response headers verbatim — `Cookie`,
 * `Authorization`, `Set-Cookie`. They are named here rather than there because
 * one list is the only way this stays checkable; they are also the case that
 * proves the check must key off the CLAIMED type, since `parseMessageFast`
 * refuses them and they reach the ring down the `unparseable` path.
 *
 * Metadata (type, id, byte count) is still recorded — only the payload is
 * withheld, so a capture still shows that the frame crossed and when.
 *
 * Add a type here in the same commit that gives it a secret-bearing field.
 */
export const BODY_REDACTED_MESSAGE_TYPES = new Set<string>([
  "agent:enableRelay",
  "agent:question-resolve",
  "terminal:input",
  // Rendered screen content, which is the same secret class `terminal:input` is
  // redacted for: whatever the user typed is echoed back into these two, so a
  // capture would otherwise hold the pasted token that the keystroke frames
  // withheld. `terminal:snapshot` predates this rule and is knowingly not here.
  "terminal:frame",
  "terminal:history:page",
  "tunnel:http-request",
  "tunnel:http-head",
  "tunnel:ws-open",
]);

/** The exhaustive checkout-variable protocol set. Any new filesystem-facing
 * type belongs here (and gets an explicit schema decision + contract test). */
export const CHECKOUT_VARIABLE_MESSAGE_TYPES = new Set<string>([
  "terminal:start", "terminal:stop", "terminal:input", "terminal:resize", "terminal:output", "terminal:started", "terminal:exited", "terminal:notification", "terminal:bell", "terminal:size",
  "terminal:snapshot:request", "terminal:snapshot",
  "terminal:subscribe", "terminal:subscribed", "terminal:frame", "terminal:ack",
  "terminal:unsubscribe", "terminal:history:request", "terminal:history:page", "terminal:display:status",
  "agent:status",
  "tree:full", "tree:update", "file:read", "file:content",
  "file:resolve-path", "file:resolve-path-result",
  "file:search", "file:search-cancel", "file:search-result", "file:search-done",
  "file:upload-start", "file:upload-ready", "file:upload-chunk", "file:upload-ack", "file:upload-done", "file:upload-result",
  "git:status", "git:diff", "git:diff-content", "git:list-branches", "git:branches", "git:checkout", "git:checkout-result",
  "git:commit", "git:commit-result", "git:discard", "git:discard-result",
  "git:stage", "git:stage-result", "git:unstage", "git:unstage-result",
  "git:stash-list", "git:stash-list-result", "git:stash-pop", "git:stash-pop-result",
  "git:stash-drop", "git:stash-drop-result",
  "git:log", "git:log-result", "git:commit-files", "git:commit-files-result",
  "git:commit-diff", "git:commit-diff-content",
  "git:sync", "git:sync-result", "git:sync-status", "git:sync-state",
  "command:run", "command:output", "command:done",
  "config:read", "config:read-result", "config:write", "config:write-result", "config:changed", "config:detect-tools", "config:detect-tools-result",
  "ports:update", "port:detected", "preview:url", "file:tree:snapshot:request", "file:tree:snapshot", "file:tree:unchanged", "preview:snapshot:request", "preview:snapshot",
  "session:result", "control:result",
]);

/** The subset of CHECKOUT_VARIABLE_MESSAGE_TYPES carried on the "preview"
 * channel rather than "control" (see MessageBus.publish's channel argument
 * and send-scheduler.ts's control>preview priority): the two BULK per-frame
 * terminal payloads, `terminal:frame` (a viewer's live screen) and
 * `terminal:history:page` (a requested scrollback page). The frame
 * protocol's other six wire types — `terminal:subscribe`/`subscribed`,
 * `ack`, `unsubscribe`, `history:request`, `display:status` — are small,
 * latched, one-shot exchanges the requester is actively waiting on, so they
 * stay on "control" and are drained ahead of preview's bulk traffic rather
 * than queuing behind it; see the comment on `TerminalViewerTransport.send`
 * in agent-core.ts. Priority is not isolation: `SendScheduler.fits` also gates
 * on `SOCKET_INFLIGHT_BYTES`, which is shared by both channels and sits only
 * one channel-window above one, so a saturated preview channel leaves control
 * a bounded headroom and then it too waits for a credit.
 *
 * Mirrored BY HAND as `kPreviewChannelInboundTypes` in
 * app/lib/project/project_message_classification.dart, gated against this set
 * in checkout-mirror-contract.test.ts. Drift here is silent on the wire in
 * the worst way: a type added here with no Dart counterpart simply stops
 * arriving at the app, with no error on either side. The bridge side is safe
 * from the reverse drift only because every targeted terminal reply derives
 * its channel from this set (`sendAbToItsChannel` in agent-core.ts) — a call
 * site that hard-codes "preview" would keep sending a removed type onto a
 * channel the app no longer admits it on. */
export const PREVIEW_CHANNEL_MESSAGE_TYPES = new Set<string>([
  "terminal:frame",
  "terminal:history:page",
]);

type MessagePayload<T extends AbMessage["type"]> = Omit<
  Extract<AbMessage, { type: T }>,
  "id" | "timestamp" | "type" | "checkoutId"
> & Partial<Pick<Extract<AbMessage, { type: T }>, Extract<keyof Extract<AbMessage, { type: T }>, "checkoutId">>>;

export function createMessage<T extends AbMessage["type"]>(
  type: T,
  payload: MessagePayload<T>,
): Extract<AbMessage, { type: T }> {
  return {
    id: crypto.randomUUID(),
    timestamp: Date.now(),
    type,
    ...(CHECKOUT_VARIABLE_MESSAGE_TYPES.has(type) && !("checkoutId" in payload) ? { checkoutId: "main" } : {}),
    ...payload,
  } as Extract<AbMessage, { type: T }>;
}

/**
 * Wrap a resume-replay as a single `agent:transcript-replay` frame, or null
 * when there is nothing to replay.
 *
 * Drivers MUST push replays through this rather than sending each frame:
 * over the relay a per-frame replay exceeds the per-pair rate limit, and
 * rejected frames are dropped with no retransmit — silently truncating the
 * transcript (see AgentTranscriptReplayMessage).
 *
 * Returns null on an empty replay so a history-less resume stays silent: the
 * resume builders return [] for a thread with no turns, and the per-frame loop
 * this replaced sent nothing in that case.
 */
export function createTranscriptReplay(sessionId: string, frames: AbMessage[]): AbMessage | null {
  if (frames.length === 0) return null;
  return createMessage("agent:transcript-replay", {
    sessionId,
    frames: frames as unknown as Record<string, unknown>[],
  });
}

export function parseMessage(raw: string): AbMessage | null {
  try {
    const json = JSON.parse(raw);
    const result = AbMessageSchema.safeParse(json);
    return result.success ? result.data : null;
  } catch {
    return null;
  }
}

/**
 * Fast-path parser for trusted (already-decrypted) messages.
 * Skips full Zod validation — only checks that `type` is a known string.
 * Use this on the hot path (terminal:output) after the handshake is complete.
 */
const KNOWN_TYPES = new Set<string>([
  "terminal:output", "terminal:input", "terminal:started", "terminal:exited", "terminal:notification", "terminal:bell",
  "terminal:start", "terminal:stop", "terminal:resize", "terminal:size", "agent:status",
  "ping", "pong",
  "tree:full", "tree:update", "file:read", "file:content",
  "file:resolve-path", "file:resolve-path-result",
  "ports:update", "preview:url",
  "agent:disconnecting", "agent:projects", "agent:tools", "stream-ready", "control:result",
  "command:run", "command:output", "command:done", "notification:push", "push:register",
  "handler:configure", "handler:instruct", "handler:status", "handler:escalation", "handler:activity",
  "handler:snapshot", "handler:undo", "handler:dismiss", "handler:answer",
  "git:status", "git:diff", "git:diff-content",
  "git:list-branches", "git:branches", "git:checkout", "git:checkout-result",
  "git:commit", "git:commit-result", "git:discard", "git:discard-result",
  "git:stage", "git:stage-result", "git:unstage", "git:unstage-result",
  "git:stash-list", "git:stash-list-result", "git:stash-pop", "git:stash-pop-result",
  "git:stash-drop", "git:stash-drop-result",
  "git:log", "git:log-result", "git:commit-files", "git:commit-files-result",
  "git:commit-diff", "git:commit-diff-content",
  "git:sync", "git:sync-result", "git:sync-status", "git:sync-state",
  "file:search", "file:search-cancel", "file:search-result", "file:search-done",
  "file:upload-start", "file:upload-ready", "file:upload-chunk",
  "file:upload-ack", "file:upload-done", "file:upload-result",
  "agent:hello", "port:detected",
  "agent:enableRelay", "agent:disableRelay",
  "agent:activationPending", "agent:relayReady", "agent:relayError",
  "project:start",
  "config:read", "config:read-result", "config:write", "config:write-result",
  "config:changed", "config:detect-tools", "config:detect-tools-result",
  "session:list", "session:list:result",
  "session:create", "session:fork", "session:start", "session:stop",
  "session:rename", "session:archive", "session:unarchive",
  "session:delete", "session:set-mode", "session:setup", "session:focus",
  "session:result", "session:updated",
  "client:focus-state",
  "terminal:snapshot:request", "terminal:snapshot",
  "terminal:subscribe", "terminal:subscribed", "terminal:frame", "terminal:ack",
  "terminal:unsubscribe", "terminal:history:request", "terminal:history:page", "terminal:display:status",
  "file:tree:snapshot:request", "file:tree:snapshot", "file:tree:unchanged",
  "preview:snapshot:request", "preview:snapshot",
  "request", "response",
  "agent:turn-start", "agent:session-reset", "agent:turn-end",
  "agent:item-added", "agent:item-delta", "agent:item-updated",
  "agent:transcript-replay",
  "agent:snapshot", "agent:capabilities", "agent:updateAvailable",
  "agent:update", "agent:updateResult",
  "agent:permission-request", "agent:question", "agent:request-retracted", "agent:error", "agent:usage",
  "agent:background-tasks",
  "agent:prompt", "agent:cancel", "agent:set-config",
  "agent:session-action", "agent:permission-resolve", "agent:question-resolve", "agent:task-stop",
  "session-bus:post", "session-bus:notify", "session-bus:fetch", "session-bus:fetch:result", "session-bus:ack",
  "session-bus:directory", "session-bus:directory:result",
  "session-bus:inbox", "session-bus:inbox:result",
  "session-bus:thread", "session-bus:thread:result",
  "session-bus:arrived",
  "netwatch:configure", "netwatch:events",
]);

export function parseMessageFast(raw: string): AbMessage | null {
  try {
    const json = JSON.parse(raw);
    if (typeof json !== "object" || json === null) return null;
    if (!KNOWN_TYPES.has(json.type)) return null;
    return json as AbMessage;
  } catch {
    return null;
  }
}
