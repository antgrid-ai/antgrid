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

export const AbConfigSchema = z.object({
  name: z.string().optional(),
  relayUrl: z.string().optional(),
  agent: AgentBlockSchema.optional(),
  services: z.array(ServiceSchema).optional(),
  commands: z.array(CommandSchema).optional(),
  ports: z.array(PortEntrySchema).optional(),
}).strict();

export type OnDetect = z.infer<typeof OnDetectSchema>;
export type AgentBlock = z.infer<typeof AgentBlockSchema>;
export type ServiceConfig = z.infer<typeof ServiceSchema>;
export type CommandConfig = z.infer<typeof CommandSchema>;
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
}

const DEFAULT_CONFIG: AbConfig = {};

function normalizePorts(raw: z.infer<typeof AbConfigSchema>["ports"]): PortConfig[] | undefined {
  if (!raw) return undefined;
  return raw.map((entry) => {
    if (typeof entry === "number") return { port: entry, onDetect: "notify" as const };
    return { port: entry.port, name: entry.name, onDetect: entry.onDetect ?? "notify" };
  });
}

export function resolveVariables(raw: string, context: { projectPath?: string }): string {
  return raw.replace(/\$\{([^}]+)\}/g, (match, expr: string) => {
    if (expr.startsWith("env.")) return process.env[expr.slice(4)] ?? match;
    if (expr === "project.path" && context.projectPath) return context.projectPath;
    return match;
  });
}

function resolveItem<T extends { workingDir?: string; command?: string; args?: string[]; env?: Record<string, string> }>(
  item: T, ctx: { projectPath?: string },
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

function resolveAll(cfg: AbConfig): AbConfig {
  const ctx = { projectPath: process.cwd() };
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
