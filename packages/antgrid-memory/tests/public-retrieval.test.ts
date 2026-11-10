// SPDX-License-Identifier: MPL-2.0

import { describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PublicIndex, measureQuery, scoreRelevant, stableRecordId, summarize } from "../evaluation/public/retrieval";
import { parseSciFact } from "../evaluation/public/scifact";

describe("public retrieval evaluation", () => {
  test("counts each source once while duplicate chunks consume result slots", () => {
    const sources = new Map([ ["a1", ["a"]], ["a2", ["a"]], ["b", ["b"]], ["x", ["x"]] ]);
    const score = scoreRelevant(["a", "b"], ["a1", "a2", "x", "x", "x", "b"], sources);
    expect(score.coverage5).toBe(1);
    expect(score.recall5).toBe(.5);
    expect(score.recall10).toBe(1);
    expect(score.allEvidence5).toBe(0);
    expect(score.mrr10).toBe(1);
    expect(score.ndcg10).toBeCloseTo((1 + 1 / Math.log2(7)) / (1 + 1 / Math.log2(3)));
    expect(() => scoreRelevant([], [], sources)).toThrow("denominator");
    expect(() => scoreRelevant(["a"], ["unknown"], sources)).toThrow("Unknown");
  });

  test("preserves source metadata without ingesting relevance or query fields", () => {
    const corpus = [{ _id: "1", title: "Original source title", text: "Original abstract" }, { _id: "2", title: "Other", text: "Unjudged" }].map(row => JSON.stringify(row)).join("\n");
    const queries = [{ _id: "q1", text: "A held-out query" }, { _id: "train", text: "Training query" }].map(row => JSON.stringify(row)).join("\n");
    const group = parseSciFact(corpus, queries, "query-id\tcorpus-id\tscore\nq1\t1\t1\n");
    expect(group.documents).toHaveLength(2);
    expect(group.queries).toHaveLength(1);
    expect(group.documents[0]!.content).toBe("Original source title\n\nOriginal abstract");
    expect(JSON.stringify(group.documents)).not.toContain("held-out");
    expect(group.queries[0]!.relevantIds).toEqual(["1"]);
    expect(() => parseSciFact(corpus, queries, "query-id\tcorpus-id\tscore\nq1\tmissing\t1\n")).toThrow("Missing");
  });

  test("exercises real agent search, ranking changes, budget, and Windows store cleanup", async () => {
    const directory = mkdtempSync(join(tmpdir(), "antgrid-public-retrieval-"));
    const documents = Array.from({ length: 15 }, (_, i) => ({ id: `doc-${i}`, sourceIds: [`source-${i}`], title: i === 14 ? "needle" : "background",
      description: "A deliberately long description ".repeat(12), content: `${i === 14 ? "needle" : "background"} ${"source content ".repeat(900)}` }));
    let index: PublicIndex | undefined;
    try {
      index = new PublicIndex(directory, documents, true);
      index.ranking("equal");
      const raw = await index.search("needle", 10, true);
      expect((raw.results as { id: string }[])[0]!.id).toBe(stableRecordId("doc-14"));
      index.ranking("weighted");
      const measured = await measureQuery(index, "fixture", { id: "q", text: "needle", category: "test", relevantIds: ["source-14"] }, "weighted", 1);
      expect(measured.error).toBeUndefined();
      expect(measured.raw!.recall10).toBe(1);
      expect(measured.delivered!.recall5).toBe(1);
      expect(measured.envelopeBytes).toBeLessThanOrEqual(8192);
      expect(measured.latencyMs).toHaveLength(1);
      const abstain = await measureQuery(index, "fixture", { id: "abs", text: "unknown", category: "test", relevantIds: [], unanswerable: true }, "weighted", 1);
      const invalid = await measureQuery(index, "fixture", { id: "bad", text: "q".repeat(1025), category: "test", relevantIds: ["source-14"] }, "weighted", 1);
      expect(abstain.raw).toBeNull();
      expect(invalid.error).toContain("byte limit");
      const summary = summarize([measured, abstain, invalid]);
      expect(summary.queries).toBe(3);
      expect(summary.answerable).toBe(2);
      expect(summary.errors).toBe(1);
      expect(summary.delivered.recall5).toBe(.5);
    } finally { index?.close(); rmSync(directory, { recursive: true, force: true }); }
  });
});
