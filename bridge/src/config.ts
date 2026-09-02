import { z, type ZodIssue } from "zod";
import { readFileSync, existsSync } from "node:fs";
import { join, basename } from "node:path";
import { parse as parseYaml } from "yaml";
import { logger } from "./logger";
const log = logger.child({ component: "config" });
import { resolveAbDir } from "./antgrid-dir";

export const AgentBlockSchema = z.object({
  tool: z.string().optional(),
  command: z.string().optional(),
  flags: z.array(z.string()).optional(),
  workingDir: z.string().optional(),
}).strict();

export const ServiceSchema = z.object({
  name: z.string(),
  command: z.string(),
  args: z.array(z.string()).optional(),
  workingDir: z.string().optional(),
  env: z.record(z.string(), z.string()).optional(),
  autoStart: z.boolean().optional(),
}).strict();

export const CommandSchema = z.object({
  name: z.string(),
  command: z.string(),
  args: z.array(z.string()).optional(),
  workingDir: z.string().optional(),
  env: z.record(z.string(), z.string()).optional(),
  confirm: z.boolean().optional(),
  description: z.string().optional(),
  icon: z.string().optional(),
}).strict();

export const OnDetectSchema = z.enum(["notify", "openPreview", "silent", "ignore"]);

export const PortEntrySchema = z.union([
  z.number().int().positive(),
  z.object({
    port: z.number().int().positive(),
    name: z.string().optional(),
    onDetect: OnDetectSchema.optional(),
  }).strict(),
]);

/** One provisioning step for a freshly cut managed worktree. `copy` and `run`
 *  are mutually exclusive so a step has exactly one meaning in the progress
 *  line; `name` is required because that line is the entire point of a named
 *  list. `copy` sources resolve against the main project path and land at the
 *  same relative path inside the checkout. */
export const WorktreeSetupStepSchema = z.object({
  name: z.string().min(1),
  copy: z.array(z.string()).optional(),
  run: z.string().optional(),
  workingDir: z.string().optional(),
  env: z.record(z.string(), z.string()).optional(),
}).strict().superRefine((value, ctx) => {
  if (value.copy && value.run) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["run"], message: "a step carries either copy or run, not both" });
  }
  if (!value.copy && !value.run) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["name"], message: "a step needs copy or run" });
  }
});

export const WorktreeSetupSchema = z.object({
  steps: z.array(WorktreeSetupStepSchema),
  /** Budget for the whole run, not per step. */
  timeoutMs: z.number().int().positive().optional(),
  /** `block` is reserved, not accepted: a setup that can wedge a session behind
   *  it needs an escape hatch the v1 UI does not have. */
  onFailure: z.enum(["warn"]).optional(),
  /** Whether this session's agent WAITS for the run.
   *
   *  `immediate` launches it alongside the first step, so it is live in a tree
   *  that is not provisioned yet — nothing orders the two PTYs, and a project
   *  whose first step copies `.env` in should expect the agent to beat it. That
   *  is why the default keeps the wait rather than inheriting it from how fast
   *  a given project's steps happen to be.
   *
   *  An enum rather than a boolean because the useful third answer is a step
   *  name ("clear the cheap prep, not the installs"), which widens this to a
   *  union without breaking the `.strict()` object around it. */
  startAgent: z.enum(["afterSetup", "immediate"]).default("afterSetup"),
}).strict();

export const WorktreeBlockSchema = z.object({
  setup: WorktreeSetupSchema.optional(),
}).strict();

export const AbConfigSchema = z.object({
  name: z.string().optional(),
  relayUrl: z.string().optional(),
  agent: AgentBlockSchema.optional(),
  services: z.array(ServiceSchema).optional(),
  commands: z.array(CommandSchema).optional(),
  ports: z.array(PortEntrySchema).optional(),
  worktree: WorktreeBlockSchema.optional(),
}).strict();

export type OnDetect = z.infer<typeof OnDetectSchema>;
export type AgentBlock = z.infer<typeof AgentBlockSchema>;
export type ServiceConfig = z.infer<typeof ServiceSchema>;
export type CommandConfig = z.infer<typeof CommandSchema>;
export type WorktreeSetupStep = z.infer<typeof WorktreeSetupStepSchema>;
export type WorktreeSetup = z.infer<typeof WorktreeSetupSchema>;
export type WorktreeBlock = z.infer<typeof WorktreeBlockSchema>;
export interface PortConfig {
  port: number;
  name?: string;
  onDetect: OnDetect;
}
export interface AbConfig {
  name?: string;
  relayUrl?: string;
  agent?: AgentBlock;
  services?: ServiceConfig[];
  commands?: CommandConfig[];
  ports?: PortConfig[];
  worktree?: WorktreeBlock;
}

const DEFAULT_CONFIG: AbConfig = {};

function normalizePorts(raw: z.infer<typeof AbConfigSchema>["ports"]): PortConfig[] | undefined {
  if (!raw) return undefined;
  return raw.map((entry) => {
    if (typeof entry === "number") return { port: entry, onDetect: "notify" as const };
    return { port: entry.port, name: entry.name, onDetect: entry.onDetect ?? "notify" };
  });
}

/** Everything a `${...}` reference can name. Only `projectPath` is known at
 *  config-load time; the checkout/session members are supplied by callers that
 *  resolve a value against a specific managed worktree, so an unset one leaves
 *  the reference untouched rather than interpolating a wrong path. */
export interface ResolveContext {
  projectPath?: string;
  checkoutPath?: string;
  checkoutBranch?: string;
  baseBranch?: string;
  sessionId?: string;
}

export function resolveVariables(raw: string, context: ResolveContext): string {
  return raw.replace(/\$\{([^}]+)\}/g, (match, expr: string) => {
    if (expr.startsWith("env.")) return process.env[expr.slice(4)] ?? match;
    if (expr === "project.path" && context.projectPath) return context.projectPath;
    if (expr === "checkout.path" && context.checkoutPath) return context.checkoutPath;
    if (expr === "checkout.branch" && context.checkoutBranch) return context.checkoutBranch;
    if (expr === "base.branch" && context.baseBranch) return context.baseBranch;
    if (expr === "session.id" && context.sessionId) return context.sessionId;
    return match;
  });
}

function resolveItem<T extends { workingDir?: string; command?: string; args?: string[]; env?: Record<string, string> }>(
  item: T, ctx: ResolveContext,
): T {
  const r = { ...item };
  if (r.workingDir) r.workingDir = resolveVariables(r.workingDir, ctx);
  if (r.command) r.command = resolveVariables(r.command, ctx);
  if (r.args) r.args = r.args.map((a) => resolveVariables(a, ctx));
  if (r.env) {
    r.env = Object.fromEntries(Object.entries(r.env).map(([k, v]) => [k, resolveVariables(v, ctx)]));
  }
  return r;
}

// `worktree` is deliberately absent from this pass: the context here is
// process.cwd(), which for a checkout's own antgrid.yaml is the MAIN project
// root, so eagerly interpolating a setup step would bake the wrong paths in.
// The setup runner resolves that block lazily against the real checkout.
function resolveAll(cfg: AbConfig): AbConfig {
  const ctx: ResolveContext = { projectPath: process.cwd() };
  return {
    ...cfg,
    services: cfg.services?.map((s) => resolveItem(s, ctx)),
    commands: cfg.commands?.map((c) => resolveItem(c, ctx)),
  };
}

export function loadConfig(configPath?: string, folder?: string): AbConfig {
  const filePath = configPath ?? findConfigFile(folder);
  if (!filePath || !existsSync(filePath)) {
    log.debug("No antgrid.yaml found, using defaults");
    return DEFAULT_CONFIG;
  }
  const raw = readFileSync(filePath, "utf8");
  const parsed = parseYaml(raw);
  if (parsed === null || parsed === undefined) return DEFAULT_CONFIG;
  const result = AbConfigSchema.safeParse(parsed);
  if (!result.success) {
    const errors = formatZodIssues(result.error.issues).join(", ");
    throw new Error(`Invalid antgrid.yaml: ${errors}`);
  }
  const normalized: AbConfig = {
    ...result.data,
    ports: normalizePorts(result.data.ports),
  };
  return resolveAll(normalized);
}

export function findConfigFile(folder?: string): string | null {
  const local = join(folder ?? process.cwd(), "antgrid.yaml");
  if (existsSync(local)) return local;
  const global = join(resolveAbDir(), "antgrid.yaml");
  if (existsSync(global)) return global;
  return null;
}

export function projectName(cfg: AbConfig, folder?: string): string {
  return cfg.name ?? (basename(folder ?? process.cwd()) || "project");
}

export function formatZodIssues(issues: ZodIssue[]): string[] {
  return issues.map((i) => `${i.path.join(".")}: ${i.message}`);
}
