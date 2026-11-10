# Technical memory retrieval evaluation

Measured 2026-11-10T13:50:28.414Z; run `2026-11-10T13-45-03-597Z-technical-all`. Local retrieval only: zero model calls and zero API cost.

## Reproduce

Run from the repository root. The public dataset requires Python, curl and an isolated DuckDB reader; fixture-only runs do not need that reader. Install it once:

```powershell
python -m pip install --only-binary=:all: --no-deps --target .tmp/memory-public-evaluation/python duckdb==1.4.3
```

```powershell
bun run --filter antgrid-memory evaluate:technical --dataset all --queries 200 --rounds 3
```

Caches and per-query JSONL stay under ignored `.tmp/memory-public-evaluation`. Isolated production-schema stores are deleted after each group; user memory is never opened. See the [public retrieval evaluation](memory-public-retrieval-evaluation.md) for the general benchmarks.

## What this measures

The controlled fixtures test strict record lookup by names, technical literals, casing and quoted phrases. Every member of a confusable family is queried, so a lucky ID tie-break cannot make an entire family pass. All families share one corpus with the same prose template. An independent control corpus replaces each entire name with a unique alphanumeric token; IDs, template, relevance and metadata placement stay the same. Controls establish exact-token lookup, not an equivalent natural-language workload: token counts and document lengths necessarily differ. These deliberately adversarial cases are not an estimate of production failure frequency.

The literal, quoted and casing cohorts expect the exact named record. Accent-folded spelling variants are intentionally distinct fixture records; this strict identity test does not imply that accent folding is inappropriate for ordinary person-name search. Alias/identifier-part probes separately report whether a specific candidate appears, without assigning complete relevance labels or computing accuracy. Other returned records may be relevant; these probes do not claim alias matching is currently promised by the lexical search contract. No descriptions, embeddings, query rewriting or model-generated text are used.

Body-only, equal metadata weighting, and production title/description weights (4/2) use the same production service and 8 KiB agent response budget as the earlier public evaluation. Source titles remain in the body in every variant. Top-1 exact-target accuracy and MRR expose ambiguity that Recall@5 can hide when several siblings all fit in five results. Full IDs and generated FTS queries are retained per case. Query syntax and punctuation distinctions are evaluated as shipped; this run makes no production tokenizer or weighting changes.

Latency uses one warm-up plus 3 timed searches per query/variant, with rotated variant order. It includes service validation, SQL and response formatting, but excludes downloads, store construction, network/MCP transport and models. Percentiles describe successfully timed searches; a failure in the preceding raw-search step has no latency samples and still counts as a relevance miss. Warm-cache timings on this one Windows machine do not qualify other platforms.

## Controlled diagnostics

Each corpus contains 80 records and 240 queries. The table shows production weights; all variants and controls are in the JSON report.

| Query cohort | Queries | Exact target top 1 | Delivered Recall@5 | Raw MRR@10 | Opaque control top 1 | p95 ms |
|---|---:|---:|---:|---:|---:|---:|
| literal/languages | 8 | 62.50% | 100.00% | 0.792 | 100.00% | 0.96 |
| phrase/languages | 8 | 62.50% | 100.00% | 0.792 | 100.00% | 0.84 |
| casefold/languages | 8 | 62.50% | 100.00% | 0.792 | 100.00% | 0.68 |
| literal/runtimes | 6 | 66.67% | 100.00% | 0.833 | 100.00% | 0.55 |
| phrase/runtimes | 6 | 66.67% | 100.00% | 0.833 | 100.00% | 0.34 |
| casefold/runtimes | 6 | 66.67% | 100.00% | 0.833 | 100.00% | 0.55 |
| literal/packages | 6 | 83.33% | 100.00% | 0.917 | 100.00% | 0.64 |
| phrase/packages | 6 | 83.33% | 100.00% | 0.917 | 100.00% | 0.48 |
| casefold/packages | 6 | 83.33% | 100.00% | 0.917 | 100.00% | 0.62 |
| literal/errors | 6 | 83.33% | 100.00% | 0.917 | 100.00% | 0.63 |
| phrase/errors | 6 | 83.33% | 100.00% | 0.917 | 100.00% | 0.31 |
| casefold/errors | 6 | 83.33% | 100.00% | 0.917 | 100.00% | 0.66 |
| literal/versions | 6 | 16.67% | 83.33% | 0.408 | 100.00% | 0.62 |
| phrase/versions | 6 | 100.00% | 100.00% | 1.000 | 100.00% | 0.31 |
| casefold/versions | 6 | 16.67% | 83.33% | 0.408 | 100.00% | 0.60 |
| literal/paths | 6 | 66.67% | 100.00% | 0.806 | 100.00% | 0.71 |
| phrase/paths | 6 | 100.00% | 100.00% | 1.000 | 100.00% | 0.33 |
| casefold/paths | 6 | 66.67% | 100.00% | 0.806 | 100.00% | 0.68 |
| literal/camelCase | 6 | 100.00% | 100.00% | 1.000 | 100.00% | 0.28 |
| phrase/camelCase | 6 | 100.00% | 100.00% | 1.000 | 100.00% | 0.22 |
| casefold/camelCase | 6 | 100.00% | 100.00% | 1.000 | 100.00% | 0.33 |
| literal/snake_case | 6 | 50.00% | 100.00% | 0.681 | 100.00% | 0.71 |
| phrase/snake_case | 6 | 100.00% | 100.00% | 1.000 | 100.00% | 0.43 |
| casefold/snake_case | 6 | 50.00% | 100.00% | 0.681 | 100.00% | 0.82 |
| literal/protocols | 6 | 100.00% | 100.00% | 1.000 | 100.00% | 0.67 |
| phrase/protocols | 6 | 100.00% | 100.00% | 1.000 | 100.00% | 0.36 |
| casefold/protocols | 6 | 100.00% | 100.00% | 1.000 | 100.00% | 0.77 |
| literal/names | 6 | 100.00% | 100.00% | 1.000 | 100.00% | 0.42 |
| phrase/names | 6 | 100.00% | 100.00% | 1.000 | 100.00% | 0.17 |
| casefold/names | 6 | 100.00% | 100.00% | 1.000 | 100.00% | 0.45 |
| literal/unicode | 6 | 66.67% | 100.00% | 0.833 | 100.00% | 0.22 |
| phrase/unicode | 6 | 66.67% | 100.00% | 0.833 | 100.00% | 0.31 |
| casefold/unicode | 6 | 66.67% | 100.00% | 0.833 | 100.00% | 0.25 |
| literal/products | 6 | 100.00% | 100.00% | 1.000 | 100.00% | 0.22 |
| phrase/products | 6 | 100.00% | 100.00% | 1.000 | 100.00% | 0.30 |
| casefold/products | 6 | 100.00% | 100.00% | 1.000 | 100.00% | 0.24 |
| literal/uuids | 6 | 100.00% | 100.00% | 1.000 | 100.00% | 0.42 |
| phrase/uuids | 6 | 100.00% | 100.00% | 1.000 | 100.00% | 0.21 |
| casefold/uuids | 6 | 100.00% | 100.00% | 1.000 | 100.00% | 0.41 |

### Unscored identifier probes

These check candidate presence, not whether every other result is irrelevant.

| Query | Desired candidate | Present in raw top 10 | Generated FTS |
|---|---|---|---|
| `retry` | `maxRetryCount` | No | `"retry"` |
| `max retry count` | `maxRetryCount` | No | `"max" OR "retry" OR "count"` |
| `max_retry_count` | `maxRetryCount` | No | `"max" OR "retry" OR "count"` |
| `Open Telemetry` | `OpenTelemetry` | No | `"Open" OR "Telemetry"` |
| `Postgres` | `PostgreSQL` | No | `"Postgres"` |

## Public programming-question pilot

CQADupStack programmers tests retrieval of duplicate programming questions using upstream positive qrels. The deterministic SHA-256 query selection is fixed before scoring and keeps the complete corpus. Oversized queries are reported and fail validation rather than being silently truncated. Bodies exceeding 16 KiB are split without dropping source text; a hit on any chunk is credited to its source question, so these are question-location metrics rather than proof that a returned excerpt contains an answer. Duplicate chunks consume rank slots without increasing source recall. Optional source titles repeat on every chunk, while the full original title occurs once in the partitioned body: the ablation holds source information constant, not per-chunk text. All queries are upstream text, not synthetic names or generated paraphrases.

This pilot establishes a technical-domain baseline, not the causal effect of technical terminology: there is no equivalent nontechnical rewrite of these questions. Unlabelled results are not proven irrelevant; labels are the dataset's known duplicate links. Scores are not comparable to QA, coding-task success or vendor end-to-end memory scores.

| Variant | Queries | Delivered Coverage@5 | Delivered Recall@5 | Raw MRR@10 | Raw Recall@10 | p50 / p95 ms | Errors |
|---|---:|---:|---:|---:|---:|---:|---:|
| body | 200 | 32.00% | 28.83% | 0.238 | 33.23% | 87.90 / 139.72 | 0 |
| equal | 200 | 33.50% | 30.25% | 0.247 | 33.65% | 90.70 / 140.25 | 0 |
| weighted | 200 | 31.50% | 28.42% | 0.256 | 32.73% | 90.84 / 145.97 | 0 |

Review of this run: production weights improve raw MRR but reduce delivered Recall@5 by 1.83 percentage points relative to equal weights. These results do not establish a general weighting improvement or robust technical-name retrieval. No production search behavior was changed in response to this pilot.

Independent audits reconstructed the source chunks and fixed query selection and reproduced every reported metric across 600 public and 1,440 controlled query/variant pairs. Audit artifacts are `independent-public-audit.json` and `independent-fixture-audit.json` beside the run report. Byte checks verify recorded counters; full response payloads were not retained. The affected memory package's 85 tests and TypeScript typecheck passed.

## Limits and follow-up

The lexical representation loses some meaningful distinctions: `C++`, `C#` and `C` produce the same query; unquoted version/path components become alternatives; camelCase stays a single token. Weight changes cannot recover discarded symbols or candidate records absent from the index. Quoting preserves token order but does not restore discarded punctuation. A separate technical-literal indexing/matching signal and explicit identifier-part aliases should be evaluated before claiming robust technical-name retrieval. Globally treating punctuation as word characters could regress ordinary prose and component searches.

A successful process exit means the measurements completed without service errors, not that a technical-name quality gate passed. The diagnostics expose known unresolved retrieval gaps; no production fix or release qualification is claimed.

Errors across measured query/variant pairs: 0. Largest serialized agent MCP envelope including allowance: 8178 bytes (limit 8192). Every error remains in the JSONL and counts as a miss. No automatic-save or coding qualification was run.

## Provenance

```json
{
  "version": 1,
  "runId": "2026-11-10T13-45-03-597Z-technical-all",
  "measuredAt": "2026-11-10T13:50:28.414Z",
  "rounds": 3,
  "modelCalls": 0,
  "apiCostUsd": 0,
  "qualification": "Diagnostic measurement only; successful process exit does not qualify technical-name retrieval",
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
    "evaluation/public/technical-fixtures.ts": "8019f0597460ac3f3a4a41a9fd781f5261b5699dbf776763f3aab69b4104488e",
    "evaluation/public/technical-dataset.ts": "41e72250f915e688dc2c88e55f899039783d5e6bf43efc560aa9cbfe83548956",
    "evaluation/public/run-technical.ts": "f323852093f9b2dba787f6314a499bac967064f874ad52f40cfad53e1d523f10"
  },
  "fixtureDocuments": 80,
  "identifierProbes": [
    {
      "query": "retry",
      "target": "maxRetryCount",
      "generated": "\"retry\"",
      "foundInRaw10": false,
      "rawIds": [
        "4f741599-9ffe-e06c-1622-46aeb3f705ff",
        "5cda57f9-b15a-a14c-4a95-ef1e62cfe00d",
        "7cf13d32-b1f3-17d2-214b-9d6d8b8c12d8",
        "7d1e868a-f052-41d6-f559-be1d392c42d3",
        "94c973c8-793d-904f-59be-389bf6f06dd2",
        "af04df6f-c9b8-ffd1-9804-c3bdac0b5550"
      ]
    },
    {
      "query": "max retry count",
      "target": "maxRetryCount",
      "generated": "\"max\" OR \"retry\" OR \"count\"",
      "foundInRaw10": false,
      "rawIds": [
        "4f741599-9ffe-e06c-1622-46aeb3f705ff",
        "7cf13d32-b1f3-17d2-214b-9d6d8b8c12d8",
        "7d1e868a-f052-41d6-f559-be1d392c42d3",
        "af04df6f-c9b8-ffd1-9804-c3bdac0b5550",
        "5cda57f9-b15a-a14c-4a95-ef1e62cfe00d",
        "94c973c8-793d-904f-59be-389bf6f06dd2"
      ]
    },
    {
      "query": "max_retry_count",
      "target": "maxRetryCount",
      "generated": "\"max\" OR \"retry\" OR \"count\"",
      "foundInRaw10": false,
      "rawIds": [
        "4f741599-9ffe-e06c-1622-46aeb3f705ff",
        "7cf13d32-b1f3-17d2-214b-9d6d8b8c12d8",
        "7d1e868a-f052-41d6-f559-be1d392c42d3",
        "af04df6f-c9b8-ffd1-9804-c3bdac0b5550",
        "5cda57f9-b15a-a14c-4a95-ef1e62cfe00d",
        "94c973c8-793d-904f-59be-389bf6f06dd2"
      ]
    },
    {
      "query": "Open Telemetry",
      "target": "OpenTelemetry",
      "generated": "\"Open\" OR \"Telemetry\"",
      "foundInRaw10": false,
      "rawIds": []
    },
    {
      "query": "Postgres",
      "target": "PostgreSQL",
      "generated": "\"Postgres\"",
      "foundInRaw10": false,
      "rawIds": []
    }
  ],
  "public": {
    "manifest": {
      "dataset": "BEIR CQADupStack programmers",
      "variant": "test",
      "sourceUrl": "https://huggingface.co/datasets/BeIR/cqadupstack",
      "revision": "e84b7220ce5a4e6c49aeb568983b0ec5a7584c2c",
      "qrelsRevision": "13595a9f221256a9a21e91c8b0fed3563382b6a7",
      "sourceMethod": "Checksum-verified official Parquet files; deterministic _id-order JSONL includes only original ID, title and text",
      "reader": {
        "name": "duckdb",
        "version": "1.4.3",
        "installation": "Isolated evaluation directory; no global environment changes"
      },
      "sourceFiles": {
        "corpus": {
          "name": "corpus.parquet",
          "size": 20111039,
          "sha256": "b8eefa212252fe5af6ee72ba530df053740ff30c2c0bea77089f8a9271e94f75",
          "url": "https://huggingface.co/datasets/BeIR/cqadupstack/resolve/e84b7220ce5a4e6c49aeb568983b0ec5a7584c2c/programmers/corpus/corpus-00000-of-00001.parquet"
        },
        "queries": {
          "name": "queries.parquet",
          "size": 41633,
          "sha256": "106ba4777034ccec608a623ac93b5cfad63d89effc64d0528759ea94e276345d",
          "url": "https://huggingface.co/datasets/BeIR/cqadupstack/resolve/e84b7220ce5a4e6c49aeb568983b0ec5a7584c2c/programmers/queries/queries-00000-of-00001.parquet"
        },
        "qrels": {
          "name": "test.tsv",
          "size": 27053,
          "sha256": "ed69afa873c64d34298792d694c82c4293e4b7e3c6ea3edc7a73662d4b0cba76",
          "url": "https://huggingface.co/datasets/BeIR/cqadupstack-qrels/resolve/13595a9f221256a9a21e91c8b0fed3563382b6a7/programmers/test.tsv"
        }
      },
      "files": {
        "corpus.jsonl": {
          "sha256": "cb91fd1bfae2220559bbcede0bcb4994b785881ed55346507a497ee30ae0ff33",
          "bytes": 35249481
        },
        "queries.jsonl": {
          "sha256": "49ad45f0ac82863a84f3ede8deb9c90ff419ffc3c7fc364a3efd16efde07c589",
          "bytes": 71745
        },
        "test.tsv": {
          "sha256": "ed69afa873c64d34298792d694c82c4293e4b7e3c6ea3edc7a73662d4b0cba76",
          "bytes": 27053
        }
      },
      "sourceDocuments": 32176,
      "documents": 32180,
      "queries": 876,
      "unsupportedQueries": [],
      "queryCorpusOverlap": 0,
      "selfRelevantQueries": 0,
      "chunking": {
        "maxBytes": 16384,
        "version": "original-title-body-utf8-v1"
      },
      "metadata": "Original title and body are partitioned without truncation in every variant; optional source title is UTF-8 capped at 256 bytes; no query-derived or generated metadata"
    },
    "selection": {
      "method": "Lowest SHA-256(seed:query-id), selected before scoring; complete corpus retained",
      "seed": "antgrid-cqadupstack-programmers-pilot-v1",
      "availableQueries": 876,
      "selectedQueries": 200,
      "ids": [
        "36297",
        "155469",
        "201237",
        "50755",
        "663",
        "123851",
        "193415",
        "95637",
        "236370",
        "211276",
        "6476",
        "141411",
        "171701",
        "84638",
        "210637",
        "32425",
        "210623",
        "178018",
        "78431",
        "130256",
        "130335",
        "201119",
        "244866",
        "94932",
        "54959",
        "77731",
        "20684",
        "210346",
        "211610",
        "234962",
        "234001",
        "246066",
        "66834",
        "222464",
        "137344",
        "57068",
        "108292",
        "218184",
        "136195",
        "216301",
        "240454",
        "66764",
        "203776",
        "95933",
        "97338",
        "213452",
        "250953",
        "219198",
        "232812",
        "175594",
        "178916",
        "251756",
        "940",
        "29109",
        "223815",
        "120488",
        "233615",
        "204443",
        "98324",
        "140561",
        "204938",
        "200360",
        "221365",
        "189983",
        "64671",
        "81838",
        "221615",
        "36961",
        "210532",
        "213173",
        "218447",
        "211678",
        "189426",
        "3747",
        "200861",
        "190955",
        "111633",
        "117825",
        "43086",
        "26030",
        "94024",
        "210049",
        "145722",
        "210864",
        "84909",
        "103263",
        "122437",
        "209857",
        "215248",
        "57047",
        "78903",
        "255031",
        "121218",
        "205279",
        "193895",
        "136449",
        "180165",
        "21403",
        "165668",
        "122244",
        "111846",
        "255912",
        "224835",
        "233503",
        "93124",
        "195337",
        "8544",
        "44959",
        "85691",
        "91629",
        "234820",
        "32571",
        "177907",
        "32956",
        "198549",
        "208976",
        "221030",
        "97832",
        "132281",
        "9813",
        "176102",
        "78956",
        "116491",
        "250203",
        "131381",
        "97511",
        "750",
        "190758",
        "18679",
        "204206",
        "247382",
        "216195",
        "124817",
        "175583",
        "142292",
        "36175",
        "24170",
        "180012",
        "59606",
        "20092",
        "175014",
        "85019",
        "76801",
        "34559",
        "105380",
        "154155",
        "207815",
        "39378",
        "241389",
        "147240",
        "125252",
        "204840",
        "117766",
        "165735",
        "24542",
        "119367",
        "111881",
        "108395",
        "87082",
        "202273",
        "233592",
        "12773",
        "165725",
        "176471",
        "159089",
        "212932",
        "23313",
        "215474",
        "96504",
        "208867",
        "175309",
        "233981",
        "235468",
        "201041",
        "196615",
        "227818",
        "144717",
        "113209",
        "93848",
        "54373",
        "84778",
        "230604",
        "167277",
        "179162",
        "215727",
        "107774",
        "138726",
        "35610",
        "41981",
        "158397",
        "81131",
        "220872",
        "52961",
        "190542",
        "191191",
        "144058",
        "102008",
        "224752",
        "100959",
        "98691"
      ],
      "idsSha256": "66f88b261df8d8ee3b913c69a0157f7374aafdd2d1b065473e82a48a8edf893d"
    },
    "variants": {
      "body": {
        "queries": 200,
        "answerable": 200,
        "unanswerable": 0,
        "errors": 0,
        "raw": {
          "mrr10": 0.23824801587301592,
          "coverage5": 0.32,
          "recall5": 0.28833333333333333,
          "recall10": 0.33226190476190476,
          "allEvidence5": 0.26,
          "ndcg10": 0.2486420172594745
        },
        "delivered": {
          "mrr10": 0.23158333333333336,
          "coverage5": 0.32,
          "recall5": 0.28833333333333333,
          "recall10": 0.28833333333333333,
          "allEvidence5": 0.26,
          "ndcg10": 0.23287408009464197
        },
        "latencyMs": {
          "p50": 87.90299999999115,
          "p95": 139.7207000000053,
          "samples": 600
        },
        "maxResponseBytes": 7575,
        "maxEnvelopeBytes": 8160
      },
      "equal": {
        "queries": 200,
        "answerable": 200,
        "unanswerable": 0,
        "errors": 0,
        "raw": {
          "mrr10": 0.24695436507936516,
          "coverage5": 0.335,
          "recall5": 0.3025,
          "recall10": 0.3364621284755513,
          "allEvidence5": 0.27,
          "ndcg10": 0.25725267685549197
        },
        "delivered": {
          "mrr10": 0.24125000000000008,
          "coverage5": 0.335,
          "recall5": 0.3025,
          "recall10": 0.3025,
          "allEvidence5": 0.27,
          "ndcg10": 0.24433935981660518
        },
        "latencyMs": {
          "p50": 90.7044000000169,
          "p95": 140.24669999998878,
          "samples": 600
        },
        "maxResponseBytes": 7579,
        "maxEnvelopeBytes": 8178
      },
      "weighted": {
        "queries": 200,
        "answerable": 200,
        "unanswerable": 0,
        "errors": 0,
        "raw": {
          "mrr10": 0.2563174603174604,
          "coverage5": 0.315,
          "recall5": 0.2841666666666666,
          "recall10": 0.32729546180888464,
          "allEvidence5": 0.255,
          "ndcg10": 0.2614721664599665
        },
        "delivered": {
          "mrr10": 0.2480833333333334,
          "coverage5": 0.315,
          "recall5": 0.2841666666666666,
          "recall10": 0.2841666666666666,
          "allEvidence5": 0.255,
          "ndcg10": 0.24452344768460268
        },
        "latencyMs": {
          "p50": 90.84390000000712,
          "p95": 145.9702999999863,
          "samples": 600
        },
        "maxResponseBytes": 7579,
        "maxEnvelopeBytes": 8176
      }
    }
  }
}
```

Sources: [CQADupStack authors](https://github.com/D1Doris/CQADupStack), [official BEIR dataset](https://huggingface.co/datasets/BeIR/cqadupstack), [SQLite FTS5 unicode61](https://sqlite.org/fts5.html#unicode61_tokenizer).
