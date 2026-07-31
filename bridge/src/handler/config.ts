// bridge/src/handler/config.ts
import { z } from "zod";
import { existsSync, mkdirSync, readFileSync, appendFileSync } from "node:fs";
import { join } from "node:path";

export const HandlerConfigSchema = z.object({
  version: z.literal(2),
  defaultNotifyOnly: z.boolean(),
});
export type HandlerConfig = z.infer<typeof HandlerConfigSchema>;

// v1 shape kept only to migrate old files; enabled/template are intentionally
// dropped — arming is per-session now (see spec §Protocol and persistence).
const HandlerConfigV1Schema = z.object({
  version: z.literal(1),
  enabled: z.boolean(),
  template: z.enum(["watchdog", "closer", "autopilot"]),
  model: z.string().optional(),
});

export const DEFAULT_HANDLER_CONFIG: HandlerConfig = { version: 2, defaultNotifyOnly: false };

export interface ActivityRecord {
  recordId: string;
  at: number;
  terminalId: string;
  // "parked"/"resumed" are lifecycle EVENTS, not verdicts about the supervised
  // work — they sit here beside the other non-decision kinds so the activity
  // feed can show why a session went quiet.
  decision: "continue" | "handle" | "escalate" | "brief_armed" | "brief_edited"
    | "item_satisfied" | "wrapped_up" | "parked" | "resumed";
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
    const raw = JSON.parse(readFileSync(path, "utf8"));
    const v2 = HandlerConfigSchema.safeParse(raw);
    if (v2.success) return v2.data;
    const v1 = HandlerConfigV1Schema.safeParse(raw);
    if (v1.success) return { version: 2, defaultNotifyOnly: false };
    return DEFAULT_HANDLER_CONFIG;
  } catch {
    return DEFAULT_HANDLER_CONFIG;
  }
}

export function appendActivity(abDir: string, projectId: string, rec: ActivityRecord): void {
  const dir = projectDir(abDir, projectId);
  mkdirSync(dir, { recursive: true });
  appendFileSync(join(dir, "handler-activity.jsonl"), `${JSON.stringify(rec)}\n`, "utf8");
}
