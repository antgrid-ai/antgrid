# SPDX-License-Identifier: MPL-2.0

"""Read-only VibeMemBench discovery; no downloads, model calls, or Docker pulls."""

import argparse
import hashlib
import importlib.util
import json
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath


SOURCE_REVISION = "faf754671f5b850e1b4d1ff870db37a6a2480df6"
DATASET_REVISION = "11164976b4f920cdb0d0cd570ca572e49acea1e8"
AGENT_REVISION = "bc85a45654e6348dcc6e4c5a40ad146ed0bb144d"
TARGET_FIELDS = ("instance_id", "repo", "base_commit", "image_name", "language")


def issue_number(instance_id, repo):
    match = re.fullmatch(re.escape(repo.replace("/", "__").lower()) + r"-([1-9][0-9]*)", instance_id.lower())
    if not match:
        raise ValueError("Instance identity does not match its repository")
    return int(match[1])


def select_targets(rows, count=3):
    if not 1 <= count <= 3:
        raise ValueError("Discovery is bounded to one through three targets")
    earliest = {}
    seen = set()
    for row in rows:
        iid, repo = row["instance_id"], row["repo"]
        number = issue_number(iid, repo)
        if iid in seen:
            raise ValueError("Duplicate target identity")
        seen.add(iid)
        if row["language"] != "python":
            continue
        if repo not in earliest or number < issue_number(earliest[repo]["instance_id"], repo):
            earliest[repo] = row
    return [{key: earliest[repo][key] for key in TARGET_FIELDS} for repo in sorted(earliest, key=str.lower)[:count]]


def history_manifest(target, paths):
    repo = target["repo"]
    target_number = issue_number(target["instance_id"], repo)
    prefix = ("history", target["language"], repo.replace("/", "__"))
    eligible, excluded = [], []
    for raw in paths:
        parts = PurePosixPath(raw).parts
        if parts[:3] != prefix:
            continue
        if len(parts) != 5 or parts[4] != parts[3] + ".traj.json" or "\\" in raw:
            raise ValueError("Unexpected history path")
        number = issue_number(parts[3], repo)
        destination = eligible if number < target_number else excluded
        destination.append({"instance_id": parts[3], "path": raw})
    if len({item["instance_id"] for item in eligible + excluded}) != len(eligible + excluded):
        raise ValueError("Duplicate history identity")
    eligible.sort(key=lambda item: issue_number(item["instance_id"], repo))
    return {"eligible_history": eligible, "excluded_target_or_future_count": len(excluded)}


def read_discovery(directory):
    info = json.loads((directory / "dataset-info.json").read_text(encoding="utf-8-sig"))
    if info["sha"] != DATASET_REVISION:
        raise ValueError("Dataset manifest revision differs from the discovery pin")
    rows, indexes, files = [], set(), []
    expected = None
    for file in sorted(directory.glob("rows-*.json")):
        raw = file.read_bytes()
        response = json.loads(raw.decode("utf-8-sig"))
        if response.get("partial"):
            raise ValueError("Dataset viewer response is partial")
        total = response["num_rows_total"]
        if expected is not None and expected != total:
            raise ValueError("Dataset viewer pages disagree on row count")
        expected = total
        for item in response["rows"]:
            if item.get("truncated_cells") or item["row_idx"] in indexes:
                raise ValueError("Truncated or overlapping target metadata")
            indexes.add(item["row_idx"])
            rows.append(item["row"])
        files.append({"name": file.name, "sha256": hashlib.sha256(raw).hexdigest(), "bytes": len(raw)})
    if expected is None or indexes != set(range(expected)):
        raise ValueError("Incomplete target metadata; refusing biased selection")
    targets = select_targets(rows)
    paths = [item["rfilename"] for item in info["siblings"]]
    return {
        "schema_version": 1,
        "status": "not_run_user_selected_local_retrieval",
        "source_revision": SOURCE_REVISION,
        "dataset_revision": DATASET_REVISION,
        "mini_swe_agent_revision": AGENT_REVISION,
        "selection": "python; earliest numeric issue per repository; first three repositories in case-insensitive lexical order",
        "metadata_caveat": "Viewer rows are discovery metadata, not a revision-addressed dataset. Before execution, rederive these targets from test.parquet at dataset_revision and require exact matching IDs and execution fields.",
        "metadata_files": files,
        "target_count_observed": len(rows),
        "history_filter": "exact repository and language, strictly smaller trailing issue number; target and future histories excluded",
        "targets": [dict(target, **history_manifest(target, paths)) for target in targets],
        "execution": {"model_calls": 0, "image_pulls": 0, "history_downloads": 0, "matched_pairs": 0},
    }


def runtime_status(directory):
    docker = {"installed": shutil.which("docker") is not None, "available": False}
    if docker["installed"]:
        try:
            probe = subprocess.run(["docker", "version", "--format", "{{json .}}"], capture_output=True, text=True, timeout=15)
            payload = json.loads(probe.stdout) if probe.stdout.strip() else {}
            server = payload.get("Server")
            docker.update(available=probe.returncode == 0 and bool(server), client_version=(payload.get("Client") or {}).get("Version"))
            if server:
                docker.update(server_version=server.get("Version"), server_os=server.get("Os"), server_arch=server.get("Arch"))
            else:
                docker["failure"] = "docker version did not reach a daemon"
        except (OSError, ValueError, subprocess.TimeoutExpired):
            docker["failure"] = "docker version failed or timed out"
    return {
        "python_version": sys.version.split()[0],
        "python_modules": {name: importlib.util.find_spec(name) is not None for name in ("pandas", "pyarrow", "datasets", "minisweagent", "docker", "litellm")},
        "free_bytes": shutil.disk_usage(directory).free,
        "docker": docker,
        "model_auth": "not_probed; user selected local retrieval only",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--metadata-dir", type=Path, help="Already-downloaded dataset-info.json and complete rows-*.json pages")
    parser.add_argument("--output", type=Path, help="Write a redacted discovery manifest and current read-only runtime status")
    args = parser.parse_args()
    report = read_discovery(args.metadata_dir) if args.metadata_dir else {"schema_version": 1, "status": "runtime_preflight_only"}
    report["runtime"] = runtime_status(Path.cwd())
    report["observed_at"] = datetime.now(timezone.utc).isoformat()
    result = json.dumps(report, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(result, encoding="utf-8")
        print(json.dumps({"output": str(args.output), "status": report["status"], "docker_available": report["runtime"]["docker"]["available"]}))
    else:
        print(result)


if __name__ == "__main__":
    main()
