import { expect, test } from "bun:test";
import {
  hasTypedContent,
  isCtrlC,
  isLoneEsc,
  isSubmitKeystroke,
  isTerminalReport,
  opensCommandLine,
  submittedLine,
} from "../src/keystrokes";
import { shouldArmInterruptConfirm } from "../src/agent-core";

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

// Byte identity only — a false positive on isLoneEsc would risk closing a turn
// still legitimately in flight (e.g. mid arrow-key nav), so only the exact
// bare-ESC byte counts. Whether the key actually closes a turn is confirmed
// against the transcript, tested separately below via
// shouldArmInterruptConfirm.

test("a bare Escape keypress is a lone Esc, legacy byte or kitty-protocol form", () => {
  expect(isLoneEsc("\x1b")).toBe(true);
  // CSI 27u: what a terminal negotiating the kitty keyboard protocol's
  // disambiguate flag sends for a bare Escape instead of the legacy byte.
  expect(isLoneEsc("\x1b[27u")).toBe(true);
  expect(isLoneEsc("\x1b[27;1u")).toBe(true); // explicit "no modifiers"
});

test("any longer ESC-prefixed sequence is content, not a lone Esc", () => {
  for (const data of [
    "\x1b[A", "\x1b[13;2u", "\x1b\r", "\x1bOP", "\x1b\x1b",
    "\x1b[27;2u", // Escape+Shift, a different key than bare Escape
    "\x1b[27",    // no final 'u' — not a complete kitty sequence
  ]) {
    expect(isLoneEsc(data)).toBe(false);
  }
});

test("ordinary keys and an empty payload are not a lone Esc", () => {
  for (const data of ["a", "\r", "\t", "\x03", ""]) {
    expect(isLoneEsc(data)).toBe(false);
  }
});

test("a bare Ctrl+C keypress is isCtrlC, legacy byte or kitty-protocol form", () => {
  expect(isCtrlC("\x03")).toBe(true);
  // CSI 99;5u: codepoint of 'c' with modifiers=5 (ctrl alone) — what the kitty
  // keyboard protocol's disambiguate flag sends instead of the raw ETX byte.
  expect(isCtrlC("\x1b[99;5u")).toBe(true);
  for (const data of [
    "a", "\r", "\t", "\x1b", "",
    "\x1b[99;7u", // ctrl+alt+c, a different combination than bare Ctrl+C
    "\x1b[99u",   // no modifiers at all — not a Ctrl+C
  ]) {
    expect(isCtrlC(data)).toBe(false);
  }
});

// Whether a lone Esc/Ctrl+C is even worth confirming against the transcript —
// consumed from agent-core's terminal:input handler, BEFORE the key reaches
// the PTY. It answers only "is there anything to confirm", never "did the key
// interrupt": that verdict is the transcript's alone (interrupt-confirm.ts).

test("opencode declares no transcript-interrupt predicate, so nothing arms — turn open or not", () => {
  expect(shouldArmInterruptConfirm("opencode", "\x1b", true, "/tmp/t.jsonl")).toBeUndefined();
  expect(shouldArmInterruptConfirm("opencode", "\x03", true, "/tmp/t.jsonl")).toBeUndefined();
});

test("an idle turn arms nothing, even for an agent with a predicate and a known path", () => {
  expect(shouldArmInterruptConfirm("claude-code", "\x1b", false, "/tmp/t.jsonl")).toBeUndefined();
});

test("an unknown transcript path arms nothing, even with an open turn", () => {
  expect(shouldArmInterruptConfirm("claude-code", "\x1b", true, undefined)).toBeUndefined();
});

test("a lone Esc on claude-code with an open turn and a known path returns claude's predicate", () => {
  const predicate = shouldArmInterruptConfirm("claude-code", "\x1b", true, "/tmp/t.jsonl");
  expect(predicate).toBeInstanceOf(Function);
});

test("Ctrl+C on codex with an open turn and a known path returns codex's predicate", () => {
  const predicate = shouldArmInterruptConfirm("codex", "\x03", true, "/tmp/t.jsonl");
  expect(predicate).toBeInstanceOf(Function);
});

test("an unknown/unlisted or undefined tool arms nothing", () => {
  expect(shouldArmInterruptConfirm("not-a-real-agent", "\x03", true, "/tmp/t.jsonl")).toBeUndefined();
  expect(shouldArmInterruptConfirm(undefined, "\x03", true, "/tmp/t.jsonl")).toBeUndefined();
});

test("only a lone Esc or Ctrl+C can arm — ordinary keys never do, even with everything else true", () => {
  for (const data of ["a", "\r", "\x1b[A", ""]) {
    expect(shouldArmInterruptConfirm("claude-code", data, true, "/tmp/t.jsonl")).toBeUndefined();
  }
});

// Gates the "not a user reply" branch in agent-core's terminal:input handler.
// A false negative is what let a window focus-change clear a blocked session's
// "needs you" dot; a false positive would silently drop real typing.

test("focus and mouse reports are the terminal answering, not a reply", () => {
  for (const data of [
    "\x1b[I", // DEC 1004 focus gained
    "\x1b[O", // DEC 1004 focus lost
    "\x1b[<0;12;7M", // SGR press
    "\x1b[<0;12;7m", // SGR release
    "\x1b[<64;1;1M", // SGR wheel
    "\x1b[M !!", // X10, three trailing bytes
  ]) {
    expect(isTerminalReport(data)).toBe(true);
  }
});

test("typed input is never mistaken for a report", () => {
  for (const data of [
    "a",
    "\r",
    "\x1b",
    "\x1b[A", // arrow up
    "\x1b[Ihello", // a report the user typed through
    "\x1b[13;2u", // kitty shift+enter
    "\x1b[2~", // insert
    "",
  ]) {
    expect(isTerminalReport(data)).toBe(false);
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

// The third half of the submit gate: a line the CLI answers itself runs no model
// turn, so no turn-end hook closes the turn an inferred start would open.
test("a leading slash opens a command line", () => {
  expect(opensCommandLine("/")).toBe(true);
  // Whole-line frames: a paste, or the app's send-to-agent composer.
  expect(opensCommandLine("/compact\r")).toBe(true);
  expect(opensCommandLine("/model opus\r")).toBe(true);
});

test("a slash anywhere but the front is ordinary content", () => {
  expect(opensCommandLine("fix /etc/hosts\r")).toBe(false);
  expect(opensCommandLine("f")).toBe(false);
  expect(opensCommandLine("\r")).toBe(false);
  // History recall and cursor movement open no line of their own.
  expect(opensCommandLine("\x1b[A")).toBe(false);
});

// The viewer's VT engine writes on this channel too, and nothing it wrote is a
// line the user opened.
test("a pointer report never opens a command line", () => {
  expect(opensCommandLine("\x1b[<0;12;5M")).toBe(false);
  expect(opensCommandLine("\x1b[I")).toBe(false);
});
