import { describe, expect, test } from "bun:test";
import { buildSpawnEnv, routeScannerEvent } from "../src/terminal-session";
import type { NotificationEvent } from "../src/notification-scanner";

// Unit tests for the two pure helpers extracted to make the task's real
// contracts regression-safe without spawning a live PTY.

// ---------------------------------------------------------------------------
// buildSpawnEnv — env builder
// ---------------------------------------------------------------------------
describe("buildSpawnEnv", () => {
  test("ANTGRID_TERMINAL_ID is always set to the terminalId", () => {
    const env = buildSpawnEnv("term-42", undefined, {});
    expect(env.ANTGRID_TERMINAL_ID).toBe("term-42");
  });

  test("ANTGRID_API_PORT is present (stringified) when a port is given", () => {
    const env = buildSpawnEnv("t1", 1234, {});
    expect(env.ANTGRID_API_PORT).toBe("1234");
  });

  test("ANTGRID_API_PORT is absent when port is null", () => {
    const env = buildSpawnEnv("t1", null, {});
    expect("ANTGRID_API_PORT" in env).toBe(false);
  });

  test("ANTGRID_API_PORT is absent when port is undefined", () => {
    const env = buildSpawnEnv("t1", undefined, {});
    expect("ANTGRID_API_PORT" in env).toBe(false);
  });

  test("caller env key is preserved", () => {
    const env = buildSpawnEnv("t1", undefined, { FOO: "bar" });
    expect(env.FOO).toBe("bar");
  });

  test("ANTGRID_TERMINAL_ID wins over caller's own ANTGRID_TERMINAL_ID", () => {
    // Antgrid keys always overwrite; caller cannot inject a fake terminal id.
    const env = buildSpawnEnv("real-id", undefined, { ANTGRID_TERMINAL_ID: "fake-id" });
    expect(env.ANTGRID_TERMINAL_ID).toBe("real-id");
  });

  test("ANTGRID_API_PORT wins over caller's own ANTGRID_API_PORT", () => {
    const env = buildSpawnEnv("t1", 9999, { ANTGRID_API_PORT: "1111" });
    expect(env.ANTGRID_API_PORT).toBe("9999");
  });
});

// ---------------------------------------------------------------------------
// routeScannerEvent — per-event routing decision
// ---------------------------------------------------------------------------
describe("routeScannerEvent", () => {
  test("non-empty title event routes to title sink only (not notification)", () => {
    const titleCalls: string[] = [];
    const notifCalls: NotificationEvent[] = [];
    const ev: NotificationEvent = { kind: "title", title: "My Agent" };
    routeScannerEvent(ev, (t) => titleCalls.push(t), (e) => notifCalls.push(e));
    expect(titleCalls).toEqual(["My Agent"]);
    expect(notifCalls).toHaveLength(0);
  });

  test("empty title event routes to neither sink", () => {
    const titleCalls: string[] = [];
    const notifCalls: NotificationEvent[] = [];
    const ev: NotificationEvent = { kind: "title", title: "" };
    routeScannerEvent(ev, (t) => titleCalls.push(t), (e) => notifCalls.push(e));
    expect(titleCalls).toHaveLength(0);
    expect(notifCalls).toHaveLength(0);
  });

  test("title event with absent title routes to neither sink", () => {
    // Locks the drop invariant for an undefined (not just empty) title so a
    // missing title can never wipe a good name or leak to the notification path.
    const titleCalls: string[] = [];
    const notifCalls: NotificationEvent[] = [];
    const ev: NotificationEvent = { kind: "title" };
    routeScannerEvent(ev, (t) => titleCalls.push(t), (e) => notifCalls.push(e));
    expect(titleCalls).toHaveLength(0);
    expect(notifCalls).toHaveLength(0);
  });

  test("osc9 event with body routes to notification sink (not title)", () => {
    const titleCalls: string[] = [];
    const notifCalls: NotificationEvent[] = [];
    const ev: NotificationEvent = { kind: "osc9", body: "Build finished" };
    routeScannerEvent(ev, (t) => titleCalls.push(t), (e) => notifCalls.push(e));
    expect(titleCalls).toHaveLength(0);
    expect(notifCalls).toHaveLength(1);
    expect(notifCalls[0]!.kind).toBe("osc9");
    expect(notifCalls[0]!.body).toBe("Build finished");
  });

  test("osc777 event routes to notification sink with title and body", () => {
    const titleCalls: string[] = [];
    const notifCalls: NotificationEvent[] = [];
    const ev: NotificationEvent = { kind: "osc777", title: "Done", body: "Tests passed" };
    routeScannerEvent(ev, (t) => titleCalls.push(t), (e) => notifCalls.push(e));
    expect(titleCalls).toHaveLength(0);
    expect(notifCalls).toHaveLength(1);
    expect(notifCalls[0]!.kind).toBe("osc777");
    expect(notifCalls[0]!.title).toBe("Done");
    expect(notifCalls[0]!.body).toBe("Tests passed");
  });

  test("osc9 event routes to notification sink", () => {
    const titleCalls: string[] = [];
    const notifCalls: NotificationEvent[] = [];
    const ev: NotificationEvent = { kind: "osc9", body: "hi" };
    routeScannerEvent(ev, (t) => titleCalls.push(t), (e) => notifCalls.push(e));
    expect(titleCalls).toHaveLength(0);
    expect(notifCalls).toHaveLength(1);
    expect(notifCalls[0]!.kind).toBe("osc9");
  });

  test("title sink is optional — no throw when absent for title event", () => {
    // Passing undefined as title sink must not throw (optional callback path).
    const notifCalls: NotificationEvent[] = [];
    const ev: NotificationEvent = { kind: "title", title: "X" };
    expect(() => routeScannerEvent(ev, undefined, (e) => notifCalls.push(e))).not.toThrow();
  });
});
