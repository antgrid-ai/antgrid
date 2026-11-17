// SPDX-License-Identifier: MPL-2.0

import { createHash, randomUUID } from "node:crypto";
import { createReadStream } from "node:fs";
import { mkdir, rename, rm, stat } from "node:fs/promises";
import { resolve } from "node:path";
import { z } from "zod";
import type { DatasetManifest, PublicDocument, PublicGroup } from "./dataset-types";

export const LONGMEMEVAL_SOURCE = {
  revision: "98d7416c24c778c2fee6e6f3006e7a073259d48f",
  sha256: "d6f21ea9d60a0d56f34a05b609c79c88a451d2ae03597821ea3d5a9678c3a442",
  bytes: 277383467,
  filename: "longmemeval_s_cleaned.json",
} as const;
export const LONGMEMEVAL_URL = `https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned/resolve/${LONGMEMEVAL_SOURCE.revision}/${LONGMEMEVAL_SOURCE.filename}`;
export const LONGMEMEVAL_MAX_BYTES = 16 * 1024;
export const LONGMEMEVAL_CHUNK_VERSION = "session-turn-utf8-v1";
export const DEFAULT_DATASET_DIRECTORY = resolve(import.meta.dir, "../../../../.tmp/memory-public-evaluation/datasets");

const TurnSchema = z.object({ role: z.enum(["user", "assistant"]), content: z.string() });
const InstanceSchema = z.object({
  question_id: z.string().min(1),
  question_type: z.string().min(1),
  question: z.string().min(1),
  answer: z.unknown(),
  question_date: z.string().min(1).max(128),
  haystack_session_ids: z.array(z.string().min(1)).min(1),
  haystack_dates: z.array(z.string().min(1).max(128)),
  haystack_sessions: z.array(z.array(TurnSchema).min(1)),
  answer_session_ids: z.array(z.string()),
});

export function utf8Parts(text: string, maxBytes: number): string[] {
  if (Buffer.byteLength(text) <= maxBytes) return [text];
  const parts: string[] = [];
  let part = "", bytes = 0;
  for (const point of text) {
    const size = Buffer.byteLength(point);
    if (bytes + size > maxBytes) { parts.push(part); part = ""; bytes = 0; }
    part += point; bytes += size;
  }
  if (part) parts.push(part);
  return parts;
}

function sessionDocuments(id: string, sourceId: string, date: string, turns: z.infer<typeof TurnSchema>[]): PublicDocument[] {
  const header = `Session date: ${date}\n\n`;
  const bodyBudget = LONGMEMEVAL_MAX_BYTES - Buffer.byteLength(header);
  const bodies: string[] = [];
  let body = "";
  const flush = () => { if (body) bodies.push(body); body = ""; };
  for (const turn of turns) {
    const label = `${turn.role}:\n`;
    const rendered = label + turn.content;
    const separator = body ? "\n\n" : "";
    if (Buffer.byteLength(body + separator + rendered) <= bodyBudget) {
      body += separator + rendered;
      continue;
    }
    flush();
    const parts = utf8Parts(turn.content, bodyBudget - Buffer.byteLength(label));
    for (let index = 0; index < parts.length; index++) {
      body = label + parts[index];
      if (index < parts.length - 1) flush();
    }
  }
  flush();
  return bodies.map((content, index) => ({
    id: `${id}-c${String(index).padStart(3, "0")}`,
    title: `Conversation on ${date}`,
    content: header + content,
    sourceIds: [sourceId],
  }));
}

export function parseLongMemEval(input: unknown): PublicGroup[] {
  if (!Array.isArray(input)) throw new Error("LongMemEval must be a JSON array");
  const questionIds = new Set<string>();
  return input.map((raw, groupIndex) => {
    const item = InstanceSchema.parse(raw);
    if (questionIds.has(item.question_id)) throw new Error(`Duplicate LongMemEval question: ${item.question_id}`);
    questionIds.add(item.question_id);
    const count = item.haystack_sessions.length;
    if (count !== item.haystack_dates.length || count !== item.haystack_session_ids.length) {
      throw new Error(`Unaligned LongMemEval sessions: ${item.question_id}`);
    }
    const id = `lme-${String(groupIndex).padStart(4, "0")}`;
    const occurrenceIds = item.haystack_session_ids.map((_original, index) => `${id}-s${String(index).padStart(3, "0")}`);
    const sourceMap = new Map<string, string>();
    // Upstream repeats some sessions at different dates; preserve occurrences without inventing extra source evidence.
    item.haystack_session_ids.forEach((original, index) => { if (!sourceMap.has(original)) sourceMap.set(original, occurrenceIds[index]); });
    const unanswerable = item.question_id.endsWith("_abs");
    const relevantIds = unanswerable ? [] : [...new Set(item.answer_session_ids.map(original => {
      const neutral = sourceMap.get(original);
      if (!neutral) throw new Error(`Unknown evidence session in ${item.question_id}`);
      return neutral;
    }))];
    if (!unanswerable && !relevantIds.length) throw new Error(`Missing evidence sessions in ${item.question_id}`);
    return {
      id,
      documents: item.haystack_sessions.flatMap((turns, index) => sessionDocuments(occurrenceIds[index], sourceMap.get(item.haystack_session_ids[index])!, item.haystack_dates[index], turns)),
      queries: [{
        id: item.question_id,
        text: item.question,
        questionDate: item.question_date,
        relevantIds,
        category: item.question_type,
        answer: item.answer,
        unanswerable,
      }],
    };
  });
}

export async function loadLongMemEval(path: string): Promise<PublicGroup[]> {
  return parseLongMemEval(await Bun.file(path).json());
}

async function verifySource(path: string): Promise<void> {
  const info = await stat(path);
  if (info.size !== LONGMEMEVAL_SOURCE.bytes) throw new Error(`LongMemEval byte count mismatch: ${info.size}`);
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  if (hash.digest("hex") !== LONGMEMEVAL_SOURCE.sha256) throw new Error("LongMemEval SHA256 mismatch");
}

export async function prepareLongMemEval(options: { directory?: string } = {}): Promise<{ groups: PublicGroup[]; manifest: DatasetManifest; datasetPath: string }> {
  const directory = resolve(options.directory ?? DEFAULT_DATASET_DIRECTORY);
  await mkdir(directory, { recursive: true });
  const datasetPath = resolve(directory, LONGMEMEVAL_SOURCE.filename);
  if (!(await Bun.file(datasetPath).exists())) {
    const temporaryPath = `${datasetPath}.${randomUUID()}.partial`;
    try {
      const response = await fetch(LONGMEMEVAL_URL, { signal: AbortSignal.timeout(10 * 60 * 1000) });
      if (!response.ok) throw new Error(`LongMemEval download failed: HTTP ${response.status}`);
      await Bun.write(temporaryPath, response);
      await verifySource(temporaryPath);
      await rename(temporaryPath, datasetPath);
    } finally { await rm(temporaryPath, { force: true }); }
  }
  await verifySource(datasetPath);
  const groups = await loadLongMemEval(datasetPath);
  if (groups.length !== 500) throw new Error(`Expected 500 LongMemEval-S groups, received ${groups.length}`);
  const queries = groups.flatMap(group => group.queries);
  const manifest: DatasetManifest = {
    dataset: "LongMemEval", variant: "S-cleaned", sourceUrl: LONGMEMEVAL_URL,
    revision: LONGMEMEVAL_SOURCE.revision, sha256: LONGMEMEVAL_SOURCE.sha256,
    sourceBytes: LONGMEMEVAL_SOURCE.bytes, preparedAt: new Date().toISOString(),
    groups: groups.length, documents: groups.reduce((total, group) => total + group.documents.length, 0),
    queries: queries.length, answerableQueries: queries.filter(query => !query.unanswerable).length,
    unanswerableQueries: queries.filter(query => query.unanswerable).length,
    chunking: { maxBytes: LONGMEMEVAL_MAX_BYTES, version: LONGMEMEVAL_CHUNK_VERSION },
  };
  await Bun.write(resolve(directory, "longmemeval-s-manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
  return { groups, manifest, datasetPath };
}

if (import.meta.main) {
  const { manifest, datasetPath } = await prepareLongMemEval();
  console.log(JSON.stringify({ datasetPath, manifest }, null, 2));
}
