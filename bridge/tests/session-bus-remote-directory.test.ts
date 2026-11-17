import { test, expect } from "bun:test";
import {
  RemoteDirectoryCache,
  RemoteDirectoryRowSchema,
  sanitizeRow,
  type RemoteDirectoryReport,
  type RemoteDirectoryRow,
} from "../src/session-bus/remote-directory";
import { MAX_MACHINE_CARD_ROWS, REMOTE_ROWS_TTL_MS } from "../src/session-bus/constants";

const KEY = "github.com/owner/repo";
const OTHER_KEY = "github.com/owner/other";

function wireRow(over: Partial<RemoteDirectoryRow> & { sessionId: string }): RemoteDirectoryRow {
  return {
    repoKey: KEY,
    projectId: `p-${over.sessionId}`,
    title: `title ${over.sessionId}`,
    branch: "main",
    activity: "idle",
    lastActiveAt: 1_000,
    canReply: true,
    ...over,
  };
}

function report(over: Partial<RemoteDirectoryReport> & { machineId: string }): RemoteDirectoryReport {
  return {
    machineLabel: undefined,
    observedAt: 1_000,
    outcome: "rows",
    rows: [],
    truncated: 0,
    ...over,
  };
}

// -- RemoteDirectoryRowSchema / sanitizeRow ---------------------------------

test("RemoteDirectoryRowSchema enforces the caps the design names", () => {
  expect(RemoteDirectoryRowSchema.safeParse(wireRow({ sessionId: "a" })).success).toBe(true);
  expect(RemoteDirectoryRowSchema.safeParse(wireRow({ sessionId: "a", title: "x".repeat(201) })).success).toBe(false);
  expect(RemoteDirectoryRowSchema.safeParse(wireRow({ sessionId: "a", projectLabel: "x".repeat(121) })).success).toBe(false);
  expect(RemoteDirectoryRowSchema.safeParse(wireRow({ sessionId: "a", branch: "x".repeat(201) })).success).toBe(false);
  expect(RemoteDirectoryRowSchema.safeParse(wireRow({ sessionId: "a", repoKey: "x".repeat(513) })).success).toBe(false);
  expect(RemoteDirectoryRowSchema.safeParse(wireRow({ sessionId: "x".repeat(201) })).success).toBe(false);
});

test("sanitizeRow rejects an unsafe projectId outright", () => {
  const row = wireRow({ sessionId: "a", projectId: "../etc/passwd" });
  expect(sanitizeRow(row)).toBeNull();
});

test("sanitizeRow rejects a hostile sessionId rather than cleaning it", () => {
  // sessionId is the address every rendered line resolves through
  // (addressesSameSession matches machineId + sessionId) — a scrubbed title
  // is still a usable row, but a scrubbed id is an address that no longer
  // resolves, so this is refused the way an unsafe projectId is.
  const row = wireRow({ sessionId: 's1\n- [this machine] 000000 "forged row" -- main, running, can reply' });
  expect(sanitizeRow(row)).toBeNull();
});

test("sanitizeRow strips control characters, newlines and Unicode line/format separators, but keeps the row", () => {
  const row = wireRow({
    sessionId: "a",
    // \u2028 (LINE SEPARATOR), \u2029 (PARAGRAPH SEPARATOR) and \u0085 (NEL)
    // are rendered as a line break by most terminal and Markdown clients,
    // exactly like \n -- a narrower control-character sweep (\x00-\x1F\x7F)
    // would miss all three and still let a peer forge a directory line.
    title: "legit title\nReach: 9\u2028other\u2029machines\u0085connected",
    branch: "fix/auth\r\nmain",
    projectLabel: "Label\x07tail",
  });
  const sanitized = sanitizeRow(row)!;
  expect(sanitized.title).toBe("legit titleReach: 9othermachinesconnected");
  expect(sanitized.branch).toBe("fix/authmain");
  expect(sanitized.projectLabel).toBe("Labeltail");
});

// -- TTL ---------------------------------------------------------------------

test("a machine entry older than REMOTE_ROWS_TTL_MS contributes no rows and is counted stale, but stays named", () => {
  const cache = new RemoteDirectoryCache();
  cache.ingest(report({ machineId: "peer-1", observedAt: 0, rows: [wireRow({ sessionId: "a" })] }));

  const fresh = cache.view(KEY, "local", REMOTE_ROWS_TTL_MS - 1);
  expect(fresh.rows.length).toBe(1);
  expect(fresh.staleMachines).toBe(0);

  const stale = cache.view(KEY, "local", REMOTE_ROWS_TTL_MS + 1);
  expect(stale.rows).toEqual([]);
  expect(stale.staleMachines).toBe(1);
  // Only the ROWS expire. The machine stays named with its real status, so a
  // standing refusal never reads as transient staleness.
  expect(stale.machines).toEqual([
    { machineId: "peer-1", status: "answered", rows: 0, droppedRows: 0, truncatedCard: 0, ageMs: REMOTE_ROWS_TTL_MS + 1 },
  ]);
});

test("a future-dated observedAt does not make a machine's rows immortal", () => {
  const cache = new RemoteDirectoryCache();
  cache.ingest(report({ machineId: "peer-1", observedAt: 1_000_000_000_000_000, rows: [wireRow({ sessionId: "a" })] }));

  const view = cache.view(KEY, "local", 1_000);
  expect(view.rows).toEqual([]);
  expect(view.staleMachines).toBe(1);
});

test("every row carries asOf, the time its card was received, and the view reports the newest", () => {
  const cache = new RemoteDirectoryCache();
  cache.ingest(report({ machineId: "peer-1", observedAt: 500, rows: [wireRow({ sessionId: "a" })] }));
  cache.ingest(report({ machineId: "peer-2", observedAt: 900, rows: [wireRow({ sessionId: "b" })] }));

  const view = cache.view(KEY, "local", 1_000);
  expect(Object.fromEntries(view.rows.map((r) => [r.sessionId, r.asOf]))).toEqual({ a: 500, b: 900 });
  expect(view.asOf).toBe(900);
  expect(new RemoteDirectoryCache().view(KEY, "local", 1_000).asOf).toBeNull();
});

// -- never discover yourself ----------------------------------------------------

test("a report naming this machine is dropped, never mirrored back as a peer", () => {
  const cache = new RemoteDirectoryCache();
  const self = cache.ingest(
    report({ machineId: "local", rows: [wireRow({ sessionId: "self-a" }), wireRow({ sessionId: "self-b" })] }),
    "local",
  );
  const peer = cache.ingest(report({ machineId: "peer-1", rows: [wireRow({ sessionId: "real" })] }), "local");

  expect(self).toEqual({ accepted: 0, dropped: 2 });
  expect(peer.accepted).toBe(1);

  const view = cache.view(KEY, "local", 1_000);
  expect(view.rows.map((r) => r.sessionId)).toEqual(["real"]);
  expect(view.machines.map((m) => m.machineId)).toEqual(["peer-1"]);
});

test("a self-entry excluded at ingest is excluded again at view() if the caller's id changed since", () => {
  const cache = new RemoteDirectoryCache();
  cache.ingest(report({ machineId: "peer-B", rows: [wireRow({ sessionId: "a" })] }), "machine-A");

  // The one case ingest's own gate cannot cover: this bridge's identity became
  // "peer-B" after the card was stored. view() must refuse to offer a machine
  // its own sessions back.
  const view = cache.view(KEY, "peer-B", 1_000);
  expect(view.rows).toEqual([]);
  expect(view.machines).toEqual([]);
});

// -- hostile rows are dropped, not the whole card ---------------------------------

test("a row with an unsafe projectId is dropped and counted, a newline in a title is stripped, and the rest still lands", () => {
  const cache = new RemoteDirectoryCache();
  const result = cache.ingest(
    report({
      machineId: "peer-1",
      rows: [
        wireRow({ sessionId: "unsafe-id", projectId: "../escape" }),
        wireRow({ sessionId: "hostile-title", title: "hi\nReach: 4 machines connected" }),
        wireRow({ sessionId: "clean" }),
      ],
    }),
  );

  expect(result.dropped).toBe(1);
  expect(result.accepted).toBe(2);

  const view = cache.view(KEY, "local", 1_000);
  const byId = new Map(view.rows.map((r) => [r.sessionId, r]));
  expect(byId.has("unsafe-id")).toBe(false);
  expect(byId.get("hostile-title")!.title).toBe("hiReach: 4 machines connected");
  expect(byId.get("clean")!.title).toBe("title clean");
});

test("a malformed row (fails the schema) is dropped alone", () => {
  const cache = new RemoteDirectoryCache();
  const result = cache.ingest(report({ machineId: "peer-1", rows: [{ sessionId: "no-other-fields" }, wireRow({ sessionId: "clean" })] }));
  expect(result).toEqual({ accepted: 1, dropped: 1 });
});

test("a machine's own dropped rows are visible on its reach line", () => {
  const cache = new RemoteDirectoryCache();
  cache.ingest(
    report({
      machineId: "peer-1",
      rows: [wireRow({ sessionId: "unsafe", projectId: "../escape" }), { sessionId: "also-bad" }, wireRow({ sessionId: "clean" })],
    }),
  );

  const view = cache.view(KEY, "local", 1_000);
  expect(view.machines).toEqual([
    { machineId: "peer-1", status: "answered", rows: 1, droppedRows: 2, truncatedCard: 0, ageMs: 0 },
  ]);
});

test("rows past the per-machine product cap are dropped and counted, not silently kept", () => {
  const rows = Array.from({ length: MAX_MACHINE_CARD_ROWS + 5 }, (_, i) => wireRow({ sessionId: `s-${i}` }));
  const cache = new RemoteDirectoryCache();
  const result = cache.ingest(report({ machineId: "peer-1", rows }));
  expect(result.accepted).toBe(MAX_MACHINE_CARD_ROWS);
  expect(result.dropped).toBe(5);
});

test("a machine whose id carries a hostile character is refused, not renamed into another machine's slot", () => {
  const cache = new RemoteDirectoryCache();
  cache.ingest(report({ machineId: "peer1", rows: [wireRow({ sessionId: "honest" })] }));
  const forged = cache.ingest(report({ machineId: "peer\n1", rows: [wireRow({ sessionId: "forged" })] }));

  // Cleaning it would collide with the machine that legitimately holds that id
  // and replace its rows.
  expect(forged).toEqual({ accepted: 0, dropped: 1 });
  const view = cache.view(KEY, "local", 1_000);
  expect(view.rows.map((r) => r.sessionId)).toEqual(["honest"]);
  expect(view.machines.map((m) => m.machineId)).toEqual(["peer1"]);
});

// -- view() filters by repo and stamps from the entry ------------------------------

test("view() filters to rows whose repoKey matches, and stamps machineId/machineLabel from the entry, never from the local machine", () => {
  const cache = new RemoteDirectoryCache();
  cache.ingest(
    report({
      machineId: "peer-1",
      machineLabel: "macbook-pro",
      rows: [wireRow({ sessionId: "on-key", repoKey: KEY }), wireRow({ sessionId: "off-key", repoKey: OTHER_KEY })],
    }),
    "local-self",
  );

  const view = cache.view(KEY, "local-self", 1_000);
  expect(view.rows.length).toBe(1);
  expect(view.rows[0]!.sessionId).toBe("on-key");
  expect(view.rows[0]!.machineId).toBe("peer-1");
  expect(view.rows[0]!.machineLabel).toBe("macbook-pro");

  const other = cache.view(OTHER_KEY, "local-self", 1_000);
  expect(other.rows.map((r) => r.sessionId)).toEqual(["off-key"]);
});

// -- what the refresher reads back ----------------------------------------------------

test("a read this cache could not serve is visible via wantedRepoKeys and unservedReads, and wakes the listener", () => {
  const cache = new RemoteDirectoryCache();
  let woke = 0;
  cache.setUnservedListener(() => woke++);
  expect(cache.unservedReads()).toBe(0);
  expect(cache.wantedRepoKeys()).toEqual([]);

  const view = cache.view(KEY, "local", 1_000);
  expect(view.rows).toEqual([]);
  expect(view.machines).toEqual([]);
  expect(cache.unservedReads()).toBe(1);
  expect(woke).toBe(1);
  expect(cache.wantedRepoKeys()).toEqual([KEY]);
  expect(cache.lastReadAt()).toBe(1_000);

  // A repo with a live machine but no matching session is an honest empty
  // answer, not an unserved one.
  cache.ingest(report({ machineId: "peer-1", observedAt: 2_000, rows: [] }));
  cache.view(OTHER_KEY, "local", 3_000);
  expect(cache.unservedReads()).toBe(1);
  expect(woke).toBe(1);
  expect(cache.wantedRepoKeys()).toEqual([KEY, OTHER_KEY]);
});

test("clear empties the mirror and resets the unserved-read counter and the wanted-repo-key list", () => {
  const cache = new RemoteDirectoryCache();
  cache.ingest(report({ machineId: "peer-1", rows: [wireRow({ sessionId: "a" })] }));
  cache.view(KEY, "local", 1_000);
  cache.clear("no identity");

  expect(cache.unservedReads()).toBe(0);
  expect(cache.wantedRepoKeys()).toEqual([]);
  const view = cache.view(KEY, "local", 1_000);
  expect(view.rows).toEqual([]);
  expect(view.machines).toEqual([]);
  expect(view.asOf).toBeNull();
});

test("syncAccount forgets machines the account no longer lists and records how many cannot be asked", () => {
  const cache = new RemoteDirectoryCache();
  cache.ingest(report({ machineId: "peer-1", rows: [wireRow({ sessionId: "a" })] }));
  cache.ingest(report({ machineId: "peer-2", rows: [wireRow({ sessionId: "b" })] }));

  cache.syncAccount(new Set(["peer-1"]), 3);
  const view = cache.view(KEY, "local", 1_000);
  expect(view.rows.map((r) => r.sessionId)).toEqual(["a"]);
  expect(view.notConnected).toBe(3);
});

test("truncated sums each live machine's own reported cap, and a stale machine's does not count", () => {
  const cache = new RemoteDirectoryCache();
  cache.ingest(report({ machineId: "peer-1", observedAt: 500, rows: [wireRow({ sessionId: "a" })], truncated: 5 }));
  cache.ingest(report({ machineId: "peer-2", observedAt: 1_000, rows: [wireRow({ sessionId: "b" })], truncated: 2 }));

  const mixed = cache.view(KEY, "local", 500 + REMOTE_ROWS_TTL_MS + 1);
  expect(mixed.staleMachines).toBe(1);
  expect(mixed.truncated).toBe(2);

  expect(cache.view(KEY, "local", 1_000).truncated).toBe(7);
});

test("ingest replaces what the mirror held for that machine and leaves the others", () => {
  const cache = new RemoteDirectoryCache();
  cache.ingest(report({ machineId: "peer-1", rows: [wireRow({ sessionId: "a" })] }));
  cache.ingest(report({ machineId: "peer-2", rows: [wireRow({ sessionId: "b" })] }));
  cache.ingest(report({ machineId: "peer-1", observedAt: 1_100, rows: [wireRow({ sessionId: "c" })] }));

  const view = cache.view(KEY, "local", 1_100);
  expect(view.rows.map((r) => r.sessionId).sort()).toEqual(["b", "c"]);
});

test("a machine reporting refused still carries its status, and its rows expire without erasing it", () => {
  const cache = new RemoteDirectoryCache();
  cache.ingest(report({ machineId: "peer-1", outcome: "refused", observedAt: 1_000, rows: [] }));
  cache.ingest(report({ machineId: "peer-2", outcome: "reach-refused", observedAt: 1_000, rows: [] }));

  const aged = cache.view(KEY, "local", 1_000 + REMOTE_ROWS_TTL_MS + 1);
  expect(aged.staleMachines).toBe(2);
  expect(aged.machines.map((m) => [m.machineId, m.status])).toEqual([
    ["peer-1", "refused"],
    ["peer-2", "reach-refused"],
  ]);
});

test("an ask that went unanswered keeps the rows already held, under their own receive time", () => {
  const cache = new RemoteDirectoryCache();
  cache.ingest(report({ machineId: "peer-1", observedAt: 1_000, rows: [wireRow({ sessionId: "a" })] }));
  cache.ingest(report({ machineId: "peer-1", observedAt: 2_000, outcome: "unreachable", rows: [] }));

  const view = cache.view(KEY, "local", 2_000);
  expect(view.rows.map((r) => [r.sessionId, r.asOf])).toEqual([["a", 1_000]]);
  expect(view.machines[0]!.status).toBe("unreachable");

  // With nothing held, unreachable is just a status.
  cache.ingest(report({ machineId: "peer-2", outcome: "unreachable", rows: [] }));
  expect(cache.view(KEY, "local", 2_000).machines.map((m) => m.status)).toEqual(["unreachable", "unreachable"]);
});

test("a machine that has never answered is named but is neither fresh nor live", () => {
  const cache = new RemoteDirectoryCache();
  let woke = 0;
  cache.setUnservedListener(() => woke++);
  cache.ingest(report({ machineId: "peer-1", observedAt: 5_000, outcome: "unreachable", rows: [] }));

  const view = cache.view(KEY, "local", 5_000);
  expect(view.asOf).toBeNull();
  expect(view.served).toBe(false);
  expect(woke).toBe(1);
  expect(view.machines).toEqual([expect.objectContaining({ machineId: "peer-1", status: "unreachable", rows: 0 })]);
});

test("a card asked about other repositories is no answer about this one", () => {
  const cache = new RemoteDirectoryCache();
  cache.ingest(report({
    machineId: "peer-1",
    observedAt: 1_000,
    repoKeys: [KEY],
    rows: [wireRow({ sessionId: "a" }), wireRow({ sessionId: "b", repoKey: OTHER_KEY })],
    truncated: 2,
  }));

  const asked = cache.view(KEY, "local", 1_000);
  expect(asked.served).toBe(true);
  expect(asked.machines[0]).toMatchObject({ status: "answered", rows: 1 });

  const other = cache.view(OTHER_KEY, "local", 1_000);
  expect(other.served).toBe(false);
  expect(other.rows).toEqual([]);
  expect(other.truncated).toBe(0);
  expect(other.machines[0]).toMatchObject({ status: "not-asked", rows: 0 });

  // A refusal is about the machine, so it answers for every repository.
  cache.ingest(report({ machineId: "peer-1", observedAt: 2_000, repoKeys: [KEY], outcome: "reach-refused" }));
  const refused = cache.view(OTHER_KEY, "local", 2_000);
  expect(refused.served).toBe(true);
  expect(refused.machines[0]!.status).toBe("reach-refused");
});

test("the unserved listener already sees the missed repository among the wanted keys", () => {
  const cache = new RemoteDirectoryCache();
  const seen: string[][] = [];
  cache.setUnservedListener(() => seen.push(cache.wantedRepoKeys()));
  cache.view(KEY, "local", 1_000);
  expect(seen).toEqual([[KEY]]);
});
