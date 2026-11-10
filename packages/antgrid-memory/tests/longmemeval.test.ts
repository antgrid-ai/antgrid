// SPDX-License-Identifier: MPL-2.0

import { expect, test } from "bun:test";
import { LONGMEMEVAL_MAX_BYTES, parseLongMemEval } from "../evaluation/public/longmemeval";

function fixture(overrides: Record<string, unknown> = {}) {
  return {
    question_id: "q1", question_type: "single-session-user", question: "QUERY_SECRET?",
    answer: "GOLD_SECRET", question_date: "2024/03/01 (Fri) 09:00",
    haystack_session_ids: ["noise_source", "answer_evidence_source"],
    haystack_dates: ["2024/01/01 (Mon) 09:00", "2024/02/01 (Thu) 10:00"],
    haystack_sessions: [
      [{ role: "user", content: "Earlier context." }, { role: "assistant", content: "Earlier reply." }],
      [{ role: "user", content: "Later context.", has_answer: true }, { role: "assistant", content: "Later reply." }],
    ],
    answer_session_ids: ["answer_evidence_source"], ...overrides,
  };
}

test("LongMemEval maps evidence to neutral session IDs without indexed labels or query metadata", () => {
  const [group] = parseLongMemEval([fixture()]);
  expect(group.id).toBe("lme-0000");
  expect(group.documents.map(document => document.sourceIds)).toEqual([["lme-0000-s000"], ["lme-0000-s001"]]);
  expect(group.queries[0]).toMatchObject({ id: "q1", relevantIds: ["lme-0000-s001"], answer: "GOLD_SECRET", unanswerable: false });
  expect(group.queries[0].text).toBe("QUERY_SECRET?");
  expect(group.queries[0].questionDate).toBe("2024/03/01 (Fri) 09:00");
  const indexed = JSON.stringify(group.documents);
  for (const forbidden of ["answer_", "has_answer", "QUERY_SECRET", "GOLD_SECRET", "question_type", "2024/03/01"]) expect(indexed).not.toContain(forbidden);
  expect(group.documents[0].content).toBe("Session date: 2024/01/01 (Mon) 09:00\n\nuser:\nEarlier context.\n\nassistant:\nEarlier reply.");
  expect(group.documents[1].content).toContain("2024/02/01");
});

test("LongMemEval chunks oversized multilingual turns losslessly within the UTF8 byte cap", () => {
  const text = "東京😀é".repeat(6000);
  const [group] = parseLongMemEval([fixture({
    haystack_session_ids: ["answer_big"], haystack_dates: ["2024-01-01"],
    haystack_sessions: [[{ role: "user", content: text, has_answer: true }]], answer_session_ids: ["answer_big"],
  })]);
  expect(group.documents.length).toBeGreaterThan(1);
  const header = "Session date: 2024-01-01\n\nuser:\n";
  expect(group.documents.map(document => document.content.slice(header.length)).join("")).toBe(text);
  for (const document of group.documents) {
    expect(Buffer.byteLength(document.content)).toBeLessThanOrEqual(LONGMEMEVAL_MAX_BYTES);
    expect(document.content.startsWith(header)).toBe(true);
    expect(document.content).not.toContain("\uFFFD");
    expect(document.sourceIds).toEqual(["lme-0000-s000"]);
  }
  expect(group.queries[0].relevantIds).toEqual(["lme-0000-s000"]);
});

test("LongMemEval retains abstention for QA while omitting retrieval relevance", () => {
  const [group] = parseLongMemEval([fixture({ question_id: "q1_abs", answer_session_ids: ["nonexistent_event"] })]);
  expect(group.queries[0]).toMatchObject({ unanswerable: true, relevantIds: [], answer: "GOLD_SECRET" });
  expect(group.documents.length).toBe(2);
});

test("LongMemEval groups do not share source IDs even when upstream sessions repeat", () => {
  const groups = parseLongMemEval([fixture(), fixture({ question_id: "q2" })]);
  expect(groups[0].documents.map(document => document.content)).toEqual(groups[1].documents.map(document => document.content));
  expect(groups[0].queries[0].relevantIds).not.toEqual(groups[1].queries[0].relevantIds);
  expect(new Set(groups.flatMap(group => group.documents.map(document => document.id))).size).toBe(4);
});

test("repeated upstream session IDs retain chronological occurrences and one source identity", () => {
  const [group] = parseLongMemEval([fixture({ haystack_session_ids: ["answer_same", "answer_same"], answer_session_ids: ["answer_same"] })]);
  expect(group.documents.map(document => document.id)).toEqual(["lme-0000-s000-c000", "lme-0000-s001-c000"]);
  expect(group.documents.map(document => document.sourceIds)).toEqual([["lme-0000-s000"], ["lme-0000-s000"]]);
  expect(group.queries[0].relevantIds).toEqual(["lme-0000-s000"]);
  expect(group.documents[0].content).toContain("2024/01/01");
  expect(group.documents[1].content).toContain("2024/02/01");
});

test("LongMemEval rejects malformed sessions and unmapped answerable evidence", () => {
  for (const input of [
    [fixture({ haystack_dates: ["one"] })],
    [fixture({ answer_session_ids: ["missing"] })],
    [fixture({ answer_session_ids: [] })],
    [fixture(), fixture()],
    [fixture({ haystack_sessions: [[{ role: "system", content: "unsupported" }], []] })],
    {},
  ]) expect(() => parseLongMemEval(input)).toThrow();
});
