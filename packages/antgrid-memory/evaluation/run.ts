// SPDX-License-Identifier: MPL-2.0

import { createHash } from "node:crypto";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { cpus, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { EvaluationIndex, evaluate } from "./benchmark";
import { corpus, DOCUMENTS, JUDGEMENT_VERSION, QUERIES } from "./fixtures";

const sha256 = (value: string) => createHash("sha256").update(value).digest("hex");
type Measurement = { records: number; metadata_index: EvaluationIndex["size"]; content_index: EvaluationIndex["size"]; evaluation: ReturnType<typeof evaluate> };
export function markdown(measurements: Measurement[], environment: Record<string, unknown>, fixtureHash: string): string {
  const eligible = measurements.every(measurement => measurement.evaluation.eligible);
  const percentage = (n: number) => `${(n * 100).toFixed(2)}%`;
  const decimal = (n: number) => n.toFixed(3);
  const lines = [
    "# Memory search ranking evaluation", "",
    `Measured ${environment.measured_at}. **Decision: ${eligible ? "the proposed weights meet the stated synthetic-fixture gate" : "keep equal weights; the proposed weights do not meet every gate"}.**`, "",
    "This report compares equal FTS5 column weights with title 4, description 2, body 1, applicability 1. Both variants index the same columns in the order `id UNINDEXED, content, applicability, title, description`; the baseline uses `rank MATCH 'bm25()'` and the candidate uses `rank MATCH 'bm25(0,1,1,4,2)'`. Both order by `rank ASC, id ASC`, matching the intended production rank path. The content-only index is measured separately for storage overhead; it is not the equal-weight ranking baseline.", "",
    "## Reproduce", "", "```powershell", "bun run --filter antgrid-memory evaluate:search", "```", "",
    "The runner creates disposable synthetic SQLite databases, then writes this report and `.tmp/memory-search-evaluation.json`. It never reads a user memory store or launches an agent. Defaults are 100 and 10,000 records, three full warm-up passes and 25 measured passes (1,000 samples per variant per corpus). Optional `--rounds N` changes only measured repetitions.", "",
    "## Judgements and method", "",
    `The ${QUERIES.length} queries cover concise findings, long procedural documents, underspecified queries and legacy records without title/description (${QUERIES.length / 4} per cohort). ${DOCUMENTS.length} hand-authored synthetic documents include relevant facts and plausible distractors. Additional deterministic background notes exercise common-word postings. Each query has fixed relevant IDs and a written rationale in \`packages/antgrid-memory/evaluation/fixtures.ts\`. Labels were assigned before either ranking was run and independently reviewed by the coordinating agent; they were not tuned against the scores. Judgement version: \`${JUDGEMENT_VERSION}\`; fixture SHA-256: \`${fixtureHash}\`.`, "",
    "MRR@10 uses the first judged-relevant result among the ten retrievable hits; a miss scores zero. Coverage@5 is the proportion of queries with at least one relevant result in the first five. Recall@5 is the mean fraction of all judged-relevant records returned in the first five, so ambiguous queries can have more than one relevant record. Quality measures raw ranked hits. Response sizes and latency use the production query parser and response formatter with the default five-result budget.", "",
    "The gate requires higher overall MRR@10, no overall or legacy Coverage@5 regression, and candidate p95 <= baseline p95 × 1.25 + 1 ms on both corpus sizes. This runner additionally rejects Recall@5 regressions and responses above the existing 8 KiB envelope budget. It reports per-query losses even if aggregate metrics pass.", "",
    "Latency covers synchronous SQLite search including `snippet(memory_fts,1,start,end,'…',48)`, record JSON/schema parsing, byte-aware `bodyExcerpt`, and production response formatting. Random snippet markers follow the production path. Queries use owner/project/session/checkout/lifecycle predicates before limiting, but this all-eligible corpus is not an authorization test. Variants are interleaved and query order rotates. It excludes disk-open time, network/MCP transport, model inference and agent decisions. Index build time includes generating canonical rows and building the FTS index. Canonical rows use a serialized record payload in this harness rather than reproducing all service tables.", "",
    "## Results", "",
    "| Records | Variant | MRR@10 | Coverage@5 | Recall@5 | p50 ms | p95 ms | Max response / envelope bytes |", "|---:|---|---:|---:|---:|---:|---:|---:|",
  ];
  for (const m of measurements) for (const variant of ["equal", "weighted"] as const) {
    const r = m.evaluation[variant];
    lines.push(`| ${m.records.toLocaleString("en-US")} | ${variant} | ${decimal(r.overall.mrr10)} | ${percentage(r.overall.coverage5)} | ${percentage(r.overall.recall5)} | ${decimal(r.latency_ms.p50)} | ${decimal(r.latency_ms.p95)} | ${r.response_bytes.max} / ${r.envelope_with_rpc_allowance_bytes.max} |`);
  }
  lines.push("", "| Records | Cohort | Equal / weighted MRR@10 | Equal / weighted Coverage@5 | Equal / weighted Recall@5 |", "|---:|---|---:|---:|---:|");
  for (const m of measurements) for (const cohort of ["concise", "long", "ambiguous", "legacy"] as const) {
    const a = m.evaluation.equal.cohorts[cohort]!; const b = m.evaluation.weighted.cohorts[cohort]!;
    lines.push(`| ${m.records.toLocaleString("en-US")} | ${cohort} | ${decimal(a.mrr10)} / ${decimal(b.mrr10)} | ${percentage(a.coverage5)} / ${percentage(b.coverage5)} | ${percentage(a.recall5)} / ${percentage(b.recall5)} |`);
  }
  lines.push("", "## Storage and gate details", "", "Weighting does not change stored postings: equal and weighted searches use the same metadata index.", "", "| Records | Content-only FTS bytes | Metadata FTS bytes | Change | Metadata database bytes | Metadata build ms |", "|---:|---:|---:|---:|---:|---:|");
  for (const m of measurements) lines.push(`| ${m.records.toLocaleString("en-US")} | ${m.content_index.fts_bytes} | ${m.metadata_index.fts_bytes} | ${percentage(m.metadata_index.fts_bytes / m.content_index.fts_bytes - 1)} | ${m.metadata_index.database_bytes} | ${decimal(m.metadata_index.build_ms)} |`);
  for (const m of measurements) {
    lines.push("", `- ${m.records.toLocaleString("en-US")} records: ${Object.entries(m.evaluation.gate).map(([name, pass]) => `\`${name}\` ${pass ? "pass" : "FAIL"}`).join("; ")}. Index measurement: ${m.metadata_index.fts_measurement}.`);
  }
  lines.push("", "## Per-query evidence", "", "Ranks beyond ten are shown as a miss. Each cell is equal → weighted first-relevant rank.", "", "| ID | Cohort | Query | 100 records | 10,000 records |", "|---|---|---|---:|---:|");
  for (const q of QUERIES) {
    const cells = measurements.map(m => `${m.evaluation.equal.judgements.find(row => row.id === q.id)!.rank ?? "miss"} → ${m.evaluation.weighted.judgements.find(row => row.id === q.id)!.rank ?? "miss"}`);
    lines.push(`| ${q.id} | ${q.category} | ${q.query.replaceAll("|", "\\|")} | ${cells.join(" | ")} |`);
  }
  for (const m of measurements) {
    const equal = m.evaluation.equal.judgements;
    const weighted = m.evaluation.weighted.judgements;
    const rankLosses = weighted.filter((row, i) => (row.rank ?? Infinity) > (equal[i]!.rank ?? Infinity)).map(row => row.id);
    const recallLosses = weighted.filter((row, i) => row.recall5 < equal[i]!.recall5).map(row => row.id);
    const misses = weighted.filter(row => row.rank === null).map(row => row.id);
    lines.push("", `- ${m.records.toLocaleString("en-US")} records: first-relevant rank regressions: ${rankLosses.join(", ") || "none"}; per-query Recall@5 regressions: ${recallLosses.join(", ") || "none"}; candidate misses at ten: ${misses.join(", ") || "none"}.`);
  }
  lines.push("", "The Japanese legacy query `g07` uses standalone terms within an unsegmented sentence and remains a lexical miss for both variants. The long export guide (`l10`) falls below ten as many short export-related background records are added. Metadata weighting does not resolve every long-document retrieval miss.");
  lines.push("", "## Limitations", "",
    "This is a small synthetic lexical benchmark, not a live-agent quality study or evidence of token/tool-call savings. Several concise queries closely match authored titles. Long documents share generated review context and place their distinguishing facts at the beginning; a separate deep-body regression checks the excerpt path beyond those ranking fixtures. Missing semantic synonyms and tokenizer boundaries can remain lexical misses. Background notes are generated, not representative samples of real users' memory stores. Relevance labels are agent-authored and separately agent-reviewed, not an independent human panel.", "",
    "The excerpt regression places its only query term near the end of a long body: SQLite retrieves it, and the query-aware excerpt includes that term while remaining marked `excerpted`. The opening prefix alone would omit it. A full `memory_get` remains necessary before relying on an incomplete finding, since qualifications elsewhere in the body may be absent. No model or summarizer rewrites it.", "",
    "Timing is one warm-cache run on a shared machine. The 1 ms absolute allowance is material for small queries, and these measurements should not be presented as cross-platform performance qualification. Title/description weighting can lower individual relevant hits even when average quality improves; per-query evidence and coverage remain part of the decision.", "",
    "## Environment", "", "```json", JSON.stringify(environment, null, 2), "```", "",
  );
  return lines.join("\n");
}

export function run(): void {
  const root = resolve(import.meta.dir, "../../..");
  const roundArg = Bun.argv.indexOf("--rounds");
  const rounds = roundArg < 0 ? 25 : Number(Bun.argv[roundArg + 1]);
  if (!Number.isInteger(rounds) || rounds < 1 || rounds > 1000) throw new Error("--rounds must be an integer between 1 and 1000");
  const directory = mkdtempSync(join(tmpdir(), "antgrid-search-evaluation-"));
  const measurements: Measurement[] = [];
  try {
    for (const count of [100, 10_000]) {
      const docs = corpus(count);
      const legacy = new EvaluationIndex(join(directory, `content-${count}.sqlite`), docs, false);
      const contentSize = legacy.size; legacy.close();
      const index = new EvaluationIndex(join(directory, `metadata-${count}.sqlite`), docs);
      try { measurements.push({ records: count, metadata_index: index.size, content_index: contentSize, evaluation: evaluate(index, rounds) }); }
      finally { index.close(); }
    }
  } finally { rmSync(directory, { recursive: true, force: true }); }
  const environment = {
    measured_at: new Date().toISOString(), platform: process.platform, architecture: process.arch, bun: Bun.version,
    cpu: cpus()[0]?.model, measured_rounds: rounds, samples_per_variant_per_corpus: rounds * QUERIES.length,
    formatter_sha256: sha256(readFileSync(resolve(import.meta.dir, "../src/search.ts"), "utf8")),
  };
  const fixtureHash = sha256(readFileSync(join(import.meta.dir, "fixtures.ts"), "utf8"));
  const reportPath = join(import.meta.dir, "memory-search-evaluation.md");
  const jsonPath = join(root, ".tmp/memory-search-evaluation.json");
  mkdirSync(dirname(reportPath), { recursive: true }); mkdirSync(dirname(jsonPath), { recursive: true });
  writeFileSync(reportPath, markdown(measurements, environment, fixtureHash));
  writeFileSync(jsonPath, JSON.stringify({ environment, fixture_sha256: fixtureHash, measurements }, null, 2) + "\n");
  console.log(JSON.stringify({ report: reportPath, measurements: measurements.map(m => ({ records: m.records, eligible: m.evaluation.eligible, gate: m.evaluation.gate, equal: m.evaluation.equal.overall, weighted: m.evaluation.weighted.overall, equal_p95_ms: m.evaluation.equal.latency_ms.p95, weighted_p95_ms: m.evaluation.weighted.latency_ms.p95 })) }, null, 2));
}

if (import.meta.main) run();
