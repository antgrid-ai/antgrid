// SPDX-License-Identifier: MPL-2.0

import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { cpus } from "node:os";
import { join, resolve } from "node:path";
import { VARIANTS, PublicIndex, evaluateGroups, stableRecordId, summarize, type QueryMeasurement } from "./retrieval";
import { technicalFixtures, selectTechnicalQueries } from "./technical-fixtures";
import { prepareTechnicalDataset } from "./technical-dataset";
import { ftsQuery } from "../../src/search";
import { z } from "zod";

const root = resolve(import.meta.dir, "../../../..");
const base = join(root, ".tmp/memory-public-evaluation");
const args = process.argv.slice(2);
const option = (name: string) => { const index = args.indexOf(name); return index < 0 ? undefined : args[index + 1]; };
const dataset = option("--dataset") ?? "all";
const rounds = Number(option("--rounds") ?? 3);
const queryCount = Number(option("--queries") ?? 200);
if (!["all", "fixtures", "programmers"].includes(dataset)) throw new Error("--dataset must be all, fixtures or programmers");
if (!Number.isInteger(rounds) || rounds < 1 || rounds > 100) throw new Error("--rounds must be 1..100");
if (!Number.isInteger(queryCount) || queryCount < 1 || queryCount > 10_000) throw new Error("--queries must be 1..10000");
const hash = (input: string | Uint8Array) => createHash("sha256").update(input).digest("hex");
const runId = `${new Date().toISOString().replaceAll(/[:.]/g, "-")}-technical-${dataset}`;
const directory = join(base, "runs", runId);
mkdirSync(directory, { recursive: true });
const fixtures = technicalFixtures();
const caseMap = new Map(fixtures.cases.map(item => [item.id, item]));
const saveRows = (name: string, rows: unknown[]) => writeFileSync(join(directory, `${name}-queries.jsonl`), rows.map(row => JSON.stringify(row)).join("\n") + "\n");
const variants = (rows: QueryMeasurement[]) => Object.fromEntries(VARIANTS.map(variant => [variant, summarize(rows.filter(row => row.variant === variant))]));
let fixtureRows: QueryMeasurement[] = [];
let publicRows: QueryMeasurement[] = [];
let publicManifest: unknown;
let selection: unknown;
const identifierProbes: { query: string; target: string; generated: string; foundInRaw10: boolean; rawIds: string[] }[] = [];

if (dataset !== "programmers") {
  fixtureRows = await evaluateGroups(fixtures.groups, join(base, "stores"), rounds);
  saveRows("technical-fixtures", fixtureRows.map(row => ({ ...row, diagnostic: caseMap.get(row.id) })));
  const probeDirectory = mkdtempSync(join(base, "stores", "identifier-probes-"));
  let index: PublicIndex | undefined;
  try {
    index = new PublicIndex(probeDirectory, fixtures.groups[0]!.documents, true);
    index.ranking("weighted");
    for (const probe of fixtures.probes) {
      const response = z.object({ results: z.array(z.object({ id: z.string() })) }).parse(await index.search(probe.query, 10, true));
      const rawIds = response.results.map(row => row.id);
      identifierProbes.push({ query: probe.query, target: probe.target, generated: ftsQuery(probe.query), foundInRaw10: rawIds.includes(stableRecordId(probe.id)), rawIds });
    }
  } finally { index?.close(); rmSync(probeDirectory, { recursive: true, force: true }); }
}
if (dataset !== "fixtures") {
  console.log("Preparing CQADupStack programmers");
  const prepared = await prepareTechnicalDataset(join(base, "datasets/cqadupstack-programmers"));
  publicManifest = prepared.manifest;
  if (prepared.groups.length !== 1) throw new Error("Expected one programmers corpus");
  const selected = selectTechnicalQueries(prepared.groups[0]!, queryCount);
  selection = selected.selection;
  console.log(`Evaluating ${selected.group.queries.length} queries against ${selected.group.documents.length} chunks`);
  publicRows = await evaluateGroups([selected.group], join(base, "stores"), rounds);
  saveRows("cqadupstack-programmers", publicRows);
}
function diagnosticSummary(rows: QueryMeasurement[]) {
  return { ...summarize(rows), top1: rows.filter(row => {
    const relevant = caseMap.get(row.id)!.relevantIds.map(stableRecordId);
    return relevant.includes(row.deliveredIds[0]!);
  }).length / rows.length };
}
const diagnostics = Object.fromEntries(fixtures.groups.filter(group => fixtureRows.some(row => row.group === group.id)).map(group => [group.id,
  Object.fromEntries(VARIANTS.map(variant => [variant, Object.fromEntries([...new Set(group.queries.map(query => query.category))].map(category => [category,
    diagnosticSummary(fixtureRows.filter(row => row.group === group.id && row.variant === variant && row.category === category))]))]))]));
const sourcePaths = ["src/contracts.ts", "src/search.ts", "src/service.ts", "src/store.ts", "evaluation/public/retrieval.ts", "evaluation/public/technical-fixtures.ts", "evaluation/public/technical-dataset.ts", "evaluation/public/run-technical.ts"];
const report = {
  version: 1, runId, measuredAt: new Date().toISOString(), rounds, modelCalls: 0, apiCostUsd: 0,
  qualification: "Diagnostic measurement only; successful process exit does not qualify technical-name retrieval",
  operatingSystem: process.platform, architecture: process.arch, bun: Bun.version, cpu: cpus()[0]?.model,
  sourceSha256: Object.fromEntries(sourcePaths.map(path => [path, hash(readFileSync(join(import.meta.dir, "../..", path)))])),
  fixtureCases: fixtures.cases, fixtureDocuments: fixtures.groups[0]!.documents.length, diagnostics, identifierProbes,
  public: publicRows.length ? { manifest: publicManifest, selection, variants: variants(publicRows) } : null,
};
writeFileSync(join(directory, "report.json"), JSON.stringify(report, null, 2) + "\n");
const pct = (value: number) => `${(value * 100).toFixed(2)}%`;
const ms = (value: number | null) => value === null ? "n/a" : value.toFixed(2);
const lines = [
  "# Technical memory retrieval evaluation", "", `Measured ${report.measuredAt}; run \`${runId}\`. Local retrieval only: zero model calls and zero API cost.`, "",
  "## Reproduce", "", "Run from the repository root. The public dataset requires Python, curl and an isolated DuckDB reader; fixture-only runs do not need that reader. Install it once:", "",
  "```powershell", "python -m pip install --only-binary=:all: --no-deps --target .tmp/memory-public-evaluation/python duckdb==1.4.3", "```", "",
  "```powershell", `bun run --filter antgrid-memory evaluate:technical --dataset ${dataset} --queries ${queryCount} --rounds ${rounds}`, "```", "",
  "Caches and per-query JSONL stay under ignored `.tmp/memory-public-evaluation`. Isolated production-schema stores are deleted after each group; user memory is never opened. See the [public retrieval evaluation](memory-public-retrieval-evaluation.md) for the general benchmarks.", "",
  "## What this measures", "",
  "The controlled fixtures test strict record lookup by names, technical literals, casing and quoted phrases. Every member of a confusable family is queried, so a lucky ID tie-break cannot make an entire family pass. All families share one corpus with the same prose template. An independent control corpus replaces each entire name with a unique alphanumeric token; IDs, template, relevance and metadata placement stay the same. Controls establish exact-token lookup, not an equivalent natural-language workload: token counts and document lengths necessarily differ. These deliberately adversarial cases are not an estimate of production failure frequency.", "",
  "The literal, quoted and casing cohorts expect the exact named record. Accent-folded spelling variants are intentionally distinct fixture records; this strict identity test does not imply that accent folding is inappropriate for ordinary person-name search. Alias/identifier-part probes separately report whether a specific candidate appears, without assigning complete relevance labels or computing accuracy. Other returned records may be relevant; these probes do not claim alias matching is currently promised by the lexical search contract. No descriptions, embeddings, query rewriting or model-generated text are used.", "",
  "Body-only, equal metadata weighting, and production title/description weights (4/2) use the same production service and 8 KiB agent response budget as the earlier public evaluation. Source titles remain in the body in every variant. Top-1 exact-target accuracy and MRR expose ambiguity that Recall@5 can hide when several siblings all fit in five results. Full IDs and generated FTS queries are retained per case. Query syntax and punctuation distinctions are evaluated as shipped; this run makes no production tokenizer or weighting changes.", "",
  `Latency uses one warm-up plus ${rounds} timed searches per query/variant, with rotated variant order. It includes service validation, SQL and response formatting, but excludes downloads, store construction, network/MCP transport and models. Percentiles describe successfully timed searches; a failure in the preceding raw-search step has no latency samples and still counts as a relevance miss. Warm-cache timings on this one Windows machine do not qualify other platforms.`, "",
];
if (fixtureRows.length) {
  lines.push("## Controlled diagnostics", "", `Each corpus contains ${report.fixtureDocuments} records and ${fixtures.cases.length} queries. The table shows production weights; all variants and controls are in the JSON report.`, "",
    "| Query cohort | Queries | Exact target top 1 | Delivered Recall@5 | Raw MRR@10 | Opaque control top 1 | p95 ms |",
    "|---|---:|---:|---:|---:|---:|---:|");
  for (const [category, value] of Object.entries(diagnostics["technical-literals"]!.weighted!)) {
    const control = diagnostics["technical-controls"]!.weighted![category]!;
    lines.push(`| ${category} | ${value.queries} | ${pct(value.top1)} | ${pct(value.delivered.recall5!)} | ${value.raw.mrr10!.toFixed(3)} | ${pct(control.top1)} | ${ms(value.latencyMs.p95)} |`);
  }
  lines.push("", "### Unscored identifier probes", "", "These check candidate presence, not whether every other result is irrelevant.", "",
    "| Query | Desired candidate | Present in raw top 10 | Generated FTS |", "|---|---|---|---|");
  for (const probe of identifierProbes) lines.push(`| \`${probe.query}\` | \`${probe.target}\` | ${probe.foundInRaw10 ? "Yes" : "No"} | \`${probe.generated}\` |`);
}
if (publicRows.length) {
  lines.push("", "## Public programming-question pilot", "",
    "CQADupStack programmers tests retrieval of duplicate programming questions using upstream positive qrels. The deterministic SHA-256 query selection is fixed before scoring and keeps the complete corpus. Oversized queries are reported and fail validation rather than being silently truncated. Bodies exceeding 16 KiB are split without dropping source text; a hit on any chunk is credited to its source question, so these are question-location metrics rather than proof that a returned excerpt contains an answer. Duplicate chunks consume rank slots without increasing source recall. Optional source titles repeat on every chunk, while the full original title occurs once in the partitioned body: the ablation holds source information constant, not per-chunk text. All queries are upstream text, not synthetic names or generated paraphrases.", "",
    "This pilot establishes a technical-domain baseline, not the causal effect of technical terminology: there is no equivalent nontechnical rewrite of these questions. Unlabelled results are not proven irrelevant; labels are the dataset's known duplicate links. Scores are not comparable to QA, coding-task success or vendor end-to-end memory scores.", "",
    "| Variant | Queries | Delivered Coverage@5 | Delivered Recall@5 | Raw MRR@10 | Raw Recall@10 | p50 / p95 ms | Errors |",
    "|---|---:|---:|---:|---:|---:|---:|---:|");
  for (const [variant, value] of Object.entries(report.public!.variants)) {
    lines.push(`| ${variant} | ${value.queries} | ${pct(value.delivered.coverage5!)} | ${pct(value.delivered.recall5!)} | ${value.raw.mrr10!.toFixed(3)} | ${pct(value.raw.recall10!)} | ${ms(value.latencyMs.p50)} / ${ms(value.latencyMs.p95)} | ${value.errors} |`);
  }
}
const rows = [...fixtureRows, ...publicRows];
lines.push("", "## Limits and follow-up", "",
  "The lexical representation loses some meaningful distinctions: `C++`, `C#` and `C` produce the same query; unquoted version/path components become alternatives; camelCase stays a single token. Weight changes cannot recover discarded symbols or candidate records absent from the index. Quoting preserves token order but does not restore discarded punctuation. A separate technical-literal indexing/matching signal and explicit identifier-part aliases should be evaluated before claiming robust technical-name retrieval. Globally treating punctuation as word characters could regress ordinary prose and component searches.", "",
  "A successful process exit means the measurements completed without service errors, not that a technical-name quality gate passed. The diagnostics expose known unresolved retrieval gaps; no production fix or release qualification is claimed.", "",
  `Errors across measured query/variant pairs: ${rows.filter(row => row.error).length}. Largest serialized agent MCP envelope including allowance: ${Math.max(...rows.map(row => row.envelopeBytes))} bytes (limit 8192). Every error remains in the JSONL and counts as a miss. No automatic-save or coding qualification was run.`, "",
  "## Provenance", "", "```json", JSON.stringify({ ...report, fixtureCases: undefined, diagnostics: undefined }, null, 2), "```", "",
  "Sources: [CQADupStack authors](https://github.com/D1Doris/CQADupStack), [official BEIR dataset](https://huggingface.co/datasets/BeIR/cqadupstack), [SQLite FTS5 unicode61](https://sqlite.org/fts5.html#unicode61_tokenizer).", "",
);
writeFileSync(join(directory, "report.md"), lines.join("\n"));
writeFileSync(join(import.meta.dir, "../memory-technical-retrieval-evaluation.md"), lines.join("\n"));
console.log(`Report: ${directory}`);
if (rows.some(row => row.error)) process.exitCode = 1;
