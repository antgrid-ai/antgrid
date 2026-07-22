// bridge/src/handler/config.ts
import { z } from "zod";
import { existsSync, mkdirSync, readFileSync, writeFileSync, renameSync, appendFileSync, chmodSync } from "node:fs";
import { join } from "node:path";

export const HandlerConfigSchema = z.object({
  version: z.literal(1),
  enabled: z.boolean(),
  template: z.enum(["watchdog", "closer", "autopilot"]),
  model: z.string().optional(),
});
export type HandlerConfig = z.infer<typeof HandlerConfigSchema>;

export const DEFAULT_HANDLER_CONFIG: HandlerConfig = {
  version: 1, enabled: false, template: "watchdog",
};

export interface ActivityRecord {
  recordId: string;
  at: number;
  terminalId: string;
  decision: "continue" | "handle" | "escalate";
  reason: string;
  detail?: string;
}

function projectDir(abDir: string, projectId: string): string {
  return join(abDir, "agents", projectId);
}

export function loadHandlerConfig(abDir: string, projectId: string): HandlerConfig {
  const path = join(projectDir(abDir, projectId), "handler-config.json");
  if (!existsSync(path)) return DEFAULT_HANDLER_CONFIG;
  try {
    const parsed = HandlerConfigSchema.safeParse(JSON.parse(readFileSync(path, "utf8")));
    return parsed.success ? parsed.data : DEFAULT_HANDLER_CONFIG;
  } catch {
    return DEFAULT_HANDLER_CONFIG;
  }
}

export function saveHandlerConfig(abDir: string, projectId: string, cfg: HandlerConfig): void {
  const dir = projectDir(abDir, projectId);
  mkdirSync(dir, { recursive: true });
  const path = join(dir, "handler-config.json");
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, JSON.stringify(cfg, null, 2), "utf8");
  renameSync(tmp, path);
  if (process.platform !== "win32") { try { chmodSync(path, 0o600); } catch { /* ignore */ } }
}

export function appendActivity(abDir: string, projectId: string, rec: ActivityRecord): void {
  const dir = projectDir(abDir, projectId);
  mkdirSync(dir, { recursive: true });
  appendFileSync(join(dir, "handler-activity.jsonl"), `${JSON.stringify(rec)}\n`, "utf8");
}
