// bridge/src/handler/wrap-up-store.ts
//
// Where a wrap-up report lives after the session it describes is gone.
//
// Deliberately NOT the session record, for a sharper version of the reason
// snapshot-store gives: the wrap-up is what DISARMS the session, so the record it
// would ride on stops existing at the exact moment the report becomes worth
// reading. The push lands at 3am and is read at 9, by an app that may have
// restarted in between — and the activity feed cannot carry it, because the
// feed's jsonl is never read back and `handler:activity` is not replayed.
// Project-scoped rather than keyed by slot: a report outlives its session, and
// the slot it names may be armed on something else by the time it is read.

import { z } from "zod";
import { existsSync, mkdirSync, readFileSync, writeFileSync, renameSync, chmodSync } from "node:fs";
import { join } from "node:path";
import type { SummaryStatus, WrapUpRecord } from "./wrap-up";

const WRAPUP_STATUSES = ["done", "failed", "blocked", "skipped"] as const satisfies
  readonly SummaryStatus[];

// Hand-mirrored, and annotated for the same reason SnapshotEntrySchema is: on-disk
// storage must not be able to move what wrap-up.ts produces, so a field added or
// renamed there stops compiling here rather than rehydrating into a record the
// card cannot render.
const WrapUpRecordSchema: z.ZodType<WrapUpRecord> = z.object({
  wrapUpId: z.string(),
  terminalId: z.string(),
  at: z.number(),
  goal: z.string(),
  outcomes: z.array(z.object({
    status: z.enum(WRAPUP_STATUSES),
    // The true count the sampled `items` are drawn from, which is what makes
    // "+N more" recoverable from a record that stores no `more`.
    total: z.number().int().nonnegative(),
    items: z.array(z.string()),
  })),
  blockedTotal: z.number().int().nonnegative(),
  blockedReasons: z.array(z.string()),
});

const StoreSchema = z.object({
  version: z.literal(1),
  entries: z.array(WrapUpRecordSchema),
});

// Five, where the snapshot store keeps fifty: every record here is replayed IN
// FULL on `handler:status`, which is a REPLAY_TYPE emitted twice per handler
// event and encrypted across the relay to a phone (the frame budget is stated on
// HandlerWrapUpWire in ../protocol.ts). The oldest report is also the one least
// likely still to be wanted — nothing acts on a wrap-up, so ageing one out costs
// only the reading of it.
export const MAX_STORED_WRAPUPS = 5;

// No `dropped` half, unlike pruneSnapshots: a wrap-up pins no stash, backup ref
// or trash copy, so a dropped record owes no release and there is nothing to
// hand back.
export function pruneWrapUps(entries: WrapUpRecord[]): WrapUpRecord[] {
  return entries.length <= MAX_STORED_WRAPUPS ? entries : entries.slice(-MAX_STORED_WRAPUPS);
}

function storePath(abDir: string, projectId: string): string {
  return join(abDir, "agents", projectId, "handler-wrapups.json");
}

export function loadWrapUps(abDir: string, projectId: string): WrapUpRecord[] {
  const path = storePath(abDir, projectId);
  if (!existsSync(path)) return [];
  try {
    const parsed = StoreSchema.safeParse(JSON.parse(readFileSync(path, "utf8")));
    return parsed.success ? parsed.data.entries : [];
  } catch {
    return [];
  }
}

export function saveWrapUps(abDir: string, projectId: string, entries: WrapUpRecord[]): void {
  const path = storePath(abDir, projectId);
  mkdirSync(join(abDir, "agents", projectId), { recursive: true });
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, JSON.stringify({ version: 1, entries: pruneWrapUps(entries) }, null, 2), "utf8");
  renameSync(tmp, path);
  if (process.platform !== "win32") { try { chmodSync(path, 0o600); } catch { /* ignore */ } }
}
