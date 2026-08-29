import { z } from "zod";
import { AbConfigSchema } from "./config";

const BaseMessage = z.object({
  id: z.string().uuid(),
  timestamp: z.number(),
});

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
}> = z.lazy(() =>
  z.object({
    name: z.string(),
    path: z.string(),
    type: z.enum(["file", "directory"]),
    size: z.number().optional(),
    extension: z.string().optional(),
    children: z.array(FileTreeNodeSchema).optional(),
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

const PingMessage = BaseMessage.extend({
  type: z.literal("ping"),
});

const PongMessage = BaseMessage.extend({
  type: z.literal("pong"),
});

const HandshakeClientHelloMessage = BaseMessage.extend({
  type: z.literal("handshake:client-hello"),
  pubkey: z.string(),
  nonce: z.string(),
  sig: z.string(),
});

const HandshakeAgentHelloMessage = BaseMessage.extend({
  type: z.literal("handshake:agent-hello"),
  pubkey: z.string(),
  sig: z.string(),
});

const HandshakeAgentReadyMessage = BaseMessage.extend({
  type: z.literal("handshake:agent-ready"),
  confirm: z.string(),
});

const AppReadyMessage = BaseMessage.extend({
  type: z.literal("app:ready"),
  confirm: z.string(),
  capabilities: z.object({ checkoutRouting: z.literal(true).optional() }).optional(),
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
  baseDriverClientId: z.string().optional(),
  ...CheckoutScoped,
});

const TerminalSizeMessage = BaseMessage.extend({
  type: z.literal("terminal:size"),
  terminalId: z.string(),
  cols: z.number().int().positive(),
  rows: z.number().int().positive(),
  // The clientId whose resize the PTY currently follows. A client renders
  // natively when this equals its own id, else it renders this grid letterboxed
  // or horizontally scrolled.
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
  git: z.object({ branch: z.string() }).optional(),
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

// Port scanning & preview messages
const PortInfoSchema = z.object({
  port: z.number().int().positive(),
  pid: z.number().optional(),
  processName: z.string().optional(),
  label: z.string().optional(),
  // Detected dev-server scheme (from terminal-output URL sightings). Absent
  // means unknown; consumers should fall back to http.
  scheme: z.enum(["http", "https"]).optional(),
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
      // Present when the project has an admitted relay data-plane stream: the
      // phone binds its ProjectSession services to this streamId without a fresh
      // project:start. Absent for a stopped/unpromoted project.
      streamId: z.string().optional(),
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
      path: z.string(),
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

// Outbound agent→app, control plane only: announces the streamId a phone binds
// its ProjectSession services to for `projectId`. Sent when a
// project's relay data-plane stream is admitted; also carried per-project in the
// `agent:projects` advertisement so a reconnecting phone can bind without a
// fresh project:start. E2E-opaque to the relay. No inbound switch case.
const StreamReadyMessage = BaseMessage.extend({
  type: z.literal("stream-ready"),
  projectId: z.string(),
  streamId: z.string(),
});

// Outbound agent→app, control plane only: the phone addressed a streamId this
// host process holds no stream for — almost always a host restart, whose fresh
// process re-attaches every project under newly random ids (stream-mux.ts). The
// old id is dead forever, so without this the phone replays onto it and every
// verb times out with no signal to renegotiate. The phone answers by re-driving
// `project:start` for the project it had bound to `streamId`. E2E-opaque to the
// relay. No inbound switch case.
const StreamInvalidMessage = BaseMessage.extend({
  type: z.literal("stream-invalid"),
  streamId: z.string(),
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

export const NotificationTypeSchema = z.enum(["task_complete", "permission_request", "awaiting_input", "idle", "error"]);
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
// with this before arming. `notifyOnly` is why it re-parses everything rather
// than the one field it acts on — arriving absent it would read as falsy and
// silently run an auto-injecting session the user asked to be notify-only.
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
  notifyOnly: z.boolean(),
  // Per-SESSION judge choice, persisted in the terminal's handler-session
  // record by arm(). Empty string = clear back to default (the session's own
  // tool / CLI default model); absent = leave the stored choice untouched.
  judgeTool: z.string().optional(),
  judgeModel: z.string().optional(),
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
// phone (or one preset chip), and a cross-field precondition would put a form in
// front of it.
export const HandlerInstructWire = z.object({
  terminalId: z.string(),
  // Untrusted remote text that ends up interpolated into the extraction prompt.
  // Extraction truncates for prompt budget; the cap is here so an absurd payload
  // is refused at the wire instead of being carried that far.
  text: z.string().max(10_000),
});

const HandlerInstructMessage = BaseMessage.extend({
  type: z.literal("handler:instruct"),
  projectId: z.string(),
}).extend(HandlerInstructWire.shape);

// One tap-to-answer option on a quick-choice escalation (§4.6). `text` is sent as
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
  label: z.string().min(1).max(40),
  text: z.string().min(1).max(400).regex(/^[^\x00-\x1f\x7f]+$/).refine((t) => t.trim().length > 0),
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
  // "guard_blocked" = a REPORT that a harness guard (reply shape, the §5.3 hard
  // floor, the runaway guard) refused an action Handler wanted to take. A typed
  // line does not answer it — the action was never taken — so only
  // `handler:dismiss` retires one, and the bridge never mints `choices` for it:
  // this row exists BECAUSE a guard refused this exact text, and a one-tap that
  // re-sent it would be the thinnest human in the loop there is.
  kind: z.enum(["reply", "resolve_in_session", "guard_blocked"]).optional(),
  // §4.6 quick choices, optional exactly the way `kind` is: absent means "free-text
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
});

// One §5.2 snapshot, as the app sees it. Shared by the one-shot advert and the
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

// One-tap undo of a snapshot the bridge advertised. Payload-only schema for the
// same reason as HandlerConfigureWire: parseMessageFast admits it on the
// discriminator alone, so agent-core re-parses with this before anything runs.
//
// No terminalId: the id names the entry, and the entry carries its own session
// and project path. Undo is deliberately NOT gated on authorization (§5.4) —
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

const HandlerSessionSnapshot = z.object({
  terminalId: z.string(),
  notifyOnly: z.boolean(),
  state: z.enum(["watching", "handling", "needs_you", "parked"]),
  pendingEscalations: z.number().int().nonnegative(),
  armedAt: z.number(),
  goal: z.string(),
  backlog: BacklogWire,
  escalations: z.array(OpenEscalationWire),
  // Why the session is parked and when it wakes (epoch ms), for the countdown
  // chip. Present only while state is "parked".
  parkKind: z.enum(["limit", "outage"]).optional(),
  parkedUntil: z.number().optional(),
  // Per-session judge choice (absent = session default tool / CLI default model).
  judgeTool: z.string().optional(),
  judgeModel: z.string().optional(),
  // How much of the Handler this session can actually get, so the app can tell
  // "cannot report at all" from "armed and quiet" (HandlerObservability in
  // handler/engine.ts). Optional and appended LAST: an older app still parses
  // the snapshot, and every key it reads keeps its position.
  observability: z.enum(["full", "escalate_only", "unsupported"]).optional(),
});

const HandlerStatusMessage = BaseMessage.extend({
  type: z.literal("handler:status"),
  projectId: z.string(),
  // What an absent per-session judgeTool resolves to for PTY slots (the
  // project agent tool) — chat slots resolve from their own SessionEntry.tool
  // app-side. Judge overrides themselves are per-session (see snapshot).
  defaultTool: z.string().optional(),
  // Project default seeding a newly armed session's notify-only (config v2).
  defaultNotifyOnly: z.boolean(),
  sessions: z.array(HandlerSessionSnapshot),
  // Every snapshot this project still knows about, replayed for the same reason
  // escalations are: an app that restarted between the advert and the tap would
  // otherwise have no way to reach the undo. Not nested under a session — the
  // sessions array holds only ARMED sessions, and a wrapped-up one is exactly
  // when the offer matters most.
  snapshots: z.array(HandlerSnapshotWire),
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
  // "item_resolved": a skip is as consequential as a completion (spec §4.3), so
  // the feed distinguishes them without parsing the reason text.
  decision: z.enum([
    "continue", "handle", "escalate",
    "armed", "goal_edited",
    "item_done", "item_blocked", "item_skipped", "item_failed",
    "instruction_dropped", "floor_warning", "evidence_rejected",
    "wrapped_up", "parked", "resumed",
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
// stands up a RelayClient with them and responds with the lifecycle messages
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
    path: z.string(),
  })),
  ...CheckoutScoped,
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

const FileTreeSnapshotRequestMessage = BaseMessage.extend({
  type: z.literal("file:tree:snapshot:request"),
  ...CheckoutScoped,
});

const FileTreeSnapshotMessage = BaseMessage.extend({
  type: z.literal("file:tree:snapshot"),
  tree: FileTreeNodeSchema,
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
const AgentErrorSchema = z.object({
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

const ToolContentSchema = z.discriminatedUnion("type", [
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

const AgentItemSchema = z.object({
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

const AgentUsageSchema = z.object({
  inputTokens: z.number().optional(),
  outputTokens: z.number().optional(),
  cacheReadTokens: z.number().optional(),
  cacheWriteTokens: z.number().optional(),
  reasoningTokens: z.number().optional(),
  totalTokens: z.number().optional(),
  costUsd: z.number().optional(),
});

const AgentTurnStartMessage = BaseMessage.extend({
  type: z.literal("agent:turn-start"),
  sessionId: z.string(),
  turnId: z.string(),
});

const AgentSessionResetMessage = BaseMessage.extend({
  type: z.literal("agent:session-reset"),
  sessionId: z.string(),
});

const AgentTurnEndMessage = BaseMessage.extend({
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
const AgentTranscriptReplayMessage = BaseMessage.extend({
  type: z.literal("agent:transcript-replay"),
  sessionId: z.string(),
  frames: z.array(z.record(z.string(), z.unknown())),
});

const AgentItemAddedMessage = BaseMessage.extend({
  type: z.literal("agent:item-added"),
  sessionId: z.string(),
  turnId: z.string(),
  itemId: z.string(),
  parentItemId: z.string().optional(),
  item: AgentItemSchema,
});

const AgentItemDeltaMessage = BaseMessage.extend({
  type: z.literal("agent:item-delta"),
  sessionId: z.string(),
  turnId: z.string(),
  itemId: z.string(),
  textChunk: z.string(),
});

const AgentItemUpdatedMessage = BaseMessage.extend({
  type: z.literal("agent:item-updated"),
  sessionId: z.string(),
  turnId: z.string(),
  itemId: z.string(),
  item: AgentItemSchema,
});

const AgentSnapshotMessage = BaseMessage.extend({
  type: z.literal("agent:snapshot"),
  sessionId: z.string(),
  turnId: z.string(),
  items: z.array(AgentItemSchema),
});

const AgentCapabilitiesMessage = BaseMessage.extend({
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
const AgentUpdateAvailableMessage = BaseMessage.extend({
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
const AgentUpdateMessage = BaseMessage.extend({
  type: z.literal("agent:update"),
  tool: z.string(),
  sessionId: z.string().optional(),
});

// Agent -> app: terminal outcome of an agent:update run. `installed` is the
// re-probed version after a successful update; `output` is a bounded tail of the
// updater's combined stdout+stderr, surfaced on failure.
const AgentUpdateResultMessage = BaseMessage.extend({
  type: z.literal("agent:updateResult"),
  tool: z.string(),
  sessionId: z.string().optional(),
  ok: z.boolean(),
  exitCode: z.number().optional(),
  installed: z.string().optional(),
  output: z.string().optional(),
});

const AgentPermissionRequestMessage = BaseMessage.extend({
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

const AgentQuestionMessage = BaseMessage.extend({
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
const AgentRequestRetractedMessage = BaseMessage.extend({
  type: z.literal("agent:request-retracted"),
  sessionId: z.string(),
  permissionId: z.string().optional(),
  questionId: z.string().optional(),
});

const AgentErrorMessage = BaseMessage.extend({
  type: z.literal("agent:error"),
  sessionId: z.string(),
  turnId: z.string().optional(),
  error: AgentErrorSchema,
});

// Cumulative token usage for the session. Carried as its own low-frequency
// message (not on turn-end) because codex reports usage via a thread-level
// stream (thread/tokenUsage/updated) decoupled from turn boundaries.
const AgentUsageMessage = BaseMessage.extend({
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
const AgentBackgroundTaskSchema = z.object({
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

const AgentBackgroundTasksMessage = BaseMessage.extend({
  type: z.literal("agent:background-tasks"),
  sessionId: z.string(),
  tasks: z.array(AgentBackgroundTaskSchema),
});

// App -> agent: stop one background task. Routed to the driver's stopTask
// (claude Query.stopTask / codex thread/backgroundTerminals/terminate).
const AgentTaskStopMessage = BaseMessage.extend({
  type: z.literal("agent:task-stop"),
  sessionId: z.string(),
  taskId: z.string(),
});

// ── Inbound app→agent control-plane messages ──────────────────────────────────
// These carry the app's intent into the active agent session. sessionId scopes
// each message to one running agent session (not the project). requestId on
// agent:prompt ties the turn to the app's send action for correlation.

const AgentPromptMessage = BaseMessage.extend({
  type: z.literal("agent:prompt"),
  sessionId: z.string(),
  requestId: z.string(),
  text: z.string(),
  commandId: z.string().optional(), // present => slash command invocation
});

const AgentCancelMessage = BaseMessage.extend({
  type: z.literal("agent:cancel"),
  sessionId: z.string(),
  turnId: z.string().optional(),
});

const AgentSetConfigMessage = BaseMessage.extend({
  type: z.literal("agent:set-config"),
  sessionId: z.string(),
  key: z.string(),
  value: z.unknown(),
});

const AgentSessionActionMessage = BaseMessage.extend({
  type: z.literal("agent:session-action"),
  sessionId: z.string(),
  action: z.enum(["compact", "revert"]),
  turnId: z.string().optional(),
  itemId: z.string().optional(),
  messageId: z.string().optional(),
  partId: z.string().optional(),
});

const AgentPermissionResolveMessage = BaseMessage.extend({
  type: z.literal("agent:permission-resolve"),
  sessionId: z.string(),
  permissionId: z.string(),
  optionId: z.string(),
});

const AgentQuestionResolveMessage = BaseMessage.extend({
  type: z.literal("agent:question-resolve"),
  sessionId: z.string(),
  questionId: z.string(),
  answer: z.union([z.string(), z.array(z.string())]),
});

export const AbMessageSchema = z.discriminatedUnion("type", [
  AgentHelloMessage,
  PortDetectedMessage,
  TerminalOutputMessage,
  TerminalInputMessage,
  TerminalStartedMessage,
  TerminalExitedMessage,
  TerminalNotificationMessage,
  TerminalStartCommand,
  TerminalStopCommand,
  TerminalResizeCommand,
  TerminalSizeMessage,
  AgentStatusMessage,
  PingMessage,
  PongMessage,
  HandshakeClientHelloMessage,
  HandshakeAgentHelloMessage,
  HandshakeAgentReadyMessage,
  TreeFullMessage,
  TreeUpdateMessage,
  FileReadMessage,
  FileContentMessage,
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
  StreamInvalidMessage,
  ControlResultMessage,
  AppReadyMessage,
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
  FileTreeSnapshotRequestMessage,
  FileTreeSnapshotMessage,
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
]);

export type AbMessage = z.infer<typeof AbMessageSchema>;

export type TerminalNotificationMessage = z.infer<typeof TerminalNotificationMessage>;

export type TerminalOutput = z.infer<typeof TerminalOutputMessage>;
export type TerminalInput = z.infer<typeof TerminalInputMessage>;
export type TerminalStarted = z.infer<typeof TerminalStartedMessage>;
export type TerminalExited = z.infer<typeof TerminalExitedMessage>;
export type HandshakeClientHello = z.infer<typeof HandshakeClientHelloMessage>;
export type HandshakeAgentHello = z.infer<typeof HandshakeAgentHelloMessage>;
export type HandshakeAgentReady = z.infer<typeof HandshakeAgentReadyMessage>;
export type TerminalStart = z.infer<typeof TerminalStartCommand>;
export type TerminalStop = z.infer<typeof TerminalStopCommand>;
export type TerminalResize = z.infer<typeof TerminalResizeCommand>;
export type TerminalSize = z.infer<typeof TerminalSizeMessage>;
export type AgentStatus = z.infer<typeof AgentStatusMessage>;
export type TreeFull = z.infer<typeof TreeFullMessage>;
export type TreeUpdate = z.infer<typeof TreeUpdateMessage>;
export type FileRead = z.infer<typeof FileReadMessage>;
export type FileContent = z.infer<typeof FileContentMessage>;
export type PortInfo = z.infer<typeof PortInfoSchema>;
export type PortsUpdate = z.infer<typeof PortsUpdateMessage>;
export type PreviewUrl = z.infer<typeof PreviewUrlMessage>;
export type AgentDisconnecting = z.infer<typeof AgentDisconnectingMessage>;
export type AgentProjects = z.infer<typeof AgentProjectsMessage>;
export type ProjectAdvertEntry = AgentProjects["projects"][number];
export type AgentTools = z.infer<typeof AgentToolsMessage>;
export type StreamReady = z.infer<typeof StreamReadyMessage>;
export type StreamInvalid = z.infer<typeof StreamInvalidMessage>;
export type ControlResult = z.infer<typeof ControlResultMessage>;
export type AppReady = z.infer<typeof AppReadyMessage>;
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
export type HandlerEscalationMsg = z.infer<typeof HandlerEscalationMessage>;
export type HandlerActivityMsg = z.infer<typeof HandlerActivityMessage>;
export type HandlerSnapshotMsg = z.infer<typeof HandlerSnapshotMessage>;
export type HandlerUndoMsg = z.infer<typeof HandlerUndoMessage>;
export type HandlerDismissMsg = z.infer<typeof HandlerDismissMessage>;
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
export type FileTreeSnapshotRequest = z.infer<typeof FileTreeSnapshotRequestMessage>;
export type FileTreeSnapshot = z.infer<typeof FileTreeSnapshotMessage>;
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

/** The exhaustive checkout-variable protocol set. Any new filesystem-facing
 * type belongs here (and gets an explicit schema decision + contract test). */
export const CHECKOUT_VARIABLE_MESSAGE_TYPES = new Set<string>([
  "terminal:start", "terminal:stop", "terminal:input", "terminal:resize", "terminal:output", "terminal:started", "terminal:exited", "terminal:notification", "terminal:size",
  "terminal:snapshot:request", "terminal:snapshot",
  "agent:status",
  "tree:full", "tree:update", "file:read", "file:content",
  "file:search", "file:search-cancel", "file:search-result", "file:search-done",
  "file:upload-start", "file:upload-ready", "file:upload-chunk", "file:upload-ack", "file:upload-done", "file:upload-result",
  "git:status", "git:diff", "git:diff-content", "git:list-branches", "git:branches", "git:checkout", "git:checkout-result",
  "git:commit", "git:commit-result", "git:discard", "git:discard-result",
  "git:stage", "git:stage-result", "git:unstage", "git:unstage-result",
  "command:run", "command:output", "command:done",
  "config:read", "config:read-result", "config:write", "config:write-result", "config:changed", "config:detect-tools", "config:detect-tools-result",
  "ports:update", "port:detected", "preview:url", "file:tree:snapshot:request", "file:tree:snapshot", "preview:snapshot:request", "preview:snapshot",
  "session:result", "control:result",
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
  "terminal:output", "terminal:input", "terminal:started", "terminal:exited", "terminal:notification",
  "terminal:start", "terminal:stop", "terminal:resize", "terminal:size", "agent:status",
  "ping", "pong", "handshake:client-hello", "handshake:agent-hello", "handshake:agent-ready",
  "tree:full", "tree:update", "file:read", "file:content",
  "ports:update", "preview:url",
  "agent:disconnecting", "agent:projects", "agent:tools", "stream-ready", "stream-invalid", "control:result", "app:ready",
  "command:run", "command:output", "command:done", "notification:push", "push:register",
  "handler:configure", "handler:instruct", "handler:status", "handler:escalation", "handler:activity",
  "handler:snapshot", "handler:undo", "handler:dismiss",
  "git:status", "git:diff", "git:diff-content",
  "git:list-branches", "git:branches", "git:checkout", "git:checkout-result",
  "git:commit", "git:commit-result", "git:discard", "git:discard-result",
  "git:stage", "git:stage-result", "git:unstage", "git:unstage-result",
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
  "file:tree:snapshot:request", "file:tree:snapshot",
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
