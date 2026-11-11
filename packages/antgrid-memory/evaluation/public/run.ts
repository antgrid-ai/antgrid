// SPDX-License-Identifier: MPL-2.0

import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { cpus } from "node:os";
import { join, resolve } from "node:path";
import { prepareLongMemEval } from "./longmemeval";
import { prepareSciFact } from "./scifact";
import { VARIANTS, evaluateGroups, summarize, type QueryMeasurement } from "./retrieval";

const root = resolve(import.meta.dir, "../../../..");
const base = join(root, ".tmp/memory-public-evaluation");
const args = process.argv.slice(2);
const option = (name: string) => { const index = args.indexOf(name); return index < 0 ? undefined : args[index + 1]; };
const dataset = option("--dataset") ?? "all";
const rounds = Number(option("--rounds") ?? 3);
if (!["all", "scifact", "longmemeval"].includes(dataset)) throw new Error("--dataset must be all, scifact or longmemeval");
if (!Number.isInteger(rounds) || rounds < 1 || rounds > 100) throw new Error("--rounds must be 1..100");
const hash = (value: string | Uint8Array) => createHash("sha256").update(value).digest("hex");
const runId = `${new Date().toISOString().replaceAll(/[:.]/g, "-")}-${dataset}`;
const runDirectory = join(base, "runs", runId);
mkdirSync(runDirectory, { recursive: true });
const results: { dataset: string; manifest: unknown; variants: Record<string, ReturnType<typeof summarize>>; cohorts: Record<string, unknown>; changes: unknown }[] = [];

for (const name of dataset === "all" ? ["scifact", "longmemeval"] : [dataset]) {
  console.log(`Preparing ${name}`);
  const prepared = name === "scifact" ? await prepareSciFact(join(base, "datasets/scifact")) : await prepareLongMemEval({ directory: join(base, "datasets") });
  const rows = await evaluateGroups(prepared.groups, join(base, "stores"), rounds);
  writeFileSync(join(runDirectory, `${name}-queries.jsonl`), rows.map(row => JSON.stringify(row)).join("\n") + "\n");
  const variants = Object.fromEntries(VARIANTS.map(variant => [variant, summarize(rows.filter(row => row.variant === variant))]));
  const categories = [...new Set(rows.filter(row => row.answerable).map(row => row.category))];
  const cohorts = Object.fromEntries(categories.map(category => [category, Object.fromEntries(VARIANTS.map(variant => [variant,
    summarize(rows.filter(row => row.category === category && row.variant === variant))]))]));
  const pairs = new Map<string, Partial<Record<string, QueryMeasurement>>>();
  for (const row of rows.filter(row => row.answerable)) {
    const key = `${row.group}/${row.id}`;
    pairs.set(key, { ...pairs.get(key), [row.variant]: row });
  }
  const changed = [...pairs.entries()].map(([id, pair]) => ({ id,
    mrrDelta: pair.weighted!.raw!.mrr10 - pair.equal!.raw!.mrr10,
    recall5Delta: pair.weighted!.delivered!.recall5 - pair.equal!.delivered!.recall5,
  })).filter(row => row.mrrDelta || row.recall5Delta);
  results.push({ dataset: name, manifest: prepared.manifest, variants, cohorts, changes: changed });
  console.log(JSON.stringify({ dataset: name, variants }, null, 2));
}
const sourcePaths = ["src/contracts.ts", "src/search.ts", "src/service.ts", "src/store.ts", "evaluation/public/retrieval.ts", "evaluation/public/longmemeval.ts", "evaluation/public/scifact.ts", "evaluation/public/run.ts"];
const report = {
  version: 1, runId, measuredAt: new Date().toISOString(), rounds, operatingSystem: process.platform, architecture: process.arch, bun: Bun.version, cpu: cpus()[0]?.model,
  sourceSha256: Object.fromEntries(sourcePaths.map(path => [path, hash(readFileSync(join(import.meta.dir, "../..", path)))])),
  modelCalls: 0, apiCostUsd: 0, results,
};
writeFileSync(join(runDirectory, "report.json"), JSON.stringify(report, null, 2) + "\n");
const percent = (n: number) => `${(n * 100).toFixed(2)}%`;
const decimal = (n: number | null) => n === null ? "n/a" : n.toFixed(3);
const lines = [
  "# Public memory retrieval evaluation", "", `Measured ${report.measuredAt}; run \`${runId}\`. No model inference or paid API calls in this retrieval run.`, "",
  "## Reproduce", "", "```powershell", `bun run --filter antgrid-memory evaluate:public --dataset ${dataset} --rounds ${rounds}`, "```", "",
  "Downloads stay under ignored `.tmp/memory-public-evaluation/datasets`; fixed source checksums reject drift. Each run writes a separate manifest, per-query JSONL and Markdown report under `.tmp/memory-public-evaluation/runs`. The latest requested dataset selection is copied to this document. No user memory store is read or changed.", "",
  "## Protocol fixed before scoring", "",
  "This is a retrieval-only evaluation of production MemoryService search, validation, FTS5 ranking, snippets and response formatting. Offline fixtures populate the production schema with deterministic IDs and validated/redacted records; they bypass automatic agent extraction, save receipts and duplicate suppression. It does not measure agent saving, QA accuracy, coding outcomes, MCP transport latency or savings in model tokens.", "",
  "The three variants are body-only (metadata omitted), equal weights with metadata, and current production weights (title 4, description 2, body/applicability 1). All retain the same source information in the body. SciFact uses source-authored titles, duplicated into its optional title field. LongMemEval titles are query-blind `Conversation on <session date>` labels; dates also remain in each body. No descriptions or model summaries are generated. This tests source titles and date labels, not the quality of agent-written descriptions.", "",
  "LongMemEval uses all 500 cleaned S instances in separate stores: the 30 abstention cases are searched and timed but excluded from relevance denominators. Original evidence flags/answer-prefixed IDs never enter records. Sessions exceeding 16 KiB are split deterministically at turn/UTF-8 boundaries. Relevance is scored against upstream evidence-session IDs after neutral remapping. A hit on any chunk of an evidence session is credited even if that chunk or returned excerpt lacks the answer; this is an optimistic session-location metric, not answer evidence verification. Duplicate source-session hits never increase recall.", "",
  "SciFact uses the complete BEIR test qrels and corpus. Original titles and abstracts remain in each body for every variant; only title indexing/weighting differs. Upstream binary relevance labels are unchanged. Gold answers and qrels stay outside the stores. Queries are the original question/claim text; LongMemEval question dates remain separate metadata for future QA and are not appended to retrieval queries. There is no query rewriting, stopword removal, tuning on results or semantic search.", "",
  "Raw MRR@10, nDCG@10 and Recall@10 use up to ten ranked records through the app inspection path. Delivered Recall@5, Coverage@5 and All-evidence@5 use the actual agent response with a five-record limit and 8 KiB serialized MCP-envelope budget. Chunk duplicates consume result slots; we do not retrieve extra chunks to manufacture five distinct sessions. These metrics are not directly comparable to vendor QA percentages or top-200 retrieval. LongMemEval has session-level evidence labels, so nDCG credits at most one new evidence source per returned chunk.", "",
  `Variant order rotates across queries/groups. Each pair has one warm-up followed by ${rounds} timed searches; timing includes service queue/validation/SQL/serialization but excludes fixture build, dataset download, HTTP, MCP and model work. Latency is a warm-cache measurement on this one Windows machine, not cross-platform qualification. Errors count as misses and are reported; no failed queries are silently dropped.`, "",
  "## Results", "",
  "| Dataset | Variant | Answerable / total | Delivered Coverage@5 | Delivered Recall@5 | All-evidence@5 | Raw MRR@10 | Raw nDCG@10 | Raw Recall@10 | p50 / p95 ms | Errors |",
  "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
];
for (const result of results) for (const variant of VARIANTS) {
  const value = result.variants[variant]!;
  lines.push(`| ${result.dataset} | ${variant} | ${value.answerable} / ${value.queries} | ${percent(value.delivered.coverage5!)} | ${percent(value.delivered.recall5!)} | ${percent(value.delivered.allEvidence5!)} | ${decimal(value.raw.mrr10!)} | ${decimal(value.raw.ndcg10!)} | ${percent(value.raw.recall10!)} | ${decimal(value.latencyMs.p50)} / ${decimal(value.latencyMs.p95)} | ${value.errors} |`);
}
lines.push("", "## Response budgets", "", "| Dataset | Variant | Max response bytes | Max MCP envelope + 256-byte allowance |", "|---|---|---:|---:|");
for (const result of results) for (const variant of VARIANTS) {
  const value = result.variants[variant]!;
  lines.push(`| ${result.dataset} | ${variant} | ${value.maxResponseBytes} | ${value.maxEnvelopeBytes} |`);
}
lines.push("", "## Category results", "", "| Dataset/category | Variant | Answerable queries | Delivered Recall@5 | Raw MRR@10 |", "|---|---|---:|---:|---:|");
for (const result of results) for (const [category, variants] of Object.entries(result.cohorts)) for (const variant of VARIANTS) {
  const value = (variants as Record<string, ReturnType<typeof summarize>>)[variant]!;
  lines.push(`| ${result.dataset}/${category} | ${variant} | ${value.answerable} | ${percent(value.delivered.recall5!)} | ${decimal(value.raw.mrr10!)} |`);
}
lines.push("", "## Interpretation", "",
  "These public results supplement the internal 40-query synthetic regression suite. They do not establish release readiness, automatic-save behavior or universal superiority of a weighting scheme. No production weights were changed in response to these scores. Public history/document corpora differ from concise agent-authored findings; source-title/date ablations cannot establish the benefit of generated descriptions. Per-query changes and failures are retained in the run artifacts.", "",
  "Model-based LoCoMo/LongMemEval QA and VibeMemBench coding runs were not run: the user selected local retrieval only. The earlier isolated authentication probe is recorded separately and is not part of these zero-model retrieval measurements.", "",
  "## Provenance", "", "```json", JSON.stringify({ ...report, results: results.map(result => ({ dataset: result.dataset, manifest: result.manifest, changedQueries: (result.changes as unknown[]).length })) }, null, 2), "```", "",
  "Sources: [LongMemEval](https://github.com/xiaowu0162/LongMemEval), [cleaned data](https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned), [BEIR](https://github.com/beir-cellar/beir), [SciFact](https://github.com/allenai/scifact).", "",
);
const markdown = lines.join("\n");
writeFileSync(join(runDirectory, "report.md"), markdown);
writeFileSync(join(import.meta.dir, "../memory-public-retrieval-evaluation.md"), markdown);
console.log(`Report: ${runDirectory}`);
if (results.some(result => Object.values(result.variants).some(value => value.errors))) process.exitCode = 1;
