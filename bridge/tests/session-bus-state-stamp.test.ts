import { expect, test } from "bun:test";
import { stampTaskState } from "../src/session-bus/state-stamp";

const CARD = "----- BEGIN TASK -----\nfix the codec\n----- END TASK -----";
const task = { taskId: "t-1", state: "assigned" };

// Reported from integration: a lead was handed a card asking it to answer a peer
// on a task that had already completed. The card was rendered while the task was
// live and sat in the queue until the next turn boundary, which outlasted it.
test("a card whose task moved while it queued says so", () => {
  const out = stampTaskState(CARD, task, "completed");
  expect(out.startsWith(CARD)).toBe(true);
  expect(out).toContain("task t-1 is completed");
  expect(out).toContain("it was assigned when the message above was written");
});

test("a card whose task has not moved is delivered verbatim", () => {
  expect(stampTaskState(CARD, task, "assigned")).toBe(CARD);
});

// The completion wake IS a card about a task that has ended, and it is the only
// thing telling its lead the work is done (D11) -- so the stamp annotates and
// never filters, and a card rendered from the terminal state it describes is not
// a state change at all.
test("a wake rendered from the terminal state it reports is not stamped", () => {
  expect(stampTaskState(CARD, { taskId: "t-1", state: "completed" }, "completed")).toBe(CARD);
});

// An expired task is swept from the store, and the card describing it must still
// arrive: a missing record is not evidence the state moved.
test("a task the store can no longer find is left alone", () => {
  expect(stampTaskState(CARD, task, undefined)).toBe(CARD);
  expect(stampTaskState(CARD, task, null)).toBe(CARD);
});
