// SPDX-License-Identifier: MPL-2.0

import { expect, test } from "bun:test";
import { selectTechnicalQueries, technicalFixtures } from "../evaluation/public/technical-fixtures";

test("technical diagnostics query every sibling with aligned opaque controls", () => {
  const { groups, cases, probes } = technicalFixtures();
  const [literal, control] = groups;
  expect(literal!.documents.length).toBeGreaterThan(70);
  expect(control!.documents.map(row => row.id)).toEqual(literal!.documents.map(row => row.id));
  expect(new Set(control!.documents.map(row => row.title)).size).toBe(control!.documents.length);
  for (const document of literal!.documents) {
    expect(cases.filter(row => row.kind === "literal" && row.relevantIds.includes(document.id))).toHaveLength(1);
    expect(document.content).toContain(document.title!);
  }
  expect(control!.queries.map(row => row.relevantIds)).toEqual(literal!.queries.map(row => row.relevantIds));
  expect(probes.length).toBeGreaterThan(0);
  expect(probes.find(row => row.query === "retry")!.target).toBe("maxRetryCount");
  expect(cases.find(row => row.term === "C++" && row.kind === "literal")!.query).toBe("C++");
  expect(cases.find(row => row.term === "C#" && row.kind === "phrase")!.query).toBe('"C#"');
});

test("technical pilot selection is order-independent and preserves the full corpus and original query", () => {
  const group = technicalFixtures().groups[0]!;
  const first = selectTechnicalQueries(group, 17);
  const reversed = selectTechnicalQueries({ ...group, queries: [...group.queries].reverse() }, 17);
  expect(first.selection).toEqual(reversed.selection);
  expect(first.group.documents).toBe(group.documents);
  expect(first.group.queries).toHaveLength(17);
  for (const selected of first.group.queries) expect(selected).toBe(group.queries.find(row => row.id === selected.id)!);
  expect(selectTechnicalQueries(group, 10000).group.queries).toHaveLength(group.queries.length);
});
