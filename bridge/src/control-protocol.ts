import { z } from "zod";
import type { AgentDescriptor } from "./protocol";

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
  z.object({
    id: z.string().min(1),
    type: z.literal("git:branches"),
    projectId: z.string().min(1),
    projectPath: z.string().min(1),
  }),
  z.object({
    id: z.string().min(1),
    type: z.literal("git:checkout"),
    projectId: z.string().min(1),
    projectPath: z.string().min(1),
    branch: z.string().min(1),
    allowActiveSessions: z.boolean().optional(),
  }),
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
  | { id: string; ok: true; type: "project:resolve"; projectId: string; repoPath: string; selectedPath: string; label: string; isGitRepository: boolean }
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
  | { id: string; ok: true; type: "git:branches"; isRepository: boolean; current: string | null; branches: string[]; worktreeSessionsSupported: boolean }
  | { id: string; ok: true; type: "git:checkout"; current: string }
  | { id: string; ok: true; type: "checkout:path"; path: string }
  | { id: string; ok: false; error: { code: string; message: string } };
