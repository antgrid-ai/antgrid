import { z } from "zod";
import type { AgentDescriptor } from "./protocol";
import type { BranchRemoteStatus, StashEntry } from "./git-branches";
import { MAX_CAPABILITY_CARD_PROJECTS, type OsCard, type RepoCard } from "./capability-card";
import { MAX_REMOTE_DIRECTORY_WIRE_MACHINES, MAX_REMOTE_DIRECTORY_WIRE_ROWS } from "./session-bus/constants";

export const ControlRequestSchema = z.discriminatedUnion("type", [
  z.object({ id: z.string().min(1), type: z.literal("project:list") }),
  z.object({ id: z.string().min(1), type: z.literal("project:resolve"), folder: z.string().min(1) }),
  z.object({ id: z.string().min(1), type: z.literal("tools:list") }),
  z.object({
    id: z.string().min(1),
    type: z.literal("project:open"),
    projectId: z.string().min(1),
    projectPath: z.string().min(1),
    mode: z.enum(["local", "remote"]),
  }),
  z.object({ id: z.string().min(1), type: z.literal("project:start"), projectId: z.string().min(1) }),
  z.object({ id: z.string().min(1), type: z.literal("project:stop"), projectId: z.string().min(1) }),
  z.object({ id: z.string().min(1), type: z.literal("project:forget"), projectId: z.string().min(1) }),
  z.object({ id: z.string().min(1), type: z.literal("host:shutdown") }),
  z.object({ id: z.string().min(1), type: z.literal("phones:list") }),
  z.object({ id: z.string().min(1), type: z.literal("phones:unpair"), phonePubkey: z.string().min(1) }),
  z.object({ id: z.string().min(1), type: z.literal("mobile-access:get") }),
  z.object({ id: z.string().min(1), type: z.literal("mobile-access:set"), enabled: z.boolean() }),
  // Subordinate to `mobile-access` above, never a replacement for it: with
  // remote access off this bit grants nothing. See `agent-reach-policy.ts`.
  z.object({ id: z.string().min(1), type: z.literal("agent-reach:get") }),
  z.object({ id: z.string().min(1), type: z.literal("agent-reach:set"), enabled: z.boolean() }),
  // The machine half of the Capability Card over the LOOPBACK plane. The relay
  // plane already answers `machine.capability-card`, so without this the app
  // cannot read the NORMALISED remote of a project on its own machine — the key
  // the add-machine dialog matches a peer machine's projects against.
  //
  // Paths come from the caller, exactly as `git:branches` below takes them: the
  // desktop already holds its own projects' paths, so this needs neither the
  // seen-project catalog nor the remote-access gate that bound the relay-side
  // handler (loopback callers are exempt by design).
  z.object({
    id: z.string().min(1),
    type: z.literal("machine:capability-card"),
    projects: z
      .array(
        z.object({
          projectId: z.string().min(1),
          projectPath: z.string().min(1),
          label: z.string().optional(),
        }),
      )
      .max(MAX_CAPABILITY_CARD_PROJECTS),
  }),
  z.object({
    id: z.string().min(1),
    type: z.literal("git:branches"),
    projectId: z.string().min(1),
    projectPath: z.string().min(1),
  }),
  z.object({
    id: z.string().min(1),
    type: z.literal("git:remote-state"),
    projectId: z.string().min(1),
    projectPath: z.string().min(1),
    branch: z.string().min(1),
  }),
  z.object({
    id: z.string().min(1),
    type: z.literal("git:checkout"),
    projectId: z.string().min(1),
    projectPath: z.string().min(1),
    branch: z.string().min(1),
    allowActiveSessions: z.boolean().optional(),
    stashIfDirty: z.boolean().optional(),
  }),
  // Arms or disarms the CONNECTED app's own frame capture (`antgrid watch
  // --remote`). A phone has no env var and no UI for this, so the desktop's
  // loopback plane is the only control surface it has. Diagnostics only — it
  // moves no data and touches no project.
  z.object({
    id: z.string().min(1),
    type: z.literal("netwatch:remote"),
    enabled: z.boolean(),
    ttlMs: z.number().int().positive().optional(),
  }),
  // Arms or disarms BODY capture for the loopback frames THIS bridge records
  // (`antgrid watch --local`). Metadata is recorded unconditionally and no verb
  // can turn it off — only payloads are worth asking for, so this is the whole
  // switch. It is answered in-process: nothing is forwarded to the app, so it
  // adds no wire message type, and it neither reads nor writes a working tree,
  // so it needs no entry in CHECKOUT_VARIABLE_MESSAGE_TYPES either.
  z.object({
    id: z.string().min(1),
    type: z.literal("netwatch:local"),
    bodies: z.boolean(),
    // Optional for the reason netwatch:remote's is — a disarm has no window to
    // state — and zero is admitted here rather than refused, so a caller that
    // spells "off" as `{bodies: false, ttlMs: 0}` is answered instead of being
    // rejected over a field it was not arming with. Positivity is the arming
    // path's concern and is enforced there.
    ttlMs: z.number().int().nonnegative().optional(),
  }),
  // Mints a single-use launch ticket for the capture viewer and reports the URL
  // that spends it (`antgrid watch --ui`). The ticket is NOT this plane's
  // bearer: a browser sends no Authorization header on a navigation, so the
  // only channel to the page is a URL, and a URL outlives the tab in history
  // and in anything the operator pastes. What it buys is scoped to reading the
  // capture stream and arming capture — see netwatch-ui-session.ts.
  z.object({ id: z.string().min(1), type: z.literal("netwatch:ui") }),
  // Discloses a checkout's absolute path to the caller. Deliberately confined
  // to THIS plane: checkout paths are host-local (checkout-types.ts) and the
  // loopback socket + token is the only transport that can reach this schema —
  // the relay control plane speaks AbMessage verbs, not ControlRequest.
  z.object({
    id: z.string().min(1),
    type: z.literal("checkout:path"),
    projectId: z.string().min(1),
    checkoutId: z.string().min(1),
  }),
  // The asking half of the remote session directory: the app's pump hands
  // over what it learned peeking peer capability cards this cycle. Unlike
  // every verb above, this ONE is gated behind the remote-access switch at
  // the handler (host-server.ts) — the rest of this plane is exempt because a
  // loopback caller is this machine's own desktop asking about its own data;
  // this verb instead hands ANOTHER machine's session inventory into this
  // machine's agents' reach, which is precisely what the switch authorizes.
  // The gate is on the data's provenance, not on the caller.
  //
  // `rows` is deliberately `z.unknown()`, not `RemoteDirectoryRowSchema` — a
  // strict per-row schema here would 400 the WHOLE push over one hostile or
  // merely-too-long field (a renamed session title is enough), and the app
  // reads a BAD_REQUEST from this verb as "the local bridge predates it" and
  // latches the pump off. `RemoteDirectoryCache.replace()` is the real row
  // gate: it validates and sanitises each row itself and drops only the rows
  // that fail, never the push. The bounds below are a wire-layer DoS ceiling,
  // looser than the product caps `replace()` enforces — see
  // `MAX_REMOTE_DIRECTORY_WIRE_MACHINES`/`_ROWS` in session-bus/constants.ts.
  z.object({
    id: z.string().min(1),
    type: z.literal("session-bus:remote-directory"),
    machines: z
      .array(
        z.object({
          machineId: z.string().min(1).max(200),
          machineLabel: z.string().max(120).optional(),
          observedAt: z.number().int().nonnegative(),
          outcome: z.enum(["rows", "no-card", "refused", "reach-refused", "unreachable"]),
          rows: z.array(z.unknown()).max(MAX_REMOTE_DIRECTORY_WIRE_ROWS).default([]),
          truncated: z.number().int().min(0).default(0),
        }),
      )
      .max(MAX_REMOTE_DIRECTORY_WIRE_MACHINES),
    notConnected: z.number().int().min(0).default(0),
  }),
]);
export type ControlRequest = z.infer<typeof ControlRequestSchema>;

/** One catalog entry as advertised to a control-plane client. */
export interface ProjectSummary {
  projectId: string;
  path: string;
  running: boolean;
  mode: "local" | "remote";
  /** Live work status for warm cores. Absent until the first bus frame arrives. */
  workStatus?: string;
  /** Per-running-session status keyed by session id — the same per-session view
   *  the relay advert carries, so a LOCAL project's session rows dot themselves
   *  instead of inheriting the project rollup. Absent for a cold core. */
  sessionStatuses?: Record<string, string>;
}

/** One paired phone as surfaced to the desktop mobile-devices hub. Mirror of the
 *  PairedPhone shape in paired-phones.ts (decoupled so the control protocol
 *  doesn't import the store). */
export interface PairedPhoneSummary {
  phonePubkey: string;
  phoneDeviceId: string;
  label?: string;
  pairedAt: string;
  lastSeenAt: string;
}

/** One project the machine knows about (warm core or seen-catalog hint).
 *  `path`/`label` are absent for a hint recorded without them. */
export interface KnownProject {
  projectId: string;
  label?: string;
  path?: string;
  running: boolean;
  /** Seen-catalog recency, absent for a warm core with no catalog hint yet. */
  lastActiveAt?: string;
}

/** One installed tool as reported by the loopback control plane. PATH-scoped:
 *  what each agent IS, installed or not, rides the sibling `agents` descriptor
 *  array (AgentDescriptor in protocol.ts). */
export interface ToolSummary {
  tool: string;
  path: string;
  chatCapable: boolean;
  /** Display name from the registry. The app prefers this over its own table,
   *  so adding an agent names it everywhere without an app release. */
  label: string;
}

/** Loopback data-plane connect info (port + token). Non-null for all cores —
 *  both local and remote modes bind a loopback listener so the desktop can
 *  always open a project locally. */
export interface ConnectInfo {
  port: number;
  token: string;
}

export type ControlResponse =
  | { id: string; ok: true; type: "project:list"; projects: ProjectSummary[] }
  | {
      id: string; ok: true; type: "project:resolve"; projectId: string; repoPath: string;
      selectedPath: string; label: string; isGitRepository: boolean;
      kind: "primary" | "managed-checkout" | "linked-worktree" | "plain"; checkoutId?: string;
    }
  | { id: string; ok: true; type: "tools:list"; tools: ToolSummary[]; agents?: AgentDescriptor[] }
  | { id: string; ok: true; type: "project:open"; running: boolean; connect: ConnectInfo | null }
  | { id: string; ok: true; type: "project:start"; running: boolean; connect: ConnectInfo | null }
  | { id: string; ok: true; type: "project:stop" }
  | { id: string; ok: true; type: "project:forget" }
  | { id: string; ok: true; type: "host:shutdown" }
  | { id: string; ok: true; type: "phones:list"; phones: PairedPhoneSummary[]; knownProjects: KnownProject[] }
  | { id: string; ok: true; type: "phones:unpair" }
  | { id: string; ok: true; type: "mobile-access:get"; enabled: boolean }
  | { id: string; ok: true; type: "mobile-access:set"; enabled: boolean }
  | { id: string; ok: true; type: "agent-reach:get"; enabled: boolean }
  | { id: string; ok: true; type: "agent-reach:set"; enabled: boolean }
  | { id: string; ok: true; type: "machine:capability-card"; os: OsCard; projects: Record<string, RepoCard> }
  | { id: string; ok: true; type: "git:branches"; isRepository: boolean; current: string | null; branches: string[]; worktreeSessionsSupported: boolean }
  | { id: string; ok: true; type: "git:remote-state"; status: BranchRemoteStatus }
  | { id: string; ok: true; type: "git:checkout"; current: string; stashed?: StashEntry }
  | { id: string; ok: true; type: "checkout:path"; path: string }
  | {
      id: string; ok: true; type: "session-bus:remote-directory";
      accepted: number; dropped: number;
      wantedRepoKeys: string[]; unservedReads: number; lastReadAt: number | null;
    }
  /** `ttlMs` is the window actually armed, which is not always the one asked
   *  for (the host clamps), and `0`/absent while disarmed. A watcher heartbeats
   *  inside it, so echoing the request instead would let a clamped capture lapse
   *  under a re-arm that believed it was early. */
  | { id: string; ok: true; type: "netwatch:remote"; enabled: boolean; ttlMs?: number }
  | { id: string; ok: true; type: "netwatch:local"; bodies: boolean; ttlMs: number }
  /** `url` carries the ticket in its FRAGMENT, which no browser sends to a
   *  server and no proxy logs — the page reads it, spends it and strips it. */
  | { id: string; ok: true; type: "netwatch:ui"; url: string; expiresInMs: number }
  | { id: string; ok: false; error: { code: string; message: string } };
