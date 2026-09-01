import { expect, test } from "bun:test";
import { hasTypedContent, isInterruptKeystroke, isSubmitKeystroke, submittedLine } from "../src/keystrokes";

// Gates the work-status turn inference for agents with no pre-turn hook. A false
// positive opens a turn nothing will close, so the negatives matter more than the
// positives here.

test("a trailing CR is a submit", () => {
  expect(isSubmitKeystroke("\r")).toBe(true);
  expect(isSubmitKeystroke("run the tests\r")).toBe(true);
  // Pasted multi-line text that ends in a submit still counts.
  expect(isSubmitKeystroke("line one\rline two\r")).toBe(true);
});

test("alt+enter inserts a newline and is NOT a submit", () => {
  // ESC-prefixed CR: the user is building a multi-line prompt and may never send
  // it, so an inferred turn would sit on "working" indefinitely.
  expect(isSubmitKeystroke("\x1b\r")).toBe(false);
  expect(isSubmitKeystroke("more context\x1b\r")).toBe(false);
});

test("ordinary typing, control keys and cursor moves are not submits", () => {
  for (const data of ["a", "hello", "\t", "\x03", "\x1b", "\x1b[A", "\x1b[13;2u", ""]) {
    expect(isSubmitKeystroke(data)).toBe(false);
  }
});

test("a CR that is not the final byte is not a submit", () => {
  // The agent echoes/redraws after a submit; only the keystroke that ENDS the
  // payload committed the prompt.
  expect(isSubmitKeystroke("\rmore typing")).toBe(false);
});

// The other half of the gate: isSubmitKeystroke("\r") is true, and on its own it
// cannot tell a prompt from enter on an empty line. See work-status.ts.

test("a bare CR carries no typed content", () => {
  expect(hasTypedContent("\r")).toBe(false);
  expect(hasTypedContent("")).toBe(false);
});

test("anything before the CR is content, including escape sequences", () => {
  // Arrow-key history recall then enter IS a submit; dropping it would lose a
  // real turn, which is worse than the odd menu keypress being counted.
  expect(hasTypedContent("run the tests\r")).toBe(true);
  expect(hasTypedContent("a")).toBe(true);
  expect(hasTypedContent("\x1b[A")).toBe(true);
  expect(hasTypedContent("\x1b\r")).toBe(true);
});

// Gates the terminal-mode interrupt close in work-status.ts. A false positive
// would close a turn still legitimately in flight (e.g. mid arrow-key nav), so
// only the exact bare-ESC byte counts.

test("a bare Escape keypress is an interrupt", () => {
  expect(isInterruptKeystroke("\x1b")).toBe(true);
});

test("any longer ESC-prefixed sequence is content, not an interrupt", () => {
  for (const data of ["\x1b[A", "\x1b[13;2u", "\x1b\r", "\x1bOP", "\x1b\x1b"]) {
    expect(isInterruptKeystroke(data)).toBe(false);
  }
});

test("ordinary keys and an empty payload are not an interrupt", () => {
  for (const data of ["a", "\r", "\t", "\x03", ""]) {
    expect(isInterruptKeystroke(data)).toBe(false);
  }
});

// Splits the one shape a guest tokenizer absorbs the CR into. Everything else is
// written through untouched, so the negatives are what keep an ordinary keystroke
// off the deferred-CR path. See pty-submit.ts for what the split buys.

test("a content-carrying submit is split from its CR", () => {
  expect(submittedLine("run the tests\r")).toBe("run the tests");
  // The case the split exists for: past the guest's 64-character threshold the
  // CR stops arriving as a key event of its own.
  const long = "x".repeat(200);
  expect(submittedLine(`${long}\r`)).toBe(long);
  expect(submittedLine("\x1b[A\r")).toBe("\x1b[A");
});

test("only the submitting CR is separated", () => {
  // An interior CR belongs to the body — separating it would submit the first
  // line and fire the rest at whatever the agent draws next.
  expect(submittedLine("line one\rline two\r")).toBe("line one\rline two");
});

test("anything that is not a content-carrying submit is written through", () => {
  for (const data of ["\r", "\x1b\r", "abc", "\x1b", ""]) {
    expect(submittedLine(data)).toBeNull();
  }
});

// A coding agent enables mouse reporting as it starts, so these arrive from a user
// who has touched no key — and `typedSessions` outlives the frame that set it, so
// one of them makes the NEXT bare Enter open a turn nothing will ever close.
test("a mouse or focus report is not typed content", () => {
  for (const seq of [
    "\x1b[<0;12;5M", "\x1b[<0;12;5m", "\x1b[<35;80;24M", // SGR press / release / motion
    "\x1b[M\x20\x30\x28",                                 // X10
    "\x1b[32;80;24M",                                     // urxvt
    "\x1b[I", "\x1b[O",                                   // focus in / out
  ]) {
    expect(hasTypedContent(seq)).toBe(false);
  }
});

// Why the exclusion is a shape test and not "starts with ESC": dropping every
// escape sequence loses arrow-key history recall, which IS a real prompt.
test("the escape sequences a human produces still count", () => {
  for (const seq of ["\x1b[A", "\x1b[B", "\x1b[C", "\x1b[D", "\x1bOA", "\x1b[3~", "\x1b[1;5C"]) {
    expect(hasTypedContent(seq)).toBe(true);
  }
});

// A mouse report can never end in CR — X10 offsets its coordinates by 32, so no
// byte in one is `\r` — which is why nothing above can reach the submit split.
test("the submit split is untouched by pointer reports", () => {
  expect(submittedLine("\x1b[<0;12;5M")).toBeNull();
  expect(submittedLine("hello\r")).toBe("hello");
});
