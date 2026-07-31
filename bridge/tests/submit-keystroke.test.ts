import { expect, test } from "bun:test";
import { isSubmitKeystroke } from "../src/agent-core";

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
