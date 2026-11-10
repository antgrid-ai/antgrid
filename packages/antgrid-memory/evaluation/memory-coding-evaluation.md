# Memory coding-benefit evaluation: not run

The user selected **local retrieval evaluation only** on 2026-11-10. No VibeMemBench coding agents, matched memory-on/off pairs, or executable task evaluations ran. This track made no model calls, downloaded no history trajectories, and pulled no Docker images. Retrieval scores elsewhere in this repository do not demonstrate an improvement in coding-task resolution.

## Public benchmark inspected

[VibeMemBench](https://github.com/AlibabaResearch/DAMO-ConvAI/tree/faf754671f5b850e1b4d1ff870db37a6a2480df6/VibeMemBench) evaluates repository work using matched memory-on/off agent runs and executable tests. Its [dataset](https://huggingface.co/datasets/Tongyi-ConvAI/VibeMemBench/tree/11164976b4f920cdb0d0cd570ca572e49acea1e8) provides target metadata and prior agent trajectories. The official setup uses a pinned mini-swe-agent and Docker task images; see the [reference setup and pipeline](https://github.com/AlibabaResearch/DAMO-ConvAI/blob/faf754671f5b850e1b4d1ff870db37a6a2480df6/VibeMemBench/README.md).

Discovery pins:

| Artifact | Revision |
|---|---|
| DAMO-ConvAI source | `faf754671f5b850e1b4d1ff870db37a6a2480df6` |
| Tongyi-ConvAI/VibeMemBench dataset | `11164976b4f920cdb0d0cd570ca572e49acea1e8` |
| Official mini-swe-agent | `bc85a45654e6348dcc6e4c5a40ad146ed0bb144d` |

The public target viewer returned 111 complete rows in two responses totaling 3,336,073 bytes. Only metadata and selected official source files were downloaded into ignored `.tmp/vibemem-inspect/`; the large history corpus was not downloaded. Viewer responses are not revision-addressed. Before any future execution, load `test.parquet` from the pinned dataset revision and rederive the selection, requiring exact agreement with the IDs and execution metadata in the discovery manifest.

## Proposed bounded subset

The unexecuted discovery rule chooses the numerically earliest Python issue in each repository, orders repositories case-insensitively, and takes the first three. Selection does not inspect gold patches, test outcomes, difficulty labels, or retrieved-memory success.

| Target | Eligible earlier histories | Excluded own/future histories |
|---|---:|---:|
| `adamchainz__flake8-comprehensions-553` | 6 | 1 |
| `aio-libs__aiohttp-7907` | 25 | 103 |
| `alteryx__woodwork-640` | 5 | 34 |

[vibemem-manifest.json](public/vibemem-manifest.json) records source revisions, exact target commits/image tags, eligible history paths, metadata-file hashes, and the measured runtime state. These history counts come from filenames, not downloaded trajectories. Image sizes and immutable image digests remain unverified.

Any later coding evaluation must preserve the [official visibility contract](https://github.com/AlibabaResearch/DAMO-ConvAI/blob/faf754671f5b850e1b4d1ff870db37a6a2480df6/VibeMemBench/scripts/CONTRACT.md): history must come from the same repository and a strictly smaller trailing issue number. The target's own and future trajectories are excluded. Gold patches, test patches, scoring test lists, and hidden provenance stay evaluator-side. Never expose the raw viewer cache or evaluator files to a solver. Build any extracted memory from eligible history before showing the target query; do not write target-specific hindsight summaries. Hold the solver, tools, sandbox, budgets, and seed policy fixed across both conditions, and use executable results rather than recall as the coding outcome.

## Local preflight observations

Docker Desktop was initially stopped. Starting its existing executable normally, with no installation or configuration changes, made the Docker 28.0.4 Linux/amd64 daemon available. Docker Desktop remains running; existing images, containers, and volumes were left untouched. Approximately 51.5 GiB was free on the workspace volume at the recorded preflight.

The installed Python was 3.14.6. `pandas`, `pyarrow`, `datasets`, `minisweagent`, the Python Docker package, and `litellm` were absent. No dependencies were installed and reference-environment compatibility was not qualified. Model authentication and pricing were not probed by this track. The reason this track did not execute is the user's retrieval-only choice, not an unavailable Docker daemon.

## Reproduce the read-only check

From the repository root:

```powershell
python packages/antgrid-memory/evaluation/public/vibemem_preflight.py
python packages/antgrid-memory/evaluation/public/vibemem_preflight_test.py
```

The standard-library preflight only checks local runtime availability and disk space. It does not download data, start Docker, pull images, install packages, inspect credentials, or call models. To regenerate the discovery manifest from the already-downloaded evaluator cache:

```powershell
python packages/antgrid-memory/evaluation/public/vibemem_preflight.py --metadata-dir .tmp/vibemem-inspect --output .tmp/vibemem-preflight.json
```

The optional cache input consists of `dataset-info.json` from the pinned Hugging Face dataset API and complete `rows-*.json` pages from its public dataset viewer. The reader rejects revision mismatches, missing/overlapping/truncated rows, malformed identities, and duplicate history identities; its output uses an explicit field allowlist that excludes gold and problem text. Six unit tests cover selection, chronology, case normalization, and leakage safeguards. These are harness checks, not coding-benefit results.
