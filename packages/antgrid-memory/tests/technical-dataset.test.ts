// SPDX-License-Identifier: MPL-2.0

import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { parseTechnicalDataset, verifyTechnicalSource } from "../evaluation/public/technical-dataset";

const jsonl = (rows: unknown[]) => rows.map(row => JSON.stringify(row)).join("\n") + "\n";
const document = { _id: "doc", title: "C++ std::vector versus C# List<T>", text: "Keep Node.js, .NET, libstdc++, snake_case and camelCase unchanged." };
const query = { _id: "q", text: "Why does std::vector<T> differ from List<T>?" };
const qrels = "query-id\tcorpus-id\tscore\nq\tdoc\t1\n";

test("technical source terms and original query text are preserved without query-derived metadata", () => {
  const parsed = parseTechnicalDataset(jsonl([document]), jsonl([query]), qrels);
  expect(parsed.unsupportedQueries).toEqual([]);
  expect(parsed.group.documents).toEqual([{
    id: "cqadupstack-programmers-doc-c000", content: `${document.title}\n\n${document.text}`,
    title: document.title, sourceIds: ["doc"],
  }]);
  expect(parsed.group.queries[0]).toEqual({ id: "q", text: query.text, category: "programming-duplicate-question", relevantIds: ["doc"] });
  expect(JSON.stringify(parsed.group.documents)).not.toContain(query.text);
});

test("oversized technical documents split losslessly at UTF8 boundaries with shared source identity", () => {
  const long = { ...document, title: "東京😀".repeat(100), text: "Type<T>::method snake_case 😀 ".repeat(2000) };
  const parsed = parseTechnicalDataset(jsonl([long]), jsonl([query]), qrels);
  expect(parsed.group.documents.length).toBeGreaterThan(1);
  expect(parsed.group.documents.map(row => row.content).join("")).toBe(`${long.title}\n\n${long.text}`);
  for (const row of parsed.group.documents) {
    expect(Buffer.byteLength(row.content)).toBeLessThanOrEqual(16384);
    expect(Buffer.byteLength(row.title!)).toBeLessThanOrEqual(256);
    expect(row.content).not.toContain("\uFFFD");
    expect(row.sourceIds).toEqual(["doc"]);
  }
  expect(new Set(parsed.group.documents.map(row => row.id)).size).toBe(parsed.group.documents.length);
  expect(parsed.group.queries[0].relevantIds).toEqual(["doc"]);
});

test("unsupported technical queries remain unchanged and are explicitly reported", () => {
  const long = "é".repeat(513);
  const parsed = parseTechnicalDataset(jsonl([document]), jsonl([{ ...query, text: long }, { _id: "punctuation", text: "+++::<>" }]), qrels + "punctuation\tdoc\t1\n");
  expect(parsed.group.queries.map(row => row.text)).toEqual([long, "+++::<>"]);
  expect(parsed.unsupportedQueries).toMatchObject([{ id: "q", bytes: 1026 }, { id: "punctuation", bytes: 7 }]);
  expect(parsed.unsupportedQueries[0].reason).toContain("retained unchanged");
});

test("technical query limit measures UTF8 bytes and accepts the exact boundary", () => {
  const parsed = parseTechnicalDataset(jsonl([document]), jsonl([{ ...query, text: "é".repeat(512) }]), qrels);
  expect(parsed.unsupportedQueries).toEqual([]);
  expect(Buffer.byteLength(parsed.group.queries[0].text)).toBe(1024);
});

test("technical qrels retain only test queries and deduplicate relevance sources", () => {
  const parsed = parseTechnicalDataset(jsonl([document]), jsonl([query, { _id: "not-test", text: "unjudged query" }]), qrels + "q\tdoc\t1\n");
  expect(parsed.group.queries.length).toBe(1);
  expect(parsed.group.queries[0].relevantIds).toEqual(["doc"]);
});

test("malformed or inconsistent technical source labels fail explicitly", () => {
  for (const [corpus, queries, labels] of [
    [jsonl([document, document]), jsonl([query]), qrels],
    [jsonl([document]), jsonl([query, query]), qrels],
    [jsonl([document]), jsonl([query]), "query-id\tcorpus-id\tscore\nq\tmissing\t1\n"],
    [jsonl([document]), jsonl([{ _id: "other", text: "Other query" }]), qrels],
    [jsonl([document]), jsonl([query]), "query-id\tcorpus-id\tscore\nq\tdoc\t\n"],
  ]) expect(() => parseTechnicalDataset(corpus, queries, labels)).toThrow();
});

test("technical sources reject corrupt cached bytes even at the pinned size", () => {
  const content = Buffer.from("verified public source");
  const expected = { name: "source.parquet", size: content.length, sha256: createHash("sha256").update(content).digest("hex") };
  expect(() => verifyTechnicalSource(content, expected)).not.toThrow();
  const corrupt = Buffer.from(content);
  corrupt[0] = 0;
  expect(() => verifyTechnicalSource(corrupt, expected)).toThrow("checksum mismatch");
  expect(() => verifyTechnicalSource(content.subarray(1), expected)).toThrow("checksum mismatch");
});
