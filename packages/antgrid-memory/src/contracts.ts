import { z } from "zod";

export const LIMITS = { content: 4096, applicability: 1024, record: 16384, query: 1024, response: 8192, excerpt: 512, exportPage: 256 * 1024, exportRecords: 64, exportCursor: 2048 } as const;
export const TASK_EXPIRY_MS = 30 * 24 * 60 * 60 * 1000;
export const bytes = (value: unknown): number => Buffer.byteLength(typeof value === "string" ? value : JSON.stringify(value), "utf8");

function boundedText(field: string, limit: number, nonempty = false) {
  return z.string().superRefine((value, ctx) => {
    const size = bytes(value);
    if (size > limit) ctx.addIssue({ code: "custom", message: `${field}: ${size} bytes exceeds ${limit} byte limit` });
    if (nonempty && !value.trim()) ctx.addIssue({ code: "custom", message: `${field} must contain text` });
  });
}

const id = z.string().min(1).max(256);
const exportCursor = boundedText("export cursor", LIMITS.exportCursor, true);
export const MemoryTypeSchema = z.enum(["preference", "task_state", "observation", "note"]);
export const MemoryScopeSchema = z.enum(["project", "task"]);
export const MemorySaveSchema = z.object({
  content: boundedText("content", LIMITS.content, true),
  memory_type: MemoryTypeSchema,
  scope: MemoryScopeSchema,
  applicability: boundedText("applicability", LIMITS.applicability).optional(),
  evidence: z.array(boundedText("evidence reference", LIMITS.record, true)).max(8).default([]),
  restrict_to_checkout: z.boolean().default(false),
  supersedes: id.optional(),
}).strict().superRefine((value, ctx) => {
  if (value.memory_type === "task_state" && value.scope !== "task") {
    ctx.addIssue({ code: "custom", message: "task_state requires task scope" });
  }
  if (value.restrict_to_checkout && value.scope !== "task") {
    ctx.addIssue({ code: "custom", message: "checkout restrictions require task scope" });
  }
});
export type MemorySave = z.infer<typeof MemorySaveSchema>;

export const MemoryRequestSchema = z.discriminatedUnion("op", [
  z.object({ op: z.literal("status") }).strict(),
  z.object({ op: z.literal("settings"), enabled: z.boolean().optional(), paused: z.boolean().optional(), project_paused: z.boolean().optional() }).strict(),
  z.object({ op: z.literal("search"), query: boundedText("query", LIMITS.query, true), limit: z.number().int().min(1).max(10).default(5) }).strict(),
  z.object({ op: z.literal("list"), history: z.boolean().default(false), offset: z.number().int().min(0).max(1_000_000).default(0) }).strict(),
  z.object({ op: z.literal("get"), id, history: z.boolean().default(false) }).strict(),
  z.object({ op: z.literal("prepare"), operation_key: id, save: MemorySaveSchema }).strict(),
  z.object({ op: z.literal("save"), operation_key: id, save: MemorySaveSchema }).strict(),
  z.object({ op: z.literal("recover") }).strict(),
  z.object({ op: z.literal("forget"), id }).strict(),
  z.object({ op: z.literal("export"), cursor: exportCursor.optional() }).strict(),
  z.object({ op: z.literal("repair") }).strict(),
]);
export type MemoryRequest = z.infer<typeof MemoryRequestSchema>;
// Wire messages carry the request as a plain record so their own schema stays
// a discriminated union; the memory issues are forwarded with their paths.
export const MemoryRequestRecordSchema = z.record(z.string(), z.unknown()).superRefine((value, context) => {
  const parsed = MemoryRequestSchema.safeParse(value);
  if (!parsed.success) for (const issue of parsed.error.issues) context.addIssue({ code: "custom", path: issue.path, message: issue.message });
});

export interface MemoryContext {
  owner_id: string;
  actor: "agent" | "app";
  project_id?: string;
  session_id?: string;
  checkout_id?: string;
  agent_id?: string;
  run_id?: string;
}
export const MemorySourceSchema = z.object({
  actor: z.enum(["agent", "app"]), project_id: id.optional(), session_id: id.optional(),
  checkout_id: id.optional(), agent_id: id.optional(),
});
export const MemoryRecordSchema = z.object({
  id, owner_id: id, content: z.string(), memory_type: MemoryTypeSchema, scope: MemoryScopeSchema,
  project_id: id, task_id: id.optional(), checkout_id: id.optional(),
  applicability: z.string().optional(), evidence: z.array(z.string()), source: MemorySourceSchema,
  supersedes: id.optional(), superseded_by: id.optional(), created_at: z.number(), updated_at: z.number(),
  lifecycle: z.enum(["active", "expired", "superseded"]),
});
export type MemoryRecord = z.infer<typeof MemoryRecordSchema>;
export const MemorySearchHitSchema = MemoryRecordSchema.pick({
  id: true, content: true, memory_type: true, scope: true, project_id: true, task_id: true,
  checkout_id: true, applicability: true, source: true, lifecycle: true,
}).extend({ excerpted: z.boolean() });
export type MemorySearchHit = z.infer<typeof MemorySearchHitSchema>;
const SaveResultSchema = z.object({ operation_key: id, id, outcome: z.enum(["saved", "already_present"]), lifecycle: z.enum(["active", "expired", "superseded"]) });
export const MemoryResultSchema = z.union([
  z.object({ available: z.literal(false), error: z.object({ code: z.string(), message: z.string() }) }),
  z.object({ available: z.boolean(), search_status: z.enum(["ready", "search_unavailable"]), enabled: z.boolean(), paused: z.boolean(), project_paused: z.boolean(), pending_operations: z.number(), failed_operations: z.number().optional(), recovery_status: z.enum(["ready", "cleanup_failed"]), error: z.object({ code: z.string(), message: z.string() }).optional() }),
  z.object({ results: z.array(z.union([MemoryRecordSchema, MemorySearchHitSchema])), has_more: z.boolean() }),
  z.object({ record: MemoryRecordSchema }),
  SaveResultSchema,
  z.object({ operation_key: id, state: z.enum(["pending", "resolved", "suppressed"]) }),
  z.object({ recovered: z.array(SaveResultSchema), pending_operations: z.number(), errors: z.array(z.object({ operation_key: id, code: z.string(), message: z.string() })).optional() }),
  z.object({ forgotten: z.boolean(), cleanup: z.literal("complete") }),
  z.object({ version: z.literal(1), owner_id: id, exported_at: z.number().int(), records: z.array(MemoryRecordSchema).max(LIMITS.exportRecords), next_cursor: exportCursor.nullable() }),
]);

export const MEMORY_OFF = "Antgrid Memory is turned off; the user can enable it in Antgrid settings";

export class MemoryError extends Error {
  constructor(readonly code: string, message: string) { super(message); this.name = "MemoryError"; }
}

// A mask is never longer than the secret it replaces, so redaction cannot push a
// save that passed the byte limits over them. Re-redacting a mask must leave it
// unchanged, because recovery redacts stored payloads a second time.
const mask = (secret: string): string => secret.length >= 10 ? "[REDACTED]" : "*".repeat(secret.length);

// Redaction precedes both canonical storage and the adapter's durable retry queue.
function redact(text: string): string {
  return text
    .replace(/-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?-----END [^-]*PRIVATE KEY-----/g, "[REDACTED PRIVATE KEY]")
    .replace(/\b(?:sk-[\w-]{16,}|gh[pousr]_[\w]{20,}|github_pat_[\w]{20,}|AKIA[A-Z0-9]{16})\b/g, "[REDACTED]")
    .replace(/\beyJ[\w-]{8,}\.[\w-]{8,}\.[\w-]{8,}\b/g, "[REDACTED]")
    .replace(/\b(Bearer\s+)([\w.+\/-]{8,}=*)/gi, (_, prefix: string, secret: string) => prefix + mask(secret))
    .replace(/\b((?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret)["']?\s*[:=]\s*["']?)([^\s"',;]+)/gi, (_, prefix: string, secret: string) => prefix + mask(secret))
    .replace(/(https?:\/\/)([^\s/@:]+:[^\s/@]+)@/gi, (_, scheme: string, secret: string) => `${scheme}${mask(secret)}@`);
}
export function redactSave(raw: unknown): MemorySave {
  const save = MemorySaveSchema.parse(raw);
  return { ...save, content: redact(save.content), ...(save.applicability === undefined ? {} : { applicability: redact(save.applicability) }), evidence: save.evidence.map(redact) };
}
