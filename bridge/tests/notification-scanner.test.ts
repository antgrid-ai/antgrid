import { describe, test, expect } from "bun:test";
import { TerminalNotificationScanner } from "../src/notification-scanner";

test("bare BEL in ground state is not a notification (renderer rings it)", () => {
  const s = new TerminalNotificationScanner();
  expect(s.feed("hello\x07world", 0)).toEqual([]);
  expect(s.feed("\x07\x07\x07", 0)).toEqual([]);
});

test("OSC 9 with BEL terminator → osc9 notify, no bell from terminator", () => {
  const s = new TerminalNotificationScanner();
  expect(s.feed("\x1b]9;Build finished\x07", 0)).toEqual([
    { kind: "osc9", body: "Build finished" },
  ]);
});

test("OSC 9 with ST terminator (ESC backslash)", () => {
  const s = new TerminalNotificationScanner();
  expect(s.feed("\x1b]9;done\x1b\\", 0)).toEqual([
    { kind: "osc9", body: "done" },
  ]);
});

test("OSC split across two feed() calls → single notify", () => {
  const s = new TerminalNotificationScanner();
  expect(s.feed("\x1b]9;Build fin", 0)).toEqual([]);
  expect(s.feed("ished\x07", 0)).toEqual([{ kind: "osc9", body: "Build finished" }]);
});

test("BEL inside DCS string is swallowed, not a bell", () => {
  const s = new TerminalNotificationScanner();
  // ESC P ... BEL ... ESC backslash  (DCS passthrough)
  expect(s.feed("\x1bPdata\x07more\x1b\\", 0)).toEqual([]);
});

test("ConEmu progress 9;4;1;50 is dropped", () => {
  const s = new TerminalNotificationScanner();
  expect(s.feed("\x1b]9;4;1;50\x07", 0)).toEqual([]);
});

test("ConEmu 9;1..9;6 forms are dropped", () => {
  const s = new TerminalNotificationScanner();
  for (const body of ["9;1;100", "9;2;hi", "9;3;tab", "9;5", "9;6;macro"]) {
    expect(s.feed(`\x1b]${body}\x07`, 0)).toEqual([]);
  }
});

test("ConEmu 9;9 set-CWD report (PowerShell on Windows) is dropped", () => {
  const s = new TerminalNotificationScanner();
  // PowerShell/Windows Terminal shell integration emits this every prompt.
  expect(s.feed('\x1b]9;9;"C:\\Users\\me\\proj"\x07', 0)).toEqual([]);
});

test("OSC 9 message starting with a digit (not ConEmu form) is a notification", () => {
  const s = new TerminalNotificationScanner();
  expect(s.feed("\x1b]9;5 items processed\x07", 0)).toEqual([
    { kind: "osc9", body: "5 items processed" },
  ]);
});

test("OSC 777 notify parses title and body; non-notify ignored", () => {
  const s = new TerminalNotificationScanner();
  expect(s.feed("\x1b]777;notify;Title;Body text\x07", 0)).toEqual([
    { kind: "osc777", title: "Title", body: "Body text" },
  ]);
  expect(s.feed("\x1b]777;something;x\x07", 0)).toEqual([]);
});

test("OSC body over 2KB is dropped and parser recovers", () => {
  const s = new TerminalNotificationScanner();
  const huge = "x".repeat(3000);
  expect(s.feed(`\x1b]9;${huge}\x07`, 0)).toEqual([]);     // overflow → dropped
  expect(s.feed("\x1b]9;ok\x07", 600)).toEqual([{ kind: "osc9", body: "ok" }]); // recovered
});

const BEL = "\x07";
const ST = "\x1b\\";

describe("OSC 0/2 title parsing", () => {
  test("OSC 2 with BEL terminator yields a title event", () => {
    const s = new TerminalNotificationScanner();
    const ev = s.feed(`\x1b]2;Fix login bug${BEL}`, 0);
    expect(ev).toEqual([{ kind: "title", title: "Fix login bug" }]);
  });

  test("OSC 0 (icon+title) yields a title event; ST terminator", () => {
    const s = new TerminalNotificationScanner();
    const ev = s.feed(`\x1b]0;My Session${ST}`, 0);
    expect(ev).toEqual([{ kind: "title", title: "My Session" }]);
  });

  test("title preserves embedded semicolons", () => {
    const s = new TerminalNotificationScanner();
    const ev = s.feed(`\x1b]2;a; b; c${BEL}`, 0);
    expect(ev).toEqual([{ kind: "title", title: "a; b; c" }]);
  });

  test("title split across feed() calls is buffered", () => {
    const s = new TerminalNotificationScanner();
    expect(s.feed("\x1b]2;Fix ", 0)).toEqual([]);
    expect(s.feed(`login${BEL}`, 0)).toEqual([{ kind: "title", title: "Fix login" }]);
  });

  test("OSC 2 interleaved with OSC 9 notification", () => {
    const s = new TerminalNotificationScanner();
    const ev = s.feed(`\x1b]2;Title${BEL}\x1b]9;hello${BEL}`, 0);
    expect(ev).toEqual([
      { kind: "title", title: "Title" },
      { kind: "osc9", body: "hello" },
    ]);
  });
});
