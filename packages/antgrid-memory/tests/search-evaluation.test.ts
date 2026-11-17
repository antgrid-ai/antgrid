// SPDX-License-Identifier: MPL-2.0

import { expect, test } from "bun:test";
import { EvaluationIndex, judge, quality } from "../evaluation/benchmark";
import { DOCUMENTS, QUERIES, corpus } from "../evaluation/fixtures";
import { markdown } from "../evaluation/run";
import { LIMITS, MemorySaveSchema, bytes } from "../src/contracts";

test("the frozen ranking corpus has labelled cohorts and legal synthetic records", () => {
  expect(QUERIES.length).toBeGreaterThanOrEqual(30);
  expect(new Set(QUERIES.map(query => query.id)).size).toBe(QUERIES.length);
  const ids = new Set(DOCUMENTS.map(record => record.id));
  expect(ids.size).toBe(DOCUMENTS.length);
  for (const document of corpus(100)) {
    const { id: _id, ...save } = document;
    expect(MemorySaveSchema.safeParse({ ...save, memory_type: "note", scope: "project" }).success).toBe(true);
  }
  for (const category of ["concise", "long", "ambiguous", "legacy"]) expect(QUERIES.filter(query => query.category === category).length).toBeGreaterThanOrEqual(5);
  for (const query of QUERIES) {
    expect(query.judgement.length).toBeGreaterThan(20);
    expect(query.relevant.length).toBeGreaterThan(0);
    for (const id of query.relevant) {
      expect(ids.has(id)).toBe(true);
      if (query.category === "legacy") {
        const document = DOCUMENTS.find(record => record.id === id)!;
        expect(document.title).toBeUndefined(); expect(document.description).toBeUndefined();
      }
    }
  }
});

test("metrics distinguish the first relevant rank, query coverage and multi-answer recall", () => {
  const query = { id: "metric", category: "ambiguous" as const, query: "fixture", relevant: ["a", "b"], judgement: "Two independently relevant answers." };
  const first = judge(query, ["noise", "a", "other", "else", "last", "b"]);
  const miss = judge(query, []);
  expect(first).toMatchObject({ rank: 2, coverage5: 1, recall5: .5 });
  expect(quality([first, miss])).toEqual({ queries: 2, mrr10: .25, coverage5: .5, recall5: .25 });
  expect(typeof markdown).toBe("function");
});

test("metadata-only terms are indexed, and both experimental rankers retain the response byte budget", () => {
  const docs = [...DOCUMENTS, { id: "metadata-only", title: "titlequartzsignal", description: "descriptionnebula", content: "This body deliberately contains neither discovery term." }];
  const index = new EvaluationIndex(":memory:", docs);
  try {
    for (const ranking of ["equal", "weighted"] as const) {
      expect(index.records("titlequartzsignal", ranking).map(record => record.id)).toEqual(["metadata-only"]);
      expect(index.records("descriptionnebula", ranking).map(record => record.id)).toEqual(["metadata-only"]);
      for (const query of QUERIES) {
        const response = index.response(query.query, ranking);
        expect(bytes({ isError: false, content: [{ type: "text", text: JSON.stringify(response) }] }) + 256).toBeLessThanOrEqual(LIMITS.response);
      }
    }
  } finally { index.close(); }
});

test("a body-only match near the end appears in a marked query-aware excerpt", () => {
  const body = "Routine procedure details require source inspection. ".repeat(180) + "The quartzrepair workaround requires restarting the isolated test worker.";
  const index = new EvaluationIndex(":memory:", [{ id: "deep-match", title: "Long verification procedure", description: "A synthetic procedure with a specific workaround in its final paragraph.", content: body }]);
  try {
    const records = index.records("quartzrepair", "weighted");
    expect(records).toHaveLength(1);
    expect(records[0]!.content).toContain("quartzrepair");
    const response = index.response("quartzrepair", "weighted");
    expect(response.results[0]!.excerpted).toBe(true);
    expect(response.results[0]!.content).toContain("quartzrepair");
    expect(body.slice(0, LIMITS.describedExcerpt)).not.toContain("quartzrepair");
    expect(response.results[0]!.content.length).toBeLessThan(body.length);
  } finally { index.close(); }
});
