# SPDX-License-Identifier: MPL-2.0

"""Selection/leakage guard tests, not benchmark coding-task outcomes."""

import json
import tempfile
import unittest
from pathlib import Path

from vibemem_preflight import DATASET_REVISION, history_manifest, read_discovery, select_targets


def target(repo="a/repo", number=20, language="python"):
    return dict(instance_id=repo.replace("/", "__") + "-" + str(number), repo=repo, language=language,
                base_commit="a" * 40, image_name="example/image:tag", patch="TARGET GOLD", test_patch="HIDDEN TEST",
                problem_statement="task", pr_description="HINDSIGHT", FAIL_TO_PASS=["hidden_test"])


def history(repo, number):
    iid = repo + "-" + str(number)
    return "history/python/" + repo + "/" + iid + "/" + iid + ".traj.json"


class DiscoveryTests(unittest.TestCase):
    def test_selection_uses_numeric_chronology_then_repo_order(self):
        rows = [target("b/repo", 9), target("a/repo", 100), target("a/repo", 20), target("a/other", 1, "go")]
        self.assertEqual([r["instance_id"] for r in select_targets(rows)], ["a__repo-20", "b__repo-9"])
        self.assertEqual(select_targets(rows), select_targets(list(reversed(rows))))

    def test_manifest_never_copies_gold_or_problem_text(self):
        result = json.dumps(select_targets([target()]))
        for forbidden in ("TARGET GOLD", "HIDDEN TEST", "HINDSIGHT", "problem_statement", "FAIL_TO_PASS"):
            self.assertNotIn(forbidden, result)

    def test_github_repository_case_can_differ_from_instance_id(self):
        row = dict(target("CS-SI/eodag"), instance_id="cs-si__eodag-20")
        selected = select_targets([row, target()])
        self.assertEqual(selected[0]["repo"], "a/repo")
        result = history_manifest(row, ["history/python/CS-SI__eodag/cs-si__eodag-9/cs-si__eodag-9.traj.json"])
        self.assertEqual(len(result["eligible_history"]), 1)

    def test_history_excludes_target_future_and_unrelated_repositories(self):
        result = history_manifest(target(), [history("a__repo", n) for n in (9, 20, 100)] + [history("other__repo", 1)])
        self.assertEqual([item["instance_id"] for item in result["eligible_history"]], ["a__repo-9"])
        self.assertEqual(result["excluded_target_or_future_count"], 2)

    def test_malformed_cross_repo_and_duplicate_identities_fail(self):
        with self.assertRaises(ValueError):
            select_targets([dict(target(), instance_id="other__repo-1")])
        with self.assertRaises(ValueError):
            select_targets([target(), target()])
        with self.assertRaises(ValueError):
            history_manifest(target(), [history("a__repo", 9), history("a__repo", 9)])
        with self.assertRaises(ValueError):
            history_manifest(target(), ["history/python/a__repo/../escape.traj.json"])

    def test_discovery_refuses_incomplete_or_truncated_viewer_pages(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / "dataset-info.json").write_text(json.dumps({"sha": DATASET_REVISION, "siblings": []}), encoding="utf-8")
            response = {"num_rows_total": 2, "rows": [{"row_idx": 0, "row": target(), "truncated_cells": []}]}
            file = directory / "rows-0.json"
            file.write_text(json.dumps(response), encoding="utf-8")
            with self.assertRaises(ValueError):
                read_discovery(directory)
            response["num_rows_total"] = 1
            response["rows"][0]["truncated_cells"] = ["patch"]
            file.write_text(json.dumps(response), encoding="utf-8")
            with self.assertRaises(ValueError):
                read_discovery(directory)


if __name__ == "__main__":
    unittest.main()
