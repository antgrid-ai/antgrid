// SPDX-License-Identifier: MPL-2.0

import { Database, type Statement } from "bun:sqlite";
import { createHash } from "node:crypto";
import { mkdtempSync, mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { z } from "zod";
import { LIMITS, MemoryRecordSchema, bytes, redactSave, type MemoryContext } from "../../src/contracts";
import { MemoryService } from "../../src/service";
import { MemoryStore, MEMORY_DATABASE } from "../../src/store";
import type { PublicDocument, PublicGroup, PublicQuery } from "./dataset-types";

export const VARIANTS = ["body", "equal", "weighted"] as const;
export type Variant = typeof VARIANTS[number];
const RANK = { body: "bm25()", equal: "bm25()", weighted: "bm25(0,1,1,4,2)" };
const NOW = Date.UTC(2026, 10, 10);
const OWNER = "00000000-0000-4000-8000-000000000001";
const PROJECT = "public-evaluation";
const ResultSchema = z.object({ results: z.array(z.object({ id: z.string() })), has_more: z.boolean() });
const digest = (input: string) => createHash("sha256").update(input).digest("hex");
export const stableRecordId = (id: string) => {
  const hash = digest(id);
  return `${hash.slice(0, 8)}-${hash.slice(8, 12)}-${hash.slice(12, 16)}-${hash.slice(16, 20)}-${hash.slice(20, 32)}`;
};

/** Evaluation-only fixtures use stable IDs so equal ranks are reproducible. */
export class PublicIndex {
  readonly service: MemoryService;
  readonly sources = new Map<string, string[]>();
  private readonly db: Database;
  private readonly rankStatement: Statement;
  readonly context: MemoryContext = { owner_id: OWNER, actor: "agent", project_id: PROJECT, session_id: "evaluation-session", checkout_id: "evaluation-checkout", agent_id: "evaluation", run_id: "evaluation-run" };
  constructor(directory: string, documents: PublicDocument[], metadata: boolean) {
    const store = new MemoryStore(directory);
    try {
      store.query("UPDATE profile SET owner_id=?,enabled=1").run(OWNER);
      store.db.transaction(() => {
        const insert = store.query(`INSERT INTO records(id,owner_id,scope,project_id,memory_type,content,title,description,evidence,source,created_at,updated_at,match_hash)
          VALUES(?,?,'project',?,'note',?,?,?,?,?,?,?,?)`);
        for (const document of documents) {
          const id = stableRecordId(document.id);
          if (this.sources.has(id)) throw new Error(`Duplicate document id ${document.id}`);
          const save = redactSave({ content: document.content, ...(metadata && document.title ? { title: document.title } : {}),
            ...(metadata && document.description ? { description: document.description } : {}), scope: "project", memory_type: "note", evidence: [] });
          const source = { actor: "agent" as const, project_id: PROJECT, session_id: "evaluation-session", checkout_id: "evaluation-checkout", agent_id: "evaluation" };
          const record = MemoryRecordSchema.parse({ ...save, id, owner_id: OWNER, project_id: PROJECT, source, created_at: NOW, updated_at: NOW, lifecycle: "active" });
          if (bytes(record) > LIMITS.record) throw new Error(`Fixture record ${document.id} exceeds record limit`);
          insert.run(id, OWNER, PROJECT, save.content, save.title ?? null, save.description ?? null, "[]", JSON.stringify(source), NOW, NOW, digest(save.content));
          this.sources.set(id, document.sourceIds);
        }
      }).immediate();
    } finally { store.close(); }
    this.service = new MemoryService({ directory, now: () => NOW });
    this.db = new Database(join(directory, MEMORY_DATABASE));
    this.rankStatement = this.db.query("INSERT INTO memory_fts(memory_fts,rank) VALUES('rank',?)");
  }
  ranking(variant: Variant) { this.rankStatement.run(RANK[variant]); }
  async search(query: string, limit: number, raw = false) {
    return await this.service.execute({ ...this.context, actor: raw ? "app" : "agent" }, { op: "search", query, limit });
  }
  close() { this.rankStatement.finalize(); this.db.close(); this.service.close(); }
}

export function scoreRelevant(relevantIds: string[], retrieved: string[], sourceMap: Map<string, string[]>) {
  const expected = new Set(relevantIds);
  if (!expected.size) throw new Error("Unanswerable queries have no retrieval-recall denominator");
  const seen = new Set<string>();
  let first: number | null = null;
  let dcg = 0;
  const recalls: number[] = [];
  for (let i = 0; i < 10; i++) {
    const sources = retrieved[i] ? sourceMap.get(retrieved[i]!) : [];
    if (retrieved[i] && !sources) throw new Error(`Unknown retrieved record ${retrieved[i]}`);
    let newRelevant = false;
    for (const source of sources ?? []) if (expected.has(source) && !seen.has(source)) { seen.add(source); newRelevant = true; }
    if (newRelevant) { first ??= i + 1; dcg += 1 / Math.log2(i + 2); }
    recalls.push(seen.size / expected.size);
  }
  const idcg = Array.from({ length: Math.min(10, expected.size) }, (_, i) => 1 / Math.log2(i + 2)).reduce((a, b) => a + b, 0);
  return { mrr10: first === null ? 0 : 1 / first, coverage5: recalls[4]! > 0 ? 1 : 0, recall5: recalls[4]!, recall10: recalls[9]!, allEvidence5: recalls[4] === 1 ? 1 : 0, ndcg10: dcg / idcg };
}

export type QueryMeasurement = {
  group: string; id: string; category: string; variant: Variant; answerable: boolean; relevantCount: number;
  rawIds: string[]; deliveredIds: string[]; raw: ReturnType<typeof scoreRelevant> | null; delivered: ReturnType<typeof scoreRelevant> | null;
  latencyMs: number[]; responseBytes: number; envelopeBytes: number; error?: string;
};
export async function measureQuery(index: PublicIndex, group: string, query: PublicQuery, variant: Variant, rounds: number): Promise<QueryMeasurement> {
  const row: QueryMeasurement = { group, id: query.id, category: query.category, variant, answerable: !query.unanswerable && query.relevantIds.length > 0,
    relevantCount: query.relevantIds.length, rawIds: [], deliveredIds: [], raw: null, delivered: null, latencyMs: [], responseBytes: 0, envelopeBytes: 0 };
  try {
    const raw = ResultSchema.parse(await index.search(query.text, 10, true));
    row.rawIds = raw.results.map(result => result.id);
    await index.search(query.text, 5);
    for (let round = 0; round < rounds; round++) {
      const start = performance.now();
      const response = await index.search(query.text, 5);
      row.latencyMs.push(performance.now() - start);
      row.deliveredIds = ResultSchema.parse(response).results.map(result => result.id);
      row.responseBytes = bytes(response);
      row.envelopeBytes = bytes({ isError: false, content: [{ type: "text", text: JSON.stringify(response) }] }) + 256;
      if (row.envelopeBytes > LIMITS.response) throw new Error("Agent response exceeded MCP envelope budget");
    }
  } catch (error) {
    row.error = error instanceof Error ? error.message : String(error);
    row.deliveredIds = [];
  }
  if (row.answerable) {
    row.raw = scoreRelevant(query.relevantIds, row.rawIds, index.sources);
    row.delivered = scoreRelevant(query.relevantIds, row.deliveredIds, index.sources);
  }
  return row;
}

export async function evaluateGroups(groups: PublicGroup[], directory: string, rounds = 3) {
  mkdirSync(directory, { recursive: true });
  const rows: QueryMeasurement[] = [];
  for (let g = 0; g < groups.length; g++) {
    const group = groups[g]!;
    const temp = mkdtempSync(join(directory, "retrieval-"));
    let body: PublicIndex | undefined;
    let metadata: PublicIndex | undefined;
    try {
      body = new PublicIndex(join(temp, "body"), group.documents, false);
      metadata = new PublicIndex(join(temp, "metadata"), group.documents, true);
      for (let q = 0; q < group.queries.length; q++) {
        for (let v = 0; v < VARIANTS.length; v++) {
          const variant = VARIANTS[(v + q + g) % VARIANTS.length]!;
          const index = variant === "body" ? body : metadata;
          index.ranking(variant);
          rows.push(await measureQuery(index, group.id, group.queries[q]!, variant, rounds));
        }
      }
    } finally { metadata?.close(); body?.close(); rmSync(temp, { recursive: true, force: true }); }
    if (g % 25 === 0 || g === groups.length - 1) console.log(`Evaluated ${g + 1}/${groups.length} groups (${rows.length} query/variant pairs)`);
  }
  return rows;
}

export function summarize(rows: QueryMeasurement[]) {
  const eligible = rows.filter(row => row.answerable);
  if (!eligible.length) throw new Error("No answerable queries");
  const mean = (values: number[]) => values.reduce((a, b) => a + b, 0) / values.length;
  const times = rows.flatMap(row => row.latencyMs).sort((a, b) => a - b);
  const percentile = (p: number) => times.length ? times[Math.max(0, Math.ceil(p * times.length) - 1)]! : null;
  const quality = (key: "raw" | "delivered") => Object.fromEntries(Object.keys(eligible[0]![key]!).map(metric => [metric,
    mean(eligible.map(row => row[key]![metric as keyof ReturnType<typeof scoreRelevant>]))]));
  return { queries: rows.length, answerable: eligible.length, unanswerable: rows.length - eligible.length,
    errors: rows.filter(row => row.error).length, raw: quality("raw"), delivered: quality("delivered"),
    latencyMs: { p50: percentile(.5), p95: percentile(.95), samples: times.length },
    maxResponseBytes: Math.max(...rows.map(row => row.responseBytes)), maxEnvelopeBytes: Math.max(...rows.map(row => row.envelopeBytes)) };
}
