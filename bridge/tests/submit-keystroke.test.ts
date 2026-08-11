import { expect, test } from "bun:test";
import { hasTypedContent, isInterruptKeystroke, isSubmitKeystroke } from "../src/agent-core";

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
