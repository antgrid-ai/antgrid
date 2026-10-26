import { expect, test } from "bun:test";
import { setLogLevel } from "../src/logger";
import { StartupScreenCheck, SubmitGate } from "../src/submit-gate";

setLogLevel("error");

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

// The guest swapped interfaces without dying -- a modal, or the mount that
// follows Claude Code's pre-TUI phase. Nothing is reading in the gap, which is
// the state that welds a line to its own CR.
test("a guest that stopped reading holds the next submit", async () => {
  const sent: string[] = [];
  const gate = new SubmitGate(60_000);
  gate.markReady("t1");
  gate.markUnready("t1");

  gate.run("t1", () => sent.push("card"));
  await tick();
  expect(sent).toEqual([]);

  gate.markReady("t1");
  await tick();
  expect(sent).toEqual(["card"]);
});

// The process is the same one the held submit was asked for, so the identity
// check must not fire: a guest bump here would resolve the wait instead of
// extending it, and a release would write into the gap it exists to skip.
test("a submit held across a lost interface keeps waiting for the new one", async () => {
  const sent: string[] = [];
  const gate = new SubmitGate(60_000);

  gate.run("t1", () => sent.push("card"));
  gate.markUnready("t1");
  await tick();
  expect(sent).toEqual([]);

  gate.markReady("t1");
  await tick();
  expect(sent).toEqual(["card"]);
});

test("a guest that has been reading once waits a swap out, not a cold start", async () => {
  const sent: string[] = [];
  const gate = new SubmitGate(60_000, 5);
  gate.markReady("t1");
  gate.markUnready("t1");

  gate.run("t1", () => sent.push("card"));
  await new Promise((resolve) => setTimeout(resolve, 40));

  expect(sent).toEqual(["card"]);
});

test("a respawn is a cold start again", async () => {
  const sent: string[] = [];
  const gate = new SubmitGate(60_000, 5);
  gate.markReady("t1");
  gate.reset("t1");

  gate.run("t1", () => sent.push("card"));
  await new Promise((resolve) => setTimeout(resolve, 40));

  expect(sent).toEqual([]);
});

const wait = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

// Measured: every agent's folder-trust dialog enables bracketed paste and
// paints, which is exactly what readiness looks for, and reads Enter as an
// answer. A submit let go into one picks the highlighted option for the user.
test("readiness alone does not release a guest that may open on a startup prompt", async () => {
  const sent: string[] = [];
  const gate = new SubmitGate(60_000);
  gate.holdForStartup("t1");

  gate.run("t1", () => sent.push("handoff"));
  gate.markReady("t1");
  await tick();
  expect(sent).toEqual([]);

  gate.startupScreen("t1", false);
  await tick();
  expect(sent).toEqual(["handoff"]);
});

test("a startup prompt on screen holds a submit past the readiness bound until it is answered", async () => {
  const sent: string[] = [];
  const gate = new SubmitGate(5, 5);
  gate.holdForStartup("t1");

  gate.run("t1", () => sent.push("handoff"));
  gate.markReady("t1");
  gate.startupScreen("t1", true);
  await wait(40);
  expect(sent).toEqual([]);

  gate.startupScreen("t1", false);
  await tick();
  expect(sent).toEqual(["handoff"]);
});

// Cursor's dialog never enables the mode, so the guest is not reading when the
// prompt goes away; the bound is what lets the submit go, and it starts over.
test("the readiness bound resumes once the prompt is gone", async () => {
  const sent: string[] = [];
  const gate = new SubmitGate(5);
  gate.holdForStartup("t1");

  gate.run("t1", () => sent.push("handoff"));
  gate.startupScreen("t1", true);
  await wait(40);
  expect(sent).toEqual([]);

  gate.startupScreen("t1", false);
  await wait(40);
  expect(sent).toEqual(["handoff"]);
});

test("a clear screen before the guest reads keeps the hold", async () => {
  const sent: string[] = [];
  const gate = new SubmitGate(60_000);
  gate.holdForStartup("t1");

  gate.run("t1", () => sent.push("handoff"));
  gate.startupScreen("t1", false);
  gate.markReady("t1");
  await tick();
  expect(sent).toEqual([]);

  gate.startupScreen("t1", false);
  await tick();
  expect(sent).toEqual(["handoff"]);
});

test("once the composer has been seen, prompt text on screen holds nothing", () => {
  const sent: string[] = [];
  const gate = new SubmitGate(60_000);
  gate.holdForStartup("t1");
  gate.markReady("t1");
  gate.startupScreen("t1", false);

  // The agent quoting the dialog's words mid-session is not the dialog.
  gate.startupScreen("t1", true);
  gate.run("t1", () => sent.push("reply"));

  expect(gate.awaitingStartup("t1")).toBe(false);
  expect(sent).toEqual(["reply"]);
});

test("a respawn drops the previous guest's startup hold", () => {
  const sent: string[] = [];
  const gate = new SubmitGate(60_000);
  gate.holdForStartup("t1");
  gate.startupScreen("t1", true);
  gate.reset("t1");
  gate.markReady("t1");

  gate.run("t1", () => sent.push("card"));

  expect(sent).toEqual(["card"]);
});

// Cursor's dialog never enables the mode; with `--trust` there is no dialog at
// all, and the screen would otherwise be read for the life of the session.
test("a guest that never reads and shows no prompt is past its startup after the cold bound", async () => {
  const gate = new SubmitGate(5);
  gate.holdForStartup("t1");
  gate.startupScreen("t1", false);
  await wait(40);

  expect(gate.awaitingStartup("t1")).toBe(false);
});

test("a guest that never reads keeps its hold while a prompt is up", async () => {
  const gate = new SubmitGate(5);
  gate.holdForStartup("t1");
  gate.startupScreen("t1", true);
  await wait(40);

  expect(gate.awaitingStartup("t1")).toBe(true);
});

test("a reading guest's screen is judged before the bound may send", async () => {
  const sent: string[] = [];
  const gate = new SubmitGate(5, 5);
  gate.holdForStartup("t1");

  gate.run("t1", () => sent.push("handoff"));
  gate.markReady("t1");
  await wait(40);
  expect(sent).toEqual([]);

  gate.startupScreen("t1", false);
  await tick();
  expect(sent).toEqual(["handoff"]);
});

// The answer is followed by the guest swapping its composer in, mode off for
// the gap; a bound that began before the answer would send into it.
test("the bound restarts from the answer, not from before it", async () => {
  const sent: string[] = [];
  const gate = new SubmitGate(40);
  gate.holdForStartup("t1");

  gate.run("t1", () => sent.push("handoff"));
  gate.startupScreen("t1", true);
  await wait(30);
  gate.startupScreen("t1", false);
  await wait(25);
  expect(sent).toEqual([]);

  gate.markReady("t1");
  gate.startupScreen("t1", false);
  await tick();
  expect(sent).toEqual(["handoff"]);
});

test("a startup screen check reads the screen only once output settles", async () => {
  const reports: boolean[] = [];
  let reads = 0;
  let rows = ["╭────╮"];
  const check = new StartupScreenCheck({
    prompts: ["Trust this folder?"],
    read: () => { reads++; return rows; },
    report: (showing) => reports.push(showing),
    settleMs: 20,
    maxDeferMs: 1_000,
  });

  // A dialog drawn in two reads: the first holds only its border.
  check.noteOutput();
  await wait(5);
  rows = ["╭────╮", "│ Trust this folder? │"];
  check.noteOutput();
  await wait(60);

  expect(reads).toBe(1);
  expect(reports).toEqual([true]);
  check.dispose();
});

test("a startup screen check still reads a screen whose output never pauses", async () => {
  const reports: boolean[] = [];
  let now = 0;
  const check = new StartupScreenCheck({
    prompts: ["Trust this folder?"],
    read: () => ["⠋ loading", "> composer"],
    report: (showing) => reports.push(showing),
    settleMs: 1_000,
    maxDeferMs: 30,
    clearMs: 0,
    now: () => now,
  });

  check.noteOutput();
  now = 25;
  check.noteOutput();
  await wait(40);

  expect(reports).toEqual([false]);
  check.dispose();
});

// Codex 0.163's order: the composer, bracketed paste on, then the trust dialog
// over it some 600ms later.
test("a composer painted before the trust dialog is not taken for no dialog", async () => {
  const reports: boolean[] = [];
  let rows = ["› Ask Codex to do anything"];
  const check = new StartupScreenCheck({
    prompts: ["Trust this folder?"],
    read: () => rows,
    report: (showing) => reports.push(showing),
    settleMs: 5,
    clearMs: 200,
  });

  check.noteOutput();
  await wait(60);
  expect(reports).toEqual([]);

  rows = ["Trust this folder? Codex can read, edit, and run files here", "› 1. Trust and continue"];
  check.noteOutput();
  await wait(40);
  expect(reports).toEqual([true]);
  check.dispose();
});

// A slow cold start: the blank pre-TUI screen outlasts the window, and only
// then does Codex paint its composer ahead of the dialog.
test("the clear window starts once the guest is reading", async () => {
  const reports: boolean[] = [];
  let reading = false;
  let rows = [""];
  const check = new StartupScreenCheck({
    prompts: ["Trust this folder?"],
    read: () => rows,
    reading: () => reading,
    report: (showing) => reports.push(showing),
    settleMs: 5,
    clearMs: 200,
  });

  check.noteOutput();
  await wait(260);
  expect(reports).toEqual([]);

  reading = true;
  rows = ["› Ask Codex to do anything"];
  check.noteOutput();
  await wait(60);
  expect(reports).toEqual([]);

  rows = ["Trust this folder? Codex can read, edit, and run files here"];
  check.noteOutput();
  await wait(40);
  expect(reports).toEqual([true]);
  check.dispose();
});

test("a screen that stays clear through the window is reported clear once", async () => {
  const reports: boolean[] = [];
  const check = new StartupScreenCheck({
    prompts: ["Trust this folder?"],
    read: () => ["> composer"],
    report: (showing) => reports.push(showing),
    settleMs: 5,
    clearMs: 30,
  });

  check.noteOutput();
  await wait(15);
  check.noteOutput();
  await wait(80);

  expect(reports).toEqual([false]);
  check.dispose();
});

test("a prompt that was answered reports the clear screen after the window", async () => {
  const reports: boolean[] = [];
  let rows = ["Trust this folder?"];
  const check = new StartupScreenCheck({
    prompts: ["Trust this folder?"],
    read: () => rows,
    report: (showing) => reports.push(showing),
    settleMs: 5,
    clearMs: 100,
  });

  check.noteOutput();
  await wait(30);
  rows = ["> composer"];
  check.noteOutput();
  await wait(30);
  expect(reports).toEqual([true]);

  await wait(150);
  expect(reports).toEqual([true, false]);
  check.dispose();
});

// Codex 0.164's order: the update prompt, the composer, then the trust dialog.
// Ending the hold on the first answer would send a queued submit into the
// dialog, where Enter trusts the repository.
test("an answered prompt followed by another keeps the hold", async () => {
  const reports: boolean[] = [];
  let rows = ["› 1. Update now (runs `npm install -g @openai/codex`)", "  3. Skip until next version"];
  const check = new StartupScreenCheck({
    prompts: ["Update now (runs", "Skip until next version", "Trust this folder?"],
    read: () => rows,
    report: (showing) => reports.push(showing),
    settleMs: 5,
    clearMs: 200,
  });

  check.noteOutput();
  await wait(30);
  rows = ["› Ask Codex to do anything"];
  check.noteOutput();
  await wait(60);
  rows = ["Trust this folder? Codex can read, edit, and run files here", "› 1. Trust and continue"];
  check.noteOutput();
  await wait(30);

  expect(reports).toEqual([true, true]);
  check.dispose();
});
