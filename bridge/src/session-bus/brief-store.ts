// The peer's durable copy of the brief it was created with.
//
// `SessionManager.pendingBrief` is a HANDOFF slot, cleared the moment the brief
// reaches the Handler — so by the time the first task arrives there is nothing
// left to restate the scope from. Spec 5.2 requires every task and every answer
// to restate it, which makes the brief a record this session keeps rather than a
// message it received once. Written on the way past, immediately before the
// pending slot is cleared, so a crash between the two costs a duplicate
// instruction and never the scope.
//
// Scope is resolved and stored ALONGSIDE the brief rather than re-derived per
// delivery: `declaredScope` is lexical, and a later edit to its patterns must
// not silently re-scope a task from a brief the human wrote months ago.

import { join } from "node:path";
import { z } from "zod";
import { SessionMemberOfSchema, type SessionMemberOf } from "../protocol";
import { MAX_BRIEF_CHARS, declaredScope, type ScopeLine } from "./delivery";
import { readStoreFile, sessionBusSessionDir, writeStoreFile } from "./store-fs";

export const BRIEF_STORE_VERSION = 1;

const ScopeLineSchema = z.object({
  label: z.enum(["Owns", "Must report", "May not"]),
  text: z.string().max(MAX_BRIEF_CHARS),
});

export const BriefFileSchema = z.object({
  version: z.literal(BRIEF_STORE_VERSION),
  lead: SessionMemberOfSchema,
  brief: z.string().max(MAX_BRIEF_CHARS),
  scope: z.array(ScopeLineSchema).max(3),
  storedAt: z.number(),
});
export type StoredBrief = z.infer<typeof BriefFileSchema>;

function briefPath(abDir: string, projectId: string, sessionId: string): string {
  return join(sessionBusSessionDir(abDir, projectId, sessionId), "brief.json");
}

export function saveBrief(
  abDir: string,
  projectId: string,
  sessionId: string,
  input: { lead: SessionMemberOf; brief: string; now: number },
): void {
  const dir = sessionBusSessionDir(abDir, projectId, sessionId);
  const brief = input.brief.slice(0, MAX_BRIEF_CHARS);
  const file: StoredBrief = {
    version: BRIEF_STORE_VERSION,
    lead: input.lead,
    brief,
    scope: declaredScope(brief),
    storedAt: input.now,
  };
  writeStoreFile(join(dir, "brief.json"), dir, file);
}

export function loadBrief(abDir: string, projectId: string, sessionId: string): StoredBrief | null {
  return readStoreFile<StoredBrief | null>(briefPath(abDir, projectId, sessionId), BriefFileSchema, null);
}

/** The scope a delivery restates, empty when the brief labelled nothing or no
 *  brief was ever stored. Empty is a rendering decision, not an error: a
 *  delivery with no scope block says less than one that promises a restatement
 *  it cannot carry. */
export function briefScope(abDir: string, projectId: string, sessionId: string): ScopeLine[] {
  return loadBrief(abDir, projectId, sessionId)?.scope ?? [];
}
