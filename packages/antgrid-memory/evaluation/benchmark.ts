// SPDX-License-Identifier: MPL-2.0

import { Database, type Statement } from "bun:sqlite";
import { LIMITS, MemoryRecordSchema, bytes, type MemoryRecord } from "../src/contracts";
import { bodyExcerpt, ftsQuery, searchResponse } from "../src/search";
import { QUERIES, type EvaluationDocument, type EvaluationQuery } from "./fixtures";

export type Ranking = "equal" | "weighted";
export const RANKING_SQL = { equal: "bm25()", weighted: "bm25(0,1,1,4,2)" } as const;
const NOW = Date.UTC(2026, 10, 10);
const OWNER = "synthetic-owner";
const PROJECT = "synthetic-project";
const toRecord = (document: EvaluationDocument): MemoryRecord => MemoryRecordSchema.parse({
  ...document, owner_id: OWNER, project_id: PROJECT, scope: "project", memory_type: "note", evidence: [],
  source: { actor: "agent", agent_id: "synthetic", project_id: PROJECT, session_id: "fixture-session", checkout_id: "main" },
  created_at: NOW, updated_at: NOW, lifecycle: "active",
});

export class EvaluationIndex {
  private readonly db: Database;
  private readonly statements = new Map<string, Statement>();
  readonly size: { database_bytes: number; fts_bytes: number; fts_measurement: string; build_ms: number; canonical_json_bytes: number };
  constructor(path: string, documents: EvaluationDocument[], metadata = true) {
    const started = performance.now();
    this.db = new Database(path, { create: true });
    try {
      this.db.exec(`
        PRAGMA journal_mode=WAL;
        CREATE TABLE records(seq INTEGER PRIMARY KEY, id TEXT UNIQUE NOT NULL, owner_id TEXT NOT NULL,
          project_id TEXT NOT NULL, scope TEXT NOT NULL, task_id TEXT, checkout_id TEXT,
          memory_type TEXT NOT NULL, superseded_by TEXT, updated_at INTEGER NOT NULL, payload TEXT NOT NULL);
        CREATE INDEX records_scope ON records(owner_id,project_id,task_id);
      `);
      const records = documents.map(toRecord);
      this.db.transaction(() => {
        const insert = this.statement("INSERT INTO records VALUES(?,?,?,?,?,NULL,NULL,?,NULL,?,?)");
        records.forEach((record, index) => insert.run(index + 1, record.id, OWNER, PROJECT, record.scope, record.memory_type, NOW, JSON.stringify(record)));
      }).immediate();
      const canonicalPages = this.pageBytes();
      this.db.exec(`CREATE VIRTUAL TABLE memory_fts USING fts5(id UNINDEXED,content,applicability${metadata ? ",title,description" : ""},tokenize='unicode61');`);
      this.db.transaction(() => {
        const insert = this.statement(metadata
          ? "INSERT INTO memory_fts(rowid,id,content,applicability,title,description) VALUES(?,?,?,?,?,?)"
          : "INSERT INTO memory_fts(rowid,id,content,applicability) VALUES(?,?,?,?)");
        documents.forEach((record, index) => insert.run(index + 1, record.id, record.content, record.applicability ?? null, ...(metadata ? [record.title ?? null, record.description ?? null] : [])));
      }).immediate();
      this.db.exec("INSERT INTO memory_fts(memory_fts) VALUES('optimize'); PRAGMA wal_checkpoint(TRUNCATE);");
      let ftsBytes: number;
      let method: string;
      try {
        ftsBytes = (this.statement("SELECT sum(pgsize) AS size FROM dbstat WHERE name GLOB 'memory_fts_*'").get() as { size: number }).size;
        method = "dbstat shadow-table pages";
      } catch {
        ftsBytes = this.pageBytes() - canonicalPages;
        method = "allocated page delta after FTS creation (includes free pages)";
      }
      this.size = { database_bytes: this.pageBytes(), fts_bytes: ftsBytes, fts_measurement: method, build_ms: performance.now() - started, canonical_json_bytes: records.reduce((sum, record) => sum + bytes(record), 0) };
    } catch (error) { this.close(); throw error; }
  }
  private statement(sql: string): Statement {
    let query = this.statements.get(sql);
    if (!query) { query = this.db.prepare(sql); this.statements.set(sql, query); }
    return query;
  }
  private pageBytes(): number {
    return (this.statement("PRAGMA page_count").get() as { page_count: number }).page_count
      * (this.statement("PRAGMA page_size").get() as { page_size: number }).page_size;
  }
  private search(query: string, ranking: Ranking, limit: number): { records: MemoryRecord[]; excerpts: string[] } {
    const start = crypto.randomUUID();
    const end = crypto.randomUUID();
    const rows = this.statement(`SELECT r.payload,snippet(memory_fts,1,?,?,'…',48) AS excerpt FROM memory_fts JOIN records r ON r.seq=memory_fts.rowid
      WHERE memory_fts MATCH ? AND rank MATCH ? AND r.owner_id=? AND r.project_id=? AND (r.scope!='task' OR r.task_id=?)
      AND (r.checkout_id IS NULL OR r.checkout_id=?) AND r.superseded_by IS NULL
      AND (r.memory_type!='task_state' OR r.updated_at>?) ORDER BY rank ASC,r.id ASC LIMIT ?`)
      .all(start, end, ftsQuery(query), RANKING_SQL[ranking], OWNER, PROJECT, "fixture-session", "main", NOW - 30 * 86400000, limit) as { payload: string; excerpt: string }[];
    const records = rows.map(row => MemoryRecordSchema.parse(JSON.parse(row.payload)));
    const excerpts = rows.map((row, i) => bodyExcerpt(row.excerpt, start, end, records[i]!.description ? LIMITS.describedExcerpt : LIMITS.excerpt));
    return { records, excerpts };
  }
  records(query: string, ranking: Ranking, limit = 10): MemoryRecord[] {
    return this.search(query, ranking, limit).records;
  }
  response(query: string, ranking: Ranking) {
    const { records, excerpts } = this.search(query, ranking, 6);
    return searchResponse(records, 5, excerpts);
  }
  close(): void { for (const statement of this.statements.values()) statement.finalize(); this.statements.clear(); this.db.close(true); }
}

export type Judgement = {
  id: string; category: EvaluationQuery["category"]; query: string; relevant: string[];
  rank: number | null; top5: string[]; coverage5: number; recall5: number;
};
export function judge(query: EvaluationQuery, ids: string[]): Judgement {
  const rank = ids.findIndex(id => query.relevant.includes(id));
  const matches = ids.slice(0, 5).filter(id => query.relevant.includes(id));
  return { id: query.id, category: query.category, query: query.query, relevant: query.relevant,
    rank: rank === -1 ? null : rank + 1, top5: ids.slice(0, 5), coverage5: matches.length ? 1 : 0, recall5: matches.length / query.relevant.length };
}
export function quality(rows: Judgement[]) {
  if (!rows.length) throw new Error("A quality cohort must contain at least one query");
  const mean = (get: (row: Judgement) => number) => rows.reduce((sum, row) => sum + get(row), 0) / rows.length;
  return { queries: rows.length, mrr10: mean(row => row.rank === null ? 0 : 1 / row.rank), coverage5: mean(row => row.coverage5), recall5: mean(row => row.recall5) };
}
export function percentile(samples: number[], fraction: number): number {
  if (!samples.length) throw new Error("Cannot measure an empty sample");
  return [...samples].sort((a, b) => a - b)[Math.max(0, Math.ceil(samples.length * fraction) - 1)]!;
}
function distribution(samples: number[]) { return { p50: percentile(samples, .5), p95: percentile(samples, .95), max: Math.max(...samples) }; }
export function evaluate(index: EvaluationIndex, rounds = 25) {
  const rows: Record<Ranking, Judgement[]> = { equal: [], weighted: [] };
  const responseBytes: Record<Ranking, number[]> = { equal: [], weighted: [] };
  const envelopeBytes: Record<Ranking, number[]> = { equal: [], weighted: [] };
  const excerpted: Record<Ranking, number> = { equal: 0, weighted: 0 };
  for (const ranking of ["equal", "weighted"] as const) {
    for (const query of QUERIES) {
      rows[ranking].push(judge(query, index.records(query.query, ranking).map(record => record.id)));
      const response = index.response(query.query, ranking);
      responseBytes[ranking].push(bytes(response));
      envelopeBytes[ranking].push(bytes({ isError: false, content: [{ type: "text", text: JSON.stringify(response) }] }) + 256);
      excerpted[ranking] += response.results.filter(record => record.excerpted).length;
    }
  }
  // Interleave variants and rotate query order so one variant does not receive
  // all cold queries or one contiguous interval of machine scheduling noise.
  for (let round = 0; round < 3; round++) for (const query of QUERIES) {
    index.response(query.query, "equal"); index.response(query.query, "weighted");
  }
  const times: Record<Ranking, number[]> = { equal: [], weighted: [] };
  for (let round = 0; round < rounds; round++) for (let step = 0; step < QUERIES.length; step++) {
    const query = QUERIES[(step + round * 7) % QUERIES.length]!;
    for (const ranking of (step + round) % 2 ? ["weighted", "equal"] as const : ["equal", "weighted"] as const) {
      const started = performance.now();
      index.response(query.query, ranking);
      times[ranking].push(performance.now() - started);
    }
  }
  const summarize = (ranking: Ranking) => ({
    overall: quality(rows[ranking]),
    cohorts: Object.fromEntries((["concise", "long", "ambiguous", "legacy"] as const).map(category => [category, quality(rows[ranking].filter(row => row.category === category))])),
    response_bytes: distribution(responseBytes[ranking]),
    envelope_with_rpc_allowance_bytes: distribution(envelopeBytes[ranking]),
    excerpted_hits: excerpted[ranking],
    latency_ms: distribution(times[ranking]), samples: times[ranking].length,
    judgements: rows[ranking],
  });
  const equal = summarize("equal");
  const weighted = summarize("weighted");
  const legacyEqual = quality(rows.equal.filter(row => row.category === "legacy"));
  const legacyWeighted = quality(rows.weighted.filter(row => row.category === "legacy"));
  const gate = {
    mrr_improves: weighted.overall.mrr10 > equal.overall.mrr10,
    overall_top5_coverage_preserved: weighted.overall.coverage5 >= equal.overall.coverage5,
    legacy_top5_coverage_preserved: legacyWeighted.coverage5 >= legacyEqual.coverage5,
    overall_top5_recall_preserved: weighted.overall.recall5 >= equal.overall.recall5,
    legacy_top5_recall_preserved: legacyWeighted.recall5 >= legacyEqual.recall5,
    latency_within_budget: weighted.latency_ms.p95 <= equal.latency_ms.p95 * 1.25 + 1,
    response_budget_preserved: Math.max(equal.envelope_with_rpc_allowance_bytes.max, weighted.envelope_with_rpc_allowance_bytes.max) <= 8192,
  };
  return { equal, weighted, gate, eligible: Object.values(gate).every(Boolean) };
}
