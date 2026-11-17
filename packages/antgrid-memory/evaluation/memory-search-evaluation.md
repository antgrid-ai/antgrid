# Memory search ranking evaluation

Measured 2026-11-10T12:00:32.837Z. **Decision: the proposed weights meet the stated synthetic-fixture gate.**

This report compares equal FTS5 column weights with title 4, description 2, body 1, applicability 1. Both variants index the same columns in the order `id UNINDEXED, content, applicability, title, description`; the baseline uses `rank MATCH 'bm25()'` and the candidate uses `rank MATCH 'bm25(0,1,1,4,2)'`. Both order by `rank ASC, id ASC`, matching the intended production rank path. The content-only index is measured separately for storage overhead; it is not the equal-weight ranking baseline.

## Reproduce

```powershell
bun run --filter antgrid-memory evaluate:search
```

The runner creates disposable synthetic SQLite databases, then writes this report and `.tmp/memory-search-evaluation.json`. It never reads a user memory store or launches an agent. Defaults are 100 and 10,000 records, three full warm-up passes and 25 measured passes (1,000 samples per variant per corpus). Optional `--rounds N` changes only measured repetitions.

## Judgements and method

The 40 queries cover concise findings, long procedural documents, underspecified queries and legacy records without title/description (10 per cohort). 42 hand-authored synthetic documents include relevant facts and plausible distractors. Additional deterministic background notes exercise common-word postings. Each query has fixed relevant IDs and a written rationale in `packages/antgrid-memory/evaluation/fixtures.ts`. Labels were assigned before either ranking was run and independently reviewed by the coordinating agent; they were not tuned against the scores. Judgement version: `synthetic-source-facts-v1`; fixture SHA-256: `c6548da110306139817220adc9d90d0bc2014943c2145ccb6f7dab0a9504751a`.

MRR@10 uses the first judged-relevant result among the ten retrievable hits; a miss scores zero. Coverage@5 is the proportion of queries with at least one relevant result in the first five. Recall@5 is the mean fraction of all judged-relevant records returned in the first five, so ambiguous queries can have more than one relevant record. Quality measures raw ranked hits. Response sizes and latency use the production query parser and response formatter with the default five-result budget.

The gate requires higher overall MRR@10, no overall or legacy Coverage@5 regression, and candidate p95 <= baseline p95 × 1.25 + 1 ms on both corpus sizes. This runner additionally rejects Recall@5 regressions and responses above the existing 8 KiB envelope budget. It reports per-query losses even if aggregate metrics pass.

Latency covers synchronous SQLite search including `snippet(memory_fts,1,start,end,'…',48)`, record JSON/schema parsing, byte-aware `bodyExcerpt`, and production response formatting. Random snippet markers follow the production path. Queries use owner/project/session/checkout/lifecycle predicates before limiting, but this all-eligible corpus is not an authorization test. Variants are interleaved and query order rotates. It excludes disk-open time, network/MCP transport, model inference and agent decisions. Index build time includes generating canonical rows and building the FTS index. Canonical rows use a serialized record payload in this harness rather than reproducing all service tables.

## Results

| Records | Variant | MRR@10 | Coverage@5 | Recall@5 | p50 ms | p95 ms | Max response / envelope bytes |
|---:|---|---:|---:|---:|---:|---:|---:|
| 100 | equal | 0.823 | 95.00% | 91.67% | 0.251 | 0.523 | 3061 / 3656 |
| 100 | weighted | 0.890 | 97.50% | 95.42% | 0.269 | 0.552 | 3061 / 3656 |
| 10,000 | equal | 0.794 | 92.50% | 89.17% | 0.327 | 7.055 | 3061 / 3656 |
| 10,000 | weighted | 0.819 | 95.00% | 91.67% | 0.356 | 6.926 | 3061 / 3656 |

| Records | Cohort | Equal / weighted MRR@10 | Equal / weighted Coverage@5 | Equal / weighted Recall@5 |
|---:|---|---:|---:|---:|
| 100 | concise | 1.000 / 1.000 | 100.00% / 100.00% | 100.00% / 100.00% |
| 100 | long | 0.517 / 0.733 | 90.00% / 100.00% | 90.00% / 100.00% |
| 100 | ambiguous | 0.875 / 0.925 | 100.00% / 100.00% | 86.67% / 91.67% |
| 100 | legacy | 0.900 / 0.900 | 90.00% / 90.00% | 90.00% / 90.00% |
| 10,000 | concise | 1.000 / 1.000 | 100.00% / 100.00% | 100.00% / 100.00% |
| 10,000 | long | 0.400 / 0.450 | 80.00% / 90.00% | 80.00% / 90.00% |
| 10,000 | ambiguous | 0.875 / 0.925 | 100.00% / 100.00% | 86.67% / 86.67% |
| 10,000 | legacy | 0.900 / 0.900 | 90.00% / 90.00% | 90.00% / 90.00% |

## Storage and gate details

Weighting does not change stored postings: equal and weighted searches use the same metadata index.

| Records | Content-only FTS bytes | Metadata FTS bytes | Change | Metadata database bytes | Metadata build ms |
|---:|---:|---:|---:|---:|---:|
| 100 | 212992 | 221184 | 3.85% | 442368 | 13.292 |
| 10,000 | 6066176 | 7696384 | 26.87% | 16805888 | 222.006 |

- 100 records: `mrr_improves` pass; `overall_top5_coverage_preserved` pass; `legacy_top5_coverage_preserved` pass; `overall_top5_recall_preserved` pass; `legacy_top5_recall_preserved` pass; `latency_within_budget` pass; `response_budget_preserved` pass. Index measurement: allocated page delta after FTS creation (includes free pages).

- 10,000 records: `mrr_improves` pass; `overall_top5_coverage_preserved` pass; `legacy_top5_coverage_preserved` pass; `overall_top5_recall_preserved` pass; `legacy_top5_recall_preserved` pass; `latency_within_budget` pass; `response_budget_preserved` pass. Index measurement: allocated page delta after FTS creation (includes free pages).

## Per-query evidence

Ranks beyond ten are shown as a miss. Each cell is equal → weighted first-relevant rank.

| ID | Cohort | Query | 100 records | 10,000 records |
|---|---|---|---:|---:|
| c01 | concise | loopback OAuth callback port | 1 → 1 | 1 → 1 |
| c02 | concise | SQLite WAL network filesystem | 1 → 1 | 1 → 1 |
| c03 | concise | IME Enter submit | 1 → 1 | 1 → 1 |
| c04 | concise | tenant cache key leakage | 1 → 1 | 1 → 1 |
| c05 | concise | payment webhook retry idempotency | 1 → 1 | 1 → 1 |
| c06 | concise | CRLF snapshot Windows | 1 → 1 | 1 → 1 |
| c07 | concise | PATH child environment Windows | 1 → 1 | 1 → 1 |
| c08 | concise | certificate hostname mismatch | 1 → 1 | 1 → 1 |
| c09 | concise | nullable column backfill | 1 → 1 | 1 → 1 |
| c10 | concise | JSON stdout logs | 1 → 1 | 1 → 1 |
| l01 | long | archive Windows date locale | 2 → 2 | 3 → 3 |
| l02 | long | Android Java build JDK | 2 → 2 | 2 → 2 |
| l03 | long | worktree merge cleanup | 3 → 2 | 3 → 3 |
| l04 | long | mobile reconnect lease | 1 → 1 | 2 → 2 |
| l05 | long | image EXIF rotation | 2 → 2 | miss → 2 |
| l06 | long | Unicode filename normalization | 2 → 1 | 2 → 2 |
| l07 | long | Postgres advisory migration lock | 2 → 1 | 2 → 2 |
| l08 | long | TypeScript ESM import extension | 1 → 1 | 1 → 1 |
| l09 | long | stream cancellation cleanup | 3 → 1 | 3 → 3 |
| l10 | long | export snapshot consistency | miss → 3 | miss → miss |
| a01 | ambiguous | date formatting | 1 → 1 | 1 → 1 |
| a02 | ambiguous | token renewal | 2 → 1 | 2 → 1 |
| a03 | ambiguous | session expiry | 1 → 1 | 1 → 1 |
| a04 | ambiguous | port collision | 1 → 1 | 1 → 1 |
| a05 | ambiguous | Java configuration | 4 → 4 | 4 → 4 |
| a06 | ambiguous | schema rollback | 1 → 1 | 1 → 1 |
| a07 | ambiguous | stream buffer | 1 → 1 | 1 → 1 |
| a08 | ambiguous | export order | 1 → 1 | 1 → 1 |
| a09 | ambiguous | Windows build | 1 → 1 | 1 → 1 |
| a10 | ambiguous | Unicode search | 1 → 1 | 1 → 1 |
| g01 | legacy | npm ERESOLVE peer | 1 → 1 | 1 → 1 |
| g02 | legacy | SQLITE_BUSY timeout | 1 → 1 | 1 → 1 |
| g03 | legacy | HTTP 429 Retry-After | 1 → 1 | 1 → 1 |
| g04 | legacy | EADDRINUSE 4317 | 1 → 1 | 1 → 1 |
| g05 | legacy | x509 unknown authority | 1 → 1 | 1 → 1 |
| g06 | legacy | CMake Program Files install | 1 → 1 | 1 → 1 |
| g07 | legacy | 東京 タイムゾーン | miss → miss | miss → miss |
| g08 | legacy | 설정 저장 실패 | 1 → 1 | 1 → 1 |
| g09 | legacy | src/parser/token_stream.ts | 1 → 1 | 1 → 1 |
| g10 | legacy | "reset connection" "idle timeout" | 1 → 1 | 1 → 1 |

- 100 records: first-relevant rank regressions: none; per-query Recall@5 regressions: none; candidate misses at ten: g07.

- 10,000 records: first-relevant rank regressions: none; per-query Recall@5 regressions: none; candidate misses at ten: l10, g07.

The Japanese legacy query `g07` uses standalone terms within an unsegmented sentence and remains a lexical miss for both variants. The long export guide (`l10`) falls below ten as many short export-related background records are added. Metadata weighting does not resolve every long-document retrieval miss.

## Limitations

This is a small synthetic lexical benchmark, not a live-agent quality study or evidence of token/tool-call savings. Several concise queries closely match authored titles. Long documents share generated review context and place their distinguishing facts at the beginning; a separate deep-body regression checks the excerpt path beyond those ranking fixtures. Missing semantic synonyms and tokenizer boundaries can remain lexical misses. Background notes are generated, not representative samples of real users' memory stores. Relevance labels are agent-authored and separately agent-reviewed, not an independent human panel.

The excerpt regression places its only query term near the end of a long body: SQLite retrieves it, and the query-aware excerpt includes that term while remaining marked `excerpted`. The opening prefix alone would omit it. A full `memory_get` remains necessary before relying on an incomplete finding, since qualifications elsewhere in the body may be absent. No model or summarizer rewrites it.

Timing is one warm-cache run on a shared machine. The 1 ms absolute allowance is material for small queries, and these measurements should not be presented as cross-platform performance qualification. Title/description weighting can lower individual relevant hits even when average quality improves; per-query evidence and coverage remain part of the decision.

## Environment

```json
{
  "measured_at": "2026-11-10T12:00:32.837Z",
  "platform": "win32",
  "architecture": "x64",
  "bun": "1.3.14",
  "cpu": "12th Gen Intel(R) Core(TM) i5-12400",
  "measured_rounds": 25,
  "samples_per_variant_per_corpus": 1000,
  "formatter_sha256": "b33d39213b311c3198a9bc9dfe0b6fda19a59ce884c8e7e4b24e18729086c1b5"
}
```
