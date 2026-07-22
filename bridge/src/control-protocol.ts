import { z } from "zod";

export const ControlRequestSchema = z.discriminatedUnion("type", [
  z.object({ id: z.string().min(1), type: z.literal("project:list") }),
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
  z.object({ id: z.string().min(1), type: z.literal("phones:allow"), phonePubkey: z.string().min(1), projectId: z.string().min(1) }),
  z.object({ id: z.string().min(1), type: z.literal("phones:deny"), phonePubkey: z.string().min(1), projectId: z.string().min(1) }),
  z.object({ id: z.string().min(1), type: z.literal("phones:unpair"), phonePubkey: z.string().min(1) }),
  z.object({ id: z.string().min(1), type: z.literal("mobile-access:get") }),
  z.object({ id: z.string().min(1), type: z.literal("mobile-access:enable-project"), projectId: z.string().min(1) }),
  z.object({ id: z.string().min(1), type: z.literal("mobile-access:disable-project"), projectId: z.string().min(1) }),
]);
export type ControlRequest = z.infer<typeof ControlRequestSchema>;

/** One catalog entry as advertised to a control-plane client. */
export interface ProjectSummary {
  projectId: string;
  path: string;
  running: boolean;
  mode: "local" | "remote";
}

/** One paired phone as surfaced to the desktop allowlist hub. Mirror of the
 *  PairedPhone shape in paired-phones.ts (decoupled so the control protocol
 *  doesn't import the store). */
export interface PairedPhoneSummary {
  phonePubkey: string;
  phoneDeviceId: string;
  label?: string;
  pairedAt: string;
  lastSeenAt: string;
  admission: "same-account" | "pair-code";
  allowedProjects: string[];
}

/** One project the machine knows about (warm core or seen-catalog hint),
 *  for the hub's column set. `path`/`label` absent only for ids known solely
 *  via a phone's allowlist. */
export interface KnownProject {
  projectId: string;
  label?: string;
  path?: string;
  running: boolean;
}

/** One installed tool as reported by the loopback control plane. */
export interface ToolSummary {
  tool: string;
  path: string;
  chatCapable: boolean;
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
  | { id: string; ok: true; type: "tools:list"; tools: ToolSummary[] }
  | { id: string; ok: true; type: "project:open"; running: boolean; connect: ConnectInfo | null }
  | { id: string; ok: true; type: "project:start"; running: boolean; connect: ConnectInfo | null }
  | { id: string; ok: true; type: "project:stop" }
  | { id: string; ok: true; type: "project:forget" }
  | { id: string; ok: true; type: "host:shutdown" }
  | { id: string; ok: true; type: "phones:list"; phones: PairedPhoneSummary[]; knownProjects: KnownProject[] }
  | { id: string; ok: true; type: "phones:allow" }
  | { id: string; ok: true; type: "phones:deny" }
  | { id: string; ok: true; type: "phones:unpair" }
  | { id: string; ok: true; type: "mobile-access:get"; projectIds: string[] }
  | { id: string; ok: true; type: "mobile-access:enable-project"; projectIds: string[] }
  | { id: string; ok: true; type: "mobile-access:disable-project"; projectIds: string[] }
  | { id: string; ok: false; error: { code: string; message: string } };
