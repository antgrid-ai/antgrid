# Public memory retrieval evaluation

Measured 2026-11-10T13:00:33.579Z; run `2026-11-10T12-55-48-952Z-all`. No model inference or paid API calls in this retrieval run.

## Reproduce

```powershell
bun run --filter antgrid-memory evaluate:public --dataset all --rounds 3
```

Downloads stay under ignored `.tmp/memory-public-evaluation/datasets`; fixed source checksums reject drift. Each run writes a separate manifest, per-query JSONL and Markdown report under `.tmp/memory-public-evaluation/runs`. The latest requested dataset selection is copied to this document. No user memory store is read or changed.

## Protocol fixed before scoring

This is a retrieval-only evaluation of production MemoryService search, validation, FTS5 ranking, snippets and response formatting. Offline fixtures populate the production schema with deterministic IDs and validated/redacted records; they bypass automatic agent extraction, save receipts and duplicate suppression. It does not measure agent saving, QA accuracy, coding outcomes, MCP transport latency or savings in model tokens.

The three variants are body-only (metadata omitted), equal weights with metadata, and current production weights (title 4, description 2, body/applicability 1). All retain the same source information in the body. SciFact uses source-authored titles, duplicated into its optional title field. LongMemEval titles are query-blind `Conversation on <session date>` labels; dates also remain in each body. No descriptions or model summaries are generated. This tests source titles and date labels, not the quality of agent-written descriptions.

LongMemEval uses all 500 cleaned S instances in separate stores: the 30 abstention cases are searched and timed but excluded from relevance denominators. Original evidence flags/answer-prefixed IDs never enter records. Sessions exceeding 16 KiB are split deterministically at turn/UTF-8 boundaries. Relevance is scored against upstream evidence-session IDs after neutral remapping. A hit on any chunk of an evidence session is credited even if that chunk or returned excerpt lacks the answer; this is an optimistic session-location metric, not answer evidence verification. Duplicate source-session hits never increase recall.

SciFact uses the complete BEIR test qrels and corpus. Original titles and abstracts remain in each body for every variant; only title indexing/weighting differs. Upstream binary relevance labels are unchanged. Gold answers and qrels stay outside the stores. Queries are the original question/claim text; LongMemEval question dates remain separate metadata for future QA and are not appended to retrieval queries. There is no query rewriting, stopword removal, tuning on results or semantic search.

Raw MRR@10, nDCG@10 and Recall@10 use up to ten ranked records through the app inspection path. Delivered Recall@5, Coverage@5 and All-evidence@5 use the actual agent response with a five-record limit and 8 KiB serialized MCP-envelope budget. Chunk duplicates consume result slots; we do not retrieve extra chunks to manufacture five distinct sessions. These metrics are not directly comparable to vendor QA percentages or top-200 retrieval. LongMemEval has session-level evidence labels, so nDCG credits at most one new evidence source per returned chunk.

Variant order rotates across queries/groups. Each pair has one warm-up followed by 3 timed searches; timing includes service queue/validation/SQL/serialization but excludes fixture build, dataset download, HTTP, MCP and model work. Latency is a warm-cache measurement on this one Windows machine, not cross-platform qualification. Errors count as misses and are reported; no failed queries are silently dropped.

## Results

| Dataset | Variant | Answerable / total | Delivered Coverage@5 | Delivered Recall@5 | All-evidence@5 | Raw MRR@10 | Raw nDCG@10 | Raw Recall@10 | p50 / p95 ms | Errors |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| scifact | body | 300 / 300 | 75.67% | 73.09% | 70.33% | 0.635 | 0.668 | 79.56% | 19.886 / 30.142 | 0 |
| scifact | equal | 300 / 300 | 75.33% | 72.93% | 70.33% | 0.645 | 0.676 | 79.23% | 21.157 / 33.992 | 0 |
| scifact | weighted | 300 / 300 | 74.67% | 72.09% | 69.33% | 0.647 | 0.677 | 79.56% | 21.065 / 33.247 | 0 |
| longmemeval | body | 470 / 500 | 96.38% | 90.85% | 82.55% | 0.911 | 0.898 | 95.15% | 5.850 / 25.441 | 0 |
| longmemeval | equal | 470 / 500 | 96.38% | 90.85% | 82.55% | 0.911 | 0.898 | 95.15% | 5.790 / 25.470 | 0 |
| longmemeval | weighted | 470 / 500 | 96.38% | 90.85% | 82.55% | 0.911 | 0.898 | 95.15% | 5.825 / 25.281 | 0 |

## Response budgets

| Dataset | Variant | Max response bytes | Max MCP envelope + 256-byte allowance |
|---|---|---:|---:|
| scifact | body | 7630 | 8191 |
| scifact | equal | 7607 | 8190 |
| scifact | weighted | 7609 | 8192 |
| longmemeval | body | 7555 | 8174 |
| longmemeval | equal | 7530 | 8182 |
| longmemeval | weighted | 7530 | 8182 |

## Category results

| Dataset/category | Variant | Answerable queries | Delivered Recall@5 | Raw MRR@10 |
|---|---|---:|---:|---:|
| scifact/scientific-claim | body | 300 | 73.09% | 0.635 |
| scifact/scientific-claim | equal | 300 | 72.93% | 0.645 |
| scifact/scientific-claim | weighted | 300 | 72.09% | 0.647 |
| longmemeval/single-session-user | body | 64 | 100.00% | 0.960 |
| longmemeval/single-session-user | equal | 64 | 100.00% | 0.960 |
| longmemeval/single-session-user | weighted | 64 | 100.00% | 0.960 |
| longmemeval/multi-session | body | 121 | 83.48% | 0.911 |
| longmemeval/multi-session | equal | 121 | 83.48% | 0.911 |
| longmemeval/multi-session | weighted | 121 | 83.48% | 0.911 |
| longmemeval/single-session-preference | body | 30 | 80.00% | 0.638 |
| longmemeval/single-session-preference | equal | 30 | 80.00% | 0.640 |
| longmemeval/single-session-preference | weighted | 30 | 80.00% | 0.640 |
| longmemeval/temporal-reasoning | body | 127 | 87.39% | 0.879 |
| longmemeval/temporal-reasoning | equal | 127 | 87.39% | 0.879 |
| longmemeval/temporal-reasoning | weighted | 127 | 87.39% | 0.879 |
| longmemeval/knowledge-update | body | 72 | 98.61% | 0.970 |
| longmemeval/knowledge-update | equal | 72 | 98.61% | 0.970 |
| longmemeval/knowledge-update | weighted | 72 | 98.61% | 0.970 |
| longmemeval/single-session-assistant | body | 56 | 100.00% | 1.000 |
| longmemeval/single-session-assistant | equal | 56 | 100.00% | 1.000 |
| longmemeval/single-session-assistant | weighted | 56 | 100.00% | 1.000 |

## Interpretation

Review of run `2026-11-10T12-55-48-952Z-all`: weighted versus equal ranking raised
SciFact raw MRR@10 from 0.64538 to 0.64721, while delivered Recall@5 fell from
72.9278% to 72.0944% (0.8333 percentage points). LongMemEval's equal and weighted
relevance metrics were identical. These results do not establish a general
retrieval-quality improvement from the fixed metadata weights. They show a
small ranking/coverage trade-off on SciFact and no aggregate benefit from date
title weighting on LongMemEval. Agent-authored descriptions remain unevaluated.

These public results supplement the internal 40-query synthetic regression suite. They do not establish release readiness, automatic-save behavior or universal superiority of a weighting scheme. No production weights were changed in response to these scores. Public history/document corpora differ from concise agent-authored findings; source-title/date ablations cannot establish the benefit of generated descriptions. Per-query changes and failures are retained in the run artifacts.

Model-based LoCoMo/LongMemEval QA and VibeMemBench coding runs were not run: the user selected local retrieval only. The earlier isolated authentication probe is recorded separately and is not part of these zero-model retrieval measurements.

An independent post-run audit reconstructed all 27,090 LongMemEval chunk-to-source
mappings and SciFact relevance labels without importing the loader or scoring
function. All 2,400 per-query/variant rows and their aggregates matched within
1e-12. The audit found no unknown IDs, dropped queries, query errors or envelope
violations. LongMemEval equal/weighted rankings differed for six queries even
though relevance scores matched. The run directory retains
`independent-audit.json`. Harness verification passed 76 memory package tests,
the package typecheck, and six coding-preflight guard tests. This review records
this run; regenerated reports need a fresh audit before carrying this claim.

## Provenance

```json
{
  "version": 1,
  "runId": "2026-11-10T12-55-48-952Z-all",
  "measuredAt": "2026-11-10T13:00:33.579Z",
  "rounds": 3,
  "operatingSystem": "win32",
  "architecture": "x64",
  "bun": "1.3.14",
  "cpu": "12th Gen Intel(R) Core(TM) i5-12400",
  "sourceSha256": {
    "src/contracts.ts": "1741f665a028343e687f50ee0c155405c65f26df2cbe76b15ba941272d0766eb",
    "src/search.ts": "b33d39213b311c3198a9bc9dfe0b6fda19a59ce884c8e7e4b24e18729086c1b5",
    "src/service.ts": "a986c6c978c1be1a441117bd2e44198766278ee12d65ee324239bb2fdfeb9991",
    "src/store.ts": "de93384da4dccd05a701c9873a852511b30059ab0091576d4502da794acb95d5",
    "evaluation/public/retrieval.ts": "cf393f0bc297d0475542336070a50f216ef276a7a6d6258a879507c172b90de8",
    "evaluation/public/longmemeval.ts": "73ffbc21aab623c1cd9129334cff267f690384b649a1795e5b3c37654dcd8a45",
    "evaluation/public/scifact.ts": "bb7e3cfa6ccffaaf42425f3e1d5928ada6ddc7ba5fa0e03d52067d1ad04ebea6",
    "evaluation/public/run.ts": "eb2c1c183dfd8b1d0fb9256a120e4986a7163cc250790a3c0ab2e11bb4c7c7bc"
  },
  "modelCalls": 0,
  "apiCostUsd": 0,
  "results": [
    {
      "dataset": "scifact",
      "manifest": {
        "dataset": "BEIR SciFact",
        "variant": "test",
        "sourceUrl": "https://public.ukp.informatik.tu-darmstadt.de/thakur/BEIR/datasets/scifact.zip",
        "upstreamMd5": "5f7d1de60b170fc8027bb7898e2efca1",
        "sha256": "536e14446a0ba56ed1398ab1055f39fe852686ecad24a6306c80c490fa8e0165",
        "sourceBytes": 2816079,
        "files": {
          "corpus.jsonl": "dec31c8182f3d744c7d2c09423756fd1d17cbef75808db13ba01cc0aab4d1ac6",
          "queries.jsonl": "8ff84a7c903f722981cd8d595c022660140c51867b27608a6d4910db86080313",
          "test.tsv": "0864bb985e0ca2367ba217977e72004d549054b2b06666ed9d4825ac7c21284c"
        },
        "documents": 5183,
        "queries": 300,
        "metadata": "Source title duplicated into optional title (UTF-8 capped); all variants retain original title and abstract in body; no description generation"
      },
      "changedQueries": 32
    },
    {
      "dataset": "longmemeval",
      "manifest": {
        "dataset": "LongMemEval",
        "variant": "S-cleaned",
        "sourceUrl": "https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned/resolve/98d7416c24c778c2fee6e6f3006e7a073259d48f/longmemeval_s_cleaned.json",
        "revision": "98d7416c24c778c2fee6e6f3006e7a073259d48f",
        "sha256": "d6f21ea9d60a0d56f34a05b609c79c88a451d2ae03597821ea3d5a9678c3a442",
        "sourceBytes": 277383467,
        "preparedAt": "2026-11-10T12:58:29.744Z",
        "groups": 500,
        "documents": 27090,
        "queries": 500,
        "answerableQueries": 470,
        "unanswerableQueries": 30,
        "chunking": {
          "maxBytes": 16384,
          "version": "session-turn-utf8-v1"
        }
      },
      "changedQueries": 0
    }
  ]
}
```

Sources: [LongMemEval](https://github.com/xiaowu0162/LongMemEval), [cleaned data](https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned), [BEIR](https://github.com/beir-cellar/beir), [SciFact](https://github.com/allenai/scifact).
