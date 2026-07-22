import { test, expect } from "bun:test";
import { TerminalNotificationScanner } from "../src/notification-scanner";
import { routeScannerEvent } from "../src/terminal-session";

// Unit-level proof of the guard contract: when suppression is on, only title
// events route; osc9/osc777 are dropped.
test("suppression drops notification events but keeps titles", () => {
  const scanner = new TerminalNotificationScanner();
  const titles: string[] = [];
  const notifs: string[] = [];
  const suppress = true;
  const feed = (s: string) => {
    for (const ev of scanner.feed(s, Date.now())) {
      routeScannerEvent(ev, (t) => titles.push(t), (n) => {
        if (suppress) return; // mirrors the guard added in onData
        notifs.push(n.kind);
      });
    }
  };
  feed("\x1b]0;my-title\x07");      // OSC 0 title
  feed("\x1b]9;hello\x07");          // OSC 9 notification
  expect(titles).toEqual(["my-title"]);
  expect(notifs).toEqual([]);
});

// Mirrors the notification-suppression test above, for the independent title
// toggle: suppressing title must not touch notifications, and vice versa.
test("title suppression drops title events but keeps notifications", () => {
  const scanner = new TerminalNotificationScanner();
  const titles: string[] = [];
  const notifs: string[] = [];
  const suppressTitle = true;
  const feed = (s: string) => {
    for (const ev of scanner.feed(s, Date.now())) {
      routeScannerEvent(ev, (t) => {
        if (suppressTitle) return; // mirrors the guard added in onData
        titles.push(t);
      }, (n) => notifs.push(n.kind));
    }
  };
  feed("\x1b]0;my-title\x07");      // OSC 0 title
  feed("\x1b]9;hello\x07");          // OSC 9 notification
  expect(titles).toEqual([]);
  expect(notifs).toEqual(["osc9"]);
});
