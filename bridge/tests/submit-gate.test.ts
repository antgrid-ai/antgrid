import { expect, test } from "bun:test";
import { SubmitGate } from "../src/submit-gate";

const tick = (): Promise<void> => new Promise((resolve) => setTimeout(resolve, 0));

// Reported from integration: the first session-bus card reached a freshly
// started agent, was typed into its composer, and sat there until the user
// pressed Enter. The whole write -- line and CR -- landed in the guest's first
// read, which is what absorbs the CR as literal text.
test("a submit into a guest that has not announced itself is held", async () => {
  const sent: string[] = [];
  const gate = new SubmitGate(60_000);

  gate.run("t1", () => sent.push("card"));
  await tick();
  expect(sent).toEqual([]);

  gate.markReady("t1");
  await tick();
  expect(sent).toEqual(["card"]);
});

test("a submit into a guest already reading goes synchronously", () => {
  const sent: string[] = [];
  const gate = new SubmitGate(60_000);
  gate.markReady("t1");

  gate.run("t1", () => sent.push("reply"));

  // Not after a tick: the Handler auto-reply and the `continue` nudge take this
  // path on every turn, and a scheduling hop here would be paid forever.
  expect(sent).toEqual(["reply"]);
});

// The welded cards from the same report: two deliveries written seconds apart
// arrived on one line, because neither read was taken until the guest started.
test("held submits keep the order they were asked for", async () => {
  const sent: string[] = [];
  const gate = new SubmitGate(60_000);

  gate.run("t1", () => sent.push("first"));
  gate.run("t1", () => sent.push("second"));
  gate.markReady("t1");
  // A third, asked for after readiness, must still queue behind the two being
  // released -- the synchronous fast path is only for an EMPTY chain.
  gate.run("t1", () => sent.push("third"));
  await tick();

  expect(sent).toEqual(["first", "second", "third"]);
});

test("a guest that never announces an input mode still submits", async () => {
  const sent: string[] = [];
  const gate = new SubmitGate(5);

  gate.run("t1", () => sent.push("card"));
  await new Promise((resolve) => setTimeout(resolve, 40));

  expect(sent).toEqual(["card"]);
});

test("one terminal's held submit does not hold another's", async () => {
  const sent: string[] = [];
  const gate = new SubmitGate(60_000);
  gate.markReady("t2");

  gate.run("t1", () => sent.push("held"));
  gate.run("t2", () => sent.push("free"));
  await tick();

  expect(sent).toEqual(["free"]);
});

// A respawn reusing a retained slot must not inherit the dead run's readiness,
// and the waiters it releases must not be left holding the chain -- a promise
// nothing can resolve would strand every later submit to that id.
test("a reset releases what is held and takes readiness back", async () => {
  const sent: string[] = [];
  const gate = new SubmitGate(60_000);

  gate.run("t1", () => sent.push("held"));
  gate.reset("t1");
  await tick();
  expect(sent).toEqual(["held"]);

  // Releasing is not granting: the next run waits for the new guest's own
  // announcement rather than inheriting the dead run's.
  gate.run("t1", () => sent.push("next"));
  await tick();
  expect(sent).toEqual(["held"]);

  gate.markReady("t1");
  await tick();
  expect(sent).toEqual(["held", "next"]);
});
