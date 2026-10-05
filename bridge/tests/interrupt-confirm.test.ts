import { expect, test } from "bun:test";
import { InterruptConfirmer, type InterruptConfirmDeps } from "../src/interrupt-confirm";

/**
 * An in-memory transcript plus a manually-ticked poll, so a test drives the
 * confirmation window without a real sleep and without a real file on disk.
 * `ticks` holds every poll callback the confirmer has scheduled, in order —
 * `ticks[0]()` fires exactly the one poll a real setInterval would have.
 */
function fakeDeps() {
  let clock = 0;
  const files = new Map<string, string>();
  const ticks: Array<() => void> = [];
  const cleared: unknown[] = [];
  const deps: InterruptConfirmDeps = {
    now: () => clock,
    setRepeating: (fn) => {
      const handle = {};
      ticks.push(fn);
      return handle;
    },
    clearRepeating: (handle) => {
      cleared.push(handle);
    },
    fileSize: (path) => {
      const content = files.get(path);
      return content === undefined ? undefined : Buffer.byteLength(content, "utf8");
    },
    readAppended: async (path, from) => {
      const content = files.get(path);
      if (content === undefined) return "";
      const buf = Buffer.from(content, "utf8");
      if (from >= buf.length) return "";
      return buf.subarray(from).toString("utf8");
    },
  };
  return {
    deps,
    advance: (ms: number) => { clock += ms; },
    files,
    ticks,
    cleared,
  };
}

const isMarker = (record: unknown): boolean =>
  typeof record === "object" && record !== null && (record as { marker?: unknown }).marker === true;

test("missing transcript file never starts a timer", () => {
  const { deps, ticks } = fakeDeps();
  const confirmer = new InterruptConfirmer(deps);
  const confirmed: string[] = [];
  confirmer.arm("s1", "/no/such/file", isMarker, () => confirmed.push("s1"));
  expect(ticks).toHaveLength(0);
  expect(confirmed).toHaveLength(0);
});

test("a marker appended after arm confirms and cancels its own reader", async () => {
  const { deps, files, ticks, cleared } = fakeDeps();
  const confirmer = new InterruptConfirmer(deps);
  files.set("/t.jsonl", "");
  const confirmed: string[] = [];
  confirmer.arm("s1", "/t.jsonl", isMarker, () => confirmed.push("s1"));
  expect(ticks).toHaveLength(1);
  files.set("/t.jsonl", '{"marker":true}\n');
  await ticks[0]!();
  expect(confirmed).toEqual(["s1"]);
  expect(cleared).toHaveLength(1); // the match cancels its own reader
});

test("a marker already in the file BEFORE arm is never seen — only bytes appended after the baseline count", async () => {
  const { deps, files, ticks } = fakeDeps();
  const confirmer = new InterruptConfirmer(deps);
  files.set("/t.jsonl", '{"marker":true}\n');
  const confirmed: string[] = [];
  confirmer.arm("s1", "/t.jsonl", isMarker, () => confirmed.push("s1"));
  // Nothing appended since arm — the pre-existing marker sits before the
  // baseline offset and must not be read.
  await ticks[0]!();
  expect(confirmed).toHaveLength(0);
});

test("a non-matching line appended after arm does not confirm; the window then times out and cancels", async () => {
  const { deps, files, ticks, cleared, advance } = fakeDeps();
  const confirmer = new InterruptConfirmer(deps);
  files.set("/t.jsonl", "");
  const confirmed: string[] = [];
  confirmer.arm("s1", "/t.jsonl", isMarker, () => confirmed.push("s1"));
  files.set("/t.jsonl", '{"marker":false}\n');
  await ticks[0]!();
  expect(confirmed).toHaveLength(0);
  expect(cleared).toHaveLength(0); // still within the window
  advance(10_000);
  await ticks[0]!();
  expect(confirmed).toHaveLength(0);
  expect(cleared).toHaveLength(1); // the window ran out with no match
});

test("two keys in a row is one reader — the second arm extends the deadline instead of starting a second poll", async () => {
  const { deps, files, ticks, advance } = fakeDeps();
  const confirmer = new InterruptConfirmer(deps);
  files.set("/t.jsonl", "");
  const confirmed: string[] = [];
  confirmer.arm("s1", "/t.jsonl", isMarker, () => confirmed.push("s1"));
  advance(2_000);
  confirmer.arm("s1", "/t.jsonl", isMarker, () => confirmed.push("s1")); // same session, second key
  expect(ticks).toHaveLength(1); // no second reader
  // Without the extension the ORIGINAL 3s deadline (now 2s past) would already
  // have expired; the second key resets the window from t=2000.
  advance(2_000);
  files.set("/t.jsonl", '{"marker":true}\n');
  await ticks[0]!();
  expect(confirmed).toEqual(["s1"]);
});

test("cancel stops a pending confirmation from ever firing, even if the file later matches", async () => {
  const { deps, files, ticks, cleared } = fakeDeps();
  const confirmer = new InterruptConfirmer(deps);
  files.set("/t.jsonl", "");
  const confirmed: string[] = [];
  confirmer.arm("s1", "/t.jsonl", isMarker, () => confirmed.push("s1"));
  const tick = ticks[0]!;
  confirmer.cancel("s1");
  expect(cleared).toHaveLength(1);
  files.set("/t.jsonl", '{"marker":true}\n');
  await tick(); // a stray tick from the (now-cleared, but still-referenced) old timer
  expect(confirmed).toHaveLength(0);
});

test("a line split across two polls is stitched before parsing", async () => {
  const { deps, files, ticks } = fakeDeps();
  const confirmer = new InterruptConfirmer(deps);
  files.set("/t.jsonl", "");
  const confirmed: string[] = [];
  confirmer.arm("s1", "/t.jsonl", isMarker, () => confirmed.push("s1"));
  files.set("/t.jsonl", '{"mark');
  await ticks[0]!();
  expect(confirmed).toHaveLength(0); // no newline yet — nothing to parse
  files.set("/t.jsonl", '{"mark' + 'er":true}\n');
  await ticks[0]!();
  expect(confirmed).toEqual(["s1"]);
});

test("a tick landing while a read is still in flight is skipped, not run as a second overlapping poll", async () => {
  const { deps: baseDeps, files, ticks } = fakeDeps();
  files.set("/t.jsonl", "");
  let readCalls = 0;
  const gates: Array<() => void> = [];
  const deps: InterruptConfirmDeps = {
    ...baseDeps,
    readAppended: async (path, from) => {
      readCalls++;
      await new Promise<void>((resolve) => gates.push(resolve));
      const content = files.get(path);
      if (content === undefined) return "";
      return content.slice(from);
    },
  };
  const confirmer = new InterruptConfirmer(deps);
  const confirmed: string[] = [];
  confirmer.arm("s1", "/t.jsonl", isMarker, () => confirmed.push("s1"));
  ticks[0]!(); // starts a read that never resolves until we release it below
  ticks[0]!(); // a second tick landing before the first read returns
  expect(readCalls).toBe(1); // the overlapping tick found a poll already in flight
  files.set("/t.jsonl", '{"marker":true}\n');
  gates.shift()!();
  // A real macrotask tick, not a microtask flush: the release above resumes a
  // chain of awaits inside poll() whose exact depth is an implementation
  // detail this test has no business pinning.
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(confirmed).toEqual(["s1"]);
});

test("confirmations on two sessions are independent", async () => {
  const { deps, files, ticks } = fakeDeps();
  const confirmer = new InterruptConfirmer(deps);
  files.set("/a.jsonl", "");
  files.set("/b.jsonl", "");
  const confirmed: string[] = [];
  confirmer.arm("a", "/a.jsonl", isMarker, () => confirmed.push("a"));
  confirmer.arm("b", "/b.jsonl", isMarker, () => confirmed.push("b"));
  expect(ticks).toHaveLength(2);
  files.set("/a.jsonl", '{"marker":true}\n');
  await ticks[0]!();
  expect(confirmed).toEqual(["a"]);
  // b's file never grew, so its own poll finds nothing.
  await ticks[1]!();
  expect(confirmed).toEqual(["a"]);
});
