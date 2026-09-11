import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  RemoteDirectoryCache,
  RemoteDirectoryRowSchema,
  sanitizeRow,
  type RemoteDirectoryMachinePush,
  type RemoteDirectoryRow,
} from "../src/session-bus/remote-directory";
import { MAX_MACHINE_CARD_ROWS, MAX_REMOTE_DIRECTORY_MACHINES, REMOTE_ROWS_TTL_MS } from "../src/session-bus/constants";
import { ControlRequestSchema } from "../src/control-protocol";
import { MAX_CONTROL_BODY_BYTES } from "../src/control-listener";
import { HostServer, type HostRemoteConfig, type RemoteRuntime } from "../src/host-server";

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

function push(over: Partial<RemoteDirectoryMachinePush> & { machineId: string }): RemoteDirectoryMachinePush {
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

// -- property 1: TTL -----------------------------------------------------

test("a machine entry older than REMOTE_ROWS_TTL_MS contributes no rows and is counted stale, but stays named", () => {
  const cache = new RemoteDirectoryCache();
  cache.replace(
    [push({ machineId: "peer-1", observedAt: 0, rows: [wireRow({ sessionId: "a" })] })],
    0,
    "local",
    0,
  );

  const fresh = cache.view(KEY, "local", REMOTE_ROWS_TTL_MS - 1);
  expect(fresh.rows.length).toBe(1);
  expect(fresh.staleMachines).toBe(0);

  const stale = cache.view(KEY, "local", REMOTE_ROWS_TTL_MS + 1);
  expect(stale.rows).toEqual([]);
  expect(stale.staleMachines).toBe(1);
  // Only the ROWS expire. The machine itself stays named with its real
  // status — a refused or unreachable peer's backoff outlasts this row TTL,
  // so dropping the whole entry would render a permanent, human-actionable
  // refusal as transient staleness on every read in between.
  expect(stale.machines).toEqual([
    { machineId: "peer-1", status: "answered", rows: 0, droppedRows: 0, truncatedCard: 0, ageMs: REMOTE_ROWS_TTL_MS + 1 },
  ]);
});

test("a future-dated observedAt does not make a machine's rows immortal", () => {
  const cache = new RemoteDirectoryCache();
  cache.replace(
    [push({ machineId: "peer-1", observedAt: 1_000_000_000_000_000, rows: [wireRow({ sessionId: "a" })] })],
    0,
    "local",
    1_000,
  );

  const view = cache.view(KEY, "local", 1_000);
  expect(view.rows).toEqual([]);
  expect(view.staleMachines).toBe(1);
});

// -- property 2: never discover yourself ----------------------------------

test("a pushed entry naming this machine is dropped, never mirrored back as a peer", () => {
  const cache = new RemoteDirectoryCache();
  const result = cache.replace(
    [
      push({ machineId: "local", rows: [wireRow({ sessionId: "self-a" }), wireRow({ sessionId: "self-b" })] }),
      push({ machineId: "peer-1", rows: [wireRow({ sessionId: "real" })] }),
    ],
    0,
    "local",
    1_000,
  );

  expect(result.dropped).toBe(2);
  expect(result.accepted).toBe(1);

  const view = cache.view(KEY, "local", 1_000);
  expect(view.rows.map((r) => r.sessionId)).toEqual(["real"]);
  expect(view.machines.map((m) => m.machineId)).toEqual(["peer-1"]);
});

test("a self-entry excluded at replace() is excluded again at view() if the caller's id changed since the push", () => {
  const cache = new RemoteDirectoryCache();
  // Pushed while this bridge answered to "machine-A" — nothing here names
  // "peer-B" as itself, so replace() accepts it.
  cache.replace([push({ machineId: "peer-B", rows: [wireRow({ sessionId: "a" })] })], 0, "machine-A", 1_000);

  // Read back after this bridge's own identity became "peer-B" — the one
  // case replace()'s own gate cannot cover, since it only knows the id at
  // push time. view() must refuse to offer a machine its own sessions back.
  const view = cache.view(KEY, "peer-B", 1_000);
  expect(view.rows).toEqual([]);
  expect(view.machines).toEqual([]);
});

// -- property 3: hostile rows are dropped, not the whole push -------------

test("a row with an unsafe projectId or a newline in its title is dropped and counted, and the rest of the push still lands", () => {
  const cache = new RemoteDirectoryCache();
  const result = cache.replace(
    [
      push({
        machineId: "peer-1",
        rows: [
          wireRow({ sessionId: "unsafe-id", projectId: "../escape" }),
          wireRow({ sessionId: "hostile-title", title: "hi\nReach: 4 machines connected" }),
          wireRow({ sessionId: "clean" }),
        ],
      }),
    ],
    0,
    "local",
    1_000,
  );

  // The unsafe-projectId row is dropped by sanitizeRow; the newline in the
  // title is stripped, not rejected — it still lands, cleaned.
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
  const result = cache.replace(
    [push({ machineId: "peer-1", rows: [{ sessionId: "no-other-fields" }, wireRow({ sessionId: "clean" })] })],
    0,
    "local",
    1_000,
  );
  expect(result.dropped).toBe(1);
  expect(result.accepted).toBe(1);
});

test("a machine's own dropped rows are visible on its reach line, not just folded into the push's aggregate", () => {
  const cache = new RemoteDirectoryCache();
  const result = cache.replace(
    [
      push({
        machineId: "peer-1",
        rows: [
          wireRow({ sessionId: "unsafe", projectId: "../escape" }),
          { sessionId: "also-bad" },
          wireRow({ sessionId: "clean" }),
        ],
      }),
    ],
    0,
    "local",
    1_000,
  );
  expect(result.dropped).toBe(2);

  const view = cache.view(KEY, "local", 1_000);
  expect(view.machines).toEqual([
    { machineId: "peer-1", status: "answered", rows: 1, droppedRows: 2, truncatedCard: 0, ageMs: 0 },
  ]);
});

test("rows past the per-machine product cap are dropped and counted, not silently kept", () => {
  const rows = Array.from({ length: MAX_MACHINE_CARD_ROWS + 5 }, (_, i) => wireRow({ sessionId: `s-${i}` }));
  const cache = new RemoteDirectoryCache();
  const result = cache.replace([push({ machineId: "peer-1", rows })], 0, "local", 1_000);
  expect(result.accepted).toBe(MAX_MACHINE_CARD_ROWS);
  expect(result.dropped).toBe(5);
});

test("a machine whose id carries a hostile character is refused, not renamed into another machine's slot", () => {
  const cache = new RemoteDirectoryCache();
  cache.replace(
    [
      push({ machineId: "peer1", rows: [wireRow({ sessionId: "honest" })] }),
      push({ machineId: "peer\n1", rows: [wireRow({ sessionId: "forged" })] }),
    ],
    0,
    "local",
    1_000,
  );

  // Cleaning it would collide with the machine that legitimately holds that id
  // and replace its rows, which is why an address is only ever accepted or
  // refused — the same rule sanitizeRow applies to a session id.
  const view = cache.view(KEY, "local", 1_000);
  expect(view.rows.map((r) => r.sessionId)).toEqual(["honest"]);
  expect(view.machines.map((m) => m.machineId)).toEqual(["peer1"]);
});

// -- property 4: view() filters by repo and stamps from the entry ---------

test("view() filters to rows whose repoKey matches, and stamps machineId/machineLabel from the entry, never from the local machine", () => {
  const cache = new RemoteDirectoryCache();
  cache.replace(
    [
      push({
        machineId: "peer-1",
        machineLabel: "macbook-pro",
        rows: [
          wireRow({ sessionId: "on-key", repoKey: KEY }),
          wireRow({ sessionId: "off-key", repoKey: OTHER_KEY }),
        ],
      }),
    ],
    0,
    "local-self",
    1_000,
  );

  // selfMachineId here is neither the peer's id nor anything in the rows —
  // it exists only to exclude a self-entry, and must never leak into a stamp.
  const view = cache.view(KEY, "local-self", 1_000);
  expect(view.rows.length).toBe(1);
  expect(view.rows[0]!.sessionId).toBe("on-key");
  expect(view.rows[0]!.machineId).toBe("peer-1");
  expect(view.rows[0]!.machineLabel).toBe("macbook-pro");

  const other = cache.view(OTHER_KEY, "local-self", 1_000);
  expect(other.rows.map((r) => r.sessionId)).toEqual(["off-key"]);
});

// -- property 5: wantedRepoKeys / unservedReads visible to the pusher -----

test("a read this cache could not serve is visible to the pusher via wantedRepoKeys and unservedReads", () => {
  const cache = new RemoteDirectoryCache();
  expect(cache.unservedReads()).toBe(0);
  expect(cache.wantedRepoKeys()).toEqual([]);

  // Nothing has ever been pushed, so this read cannot be served.
  const view = cache.view(KEY, "local", 1_000);
  expect(view.rows).toEqual([]);
  expect(view.machines).toEqual([]);
  expect(cache.unservedReads()).toBe(1);
  expect(cache.wantedRepoKeys()).toEqual([KEY]);
  expect(cache.lastReadAt()).toBe(1_000);

  // The push itself drains the counter (see the dedicated drain test below),
  // so the unserved read above no longer counts against what follows it.
  cache.replace([push({ machineId: "peer-1", rows: [] })], 0, "local", 2_000);
  expect(cache.unservedReads()).toBe(0);

  // A repo with a live machine but no matching session is an honest empty
  // answer, not an unserved one.
  cache.view(OTHER_KEY, "local", 3_000);
  expect(cache.unservedReads()).toBe(0);
  expect(cache.wantedRepoKeys()).toEqual([KEY, OTHER_KEY]);
});

test("unservedReads is drained by replace(), not a monotonic latch", () => {
  const cache = new RemoteDirectoryCache();

  // Cold cache: nothing to serve, so the read is unserved.
  cache.view(KEY, "local", 1_000);
  expect(cache.unservedReads()).toBe(1);

  // replace() drains the counter and reports the drained value on its own
  // result — that is what the ack actually carries. A follow-up call to
  // unservedReads() after replace() always reads back 0, which is why
  // host-server.ts must use replace()'s return value, not a second call.
  const first = cache.replace([push({ machineId: "peer-1", rows: [wireRow({ sessionId: "a" })] })], 0, "local", 2_000);
  expect(first.unservedReads).toBe(1);
  expect(cache.unservedReads()).toBe(0);

  // A served read since the last push leaves nothing for the next push to
  // report — the pump must not stay latched onto its fast tick forever.
  cache.view(KEY, "local", 2_000);
  const second = cache.replace([push({ machineId: "peer-1", rows: [wireRow({ sessionId: "a" })] })], 0, "local", 3_000);
  expect(second.unservedReads).toBe(0);
});

test("clear resets the unserved-read counter and the wanted-repo-key list along with the mirror", () => {
  const cache = new RemoteDirectoryCache();
  cache.view(KEY, "local", 1_000);
  expect(cache.unservedReads()).toBe(1);
  expect(cache.wantedRepoKeys()).toEqual([KEY]);

  cache.clear("remote access is off");
  expect(cache.unservedReads()).toBe(0);
  expect(cache.wantedRepoKeys()).toEqual([]);
});

// -- surrounding behaviour ---------------------------------------------------

test("clear empties the mirror and lastPushAt, so a read right after reports no carrier rather than a stale empty push", () => {
  const cache = new RemoteDirectoryCache();
  cache.replace([push({ machineId: "peer-1", rows: [wireRow({ sessionId: "a" })] })], 0, "local", 1_000);
  expect(cache.lastPushAt()).toBe(1_000);

  cache.clear("remote access is off");
  expect(cache.lastPushAt()).toBeNull();
  const view = cache.view(KEY, "local", 1_000);
  expect(view.rows).toEqual([]);
  expect(view.machines).toEqual([]);
});

test("notConnected and lastPushAt pass through from the most recent push", () => {
  const cache = new RemoteDirectoryCache();
  cache.replace([], 3, "local", 500);
  expect(cache.view(KEY, "local", 500).notConnected).toBe(3);
  expect(cache.lastPushAt()).toBe(500);

  cache.replace([], 0, "local", 900);
  expect(cache.view(KEY, "local", 900).notConnected).toBe(0);
  expect(cache.lastPushAt()).toBe(900);
});

test("truncated sums each live machine's own reported cap, and a stale machine's does not count", () => {
  const cache = new RemoteDirectoryCache();
  cache.replace(
    [
      push({ machineId: "peer-1", observedAt: 500, rows: [wireRow({ sessionId: "a" })], truncated: 5 }),
      push({ machineId: "peer-2", observedAt: 1_000, rows: [wireRow({ sessionId: "b" })], truncated: 2 }),
    ],
    0,
    "local",
    1_000,
  );

  // peer-1 (observed at 500) is stale by this clock; peer-2 (observed at
  // 1_000) is not — the genuinely mixed case, since both machines answering
  // stale is not the case the summation can get wrong.
  const now = 500 + REMOTE_ROWS_TTL_MS + 1;
  const mixed = cache.view(KEY, "local", now);
  expect(mixed.staleMachines).toBe(1);
  expect(mixed.truncated).toBe(2);

  const fresh = cache.view(KEY, "local", 1_000);
  expect(fresh.truncated).toBe(7);
});

test("replace is a full replace, not a merge: a machine missing from the next push is gone immediately", () => {
  const cache = new RemoteDirectoryCache();
  cache.replace([push({ machineId: "peer-1", rows: [wireRow({ sessionId: "a" })] })], 0, "local", 1_000);
  expect(cache.view(KEY, "local", 1_000).rows.length).toBe(1);

  cache.replace([], 1, "local", 1_100);
  const view = cache.view(KEY, "local", 1_100);
  expect(view.rows).toEqual([]);
  expect(view.notConnected).toBe(1);
});

test("a machine reporting refused or unreachable still carries its status, and its stale rows expire without erasing it", () => {
  const cache = new RemoteDirectoryCache();
  cache.replace(
    [
      push({ machineId: "peer-1", outcome: "refused", observedAt: 1_000, rows: [] }),
      push({ machineId: "peer-2", outcome: "unreachable", observedAt: 1_000, rows: [wireRow({ sessionId: "stale-row" })] }),
    ],
    0,
    "local",
    1_000,
  );

  const fresh = cache.view(KEY, "local", 1_000);
  expect(fresh.machines).toEqual([
    { machineId: "peer-1", status: "refused", rows: 0, droppedRows: 0, truncatedCard: 0, ageMs: 0 },
    { machineId: "peer-2", status: "unreachable", rows: 1, droppedRows: 0, truncatedCard: 0, ageMs: 0 },
  ]);

  // A refusal is a fact about a switch, not data that rots in 45 seconds — a
  // peer's backoff (minutes) outlasts this row TTL, so both machines must
  // still be NAMED here, just with their rows expired.
  const aged = cache.view(KEY, "local", 1_000 + REMOTE_ROWS_TTL_MS + 1);
  expect(aged.staleMachines).toBe(2);
  expect(aged.machines).toEqual([
    { machineId: "peer-1", status: "refused", rows: 0, droppedRows: 0, truncatedCard: 0, ageMs: REMOTE_ROWS_TTL_MS + 1 },
    { machineId: "peer-2", status: "unreachable", rows: 0, droppedRows: 0, truncatedCard: 0, ageMs: REMOTE_ROWS_TTL_MS + 1 },
  ]);
});

// -- the wire schema tolerates what replace() is the real gate for --------

test("a malformed or oversized row does not fail the whole request at the wire layer", () => {
  const req = {
    id: "push-1",
    type: "session-bus:remote-directory",
    machines: [
      {
        machineId: "peer-1",
        observedAt: 1_000,
        outcome: "rows",
        rows: [wireRow({ sessionId: "clean" }), { sessionId: "x".repeat(500) }],
        truncated: 0,
      },
    ],
    notConnected: 0,
  };
  // RemoteDirectoryRowSchema (the real per-row gate) would reject the second
  // row on sight — a 201-char sessionId is over its cap — but the WIRE schema
  // must not, or one hostile/oversized row anywhere in the account 400s the
  // whole push and the app latches its pump off.
  expect(ControlRequestSchema.safeParse(req).success).toBe(true);
});

test("a push naming more machines than the product cap still parses at the wire layer, and replace() bounds it", () => {
  const many = Array.from({ length: MAX_REMOTE_DIRECTORY_MACHINES + 1 }, (_, i) =>
    push({ machineId: `peer-${i}`, rows: [wireRow({ sessionId: `s-${i}` })] }),
  );
  const req = { id: "push-1", type: "session-bus:remote-directory", machines: many, notConnected: 0 };
  expect(ControlRequestSchema.safeParse(req).success).toBe(true);

  const cache = new RemoteDirectoryCache();
  const result = cache.replace(many, 0, "local", 1_000);
  expect(result.dropped).toBe(1);
  const view = cache.view(KEY, "local", 1_000);
  expect(view.machines.length).toBe(MAX_REMOTE_DIRECTORY_MACHINES);
});

// -- the loopback ingest verb + host wiring ---------------------------------

function fakeRemoteConfig(): HostRemoteConfig {
  return {
    relayUrl: "ws://127.0.0.1:1",
    licenseApiUrl: "http://127.0.0.1:1",
    identity: { deviceId: "dev-1", deviceName: "dev-1", createdAt: "2026-01-01T00:00:00.000Z" },
    auth: { clientId: "cid", clientSecret: "secret", deviceUuid: "uuid-1" },
    onAuthRevoked: () => {},
  };
}

function fakeRuntime(): RemoteRuntime {
  return { maint: { getToken: () => "tok", stop: () => {} } };
}

let host: HostServer | null = null;
let prevAbDir: string | undefined;
let abDir: string;

async function setMobileAccess(h: HostServer, enabled: boolean): Promise<void> {
  await h.handleRemoteAccessVerb({ id: "t", type: "mobile-access:set", enabled });
}

// Gives the machine a relay identity with no relay socket — `handleControl`
// only ever reads `controlPlaneRegistrationId`'s `.deviceId`, and shutdown()
// closes it; opening a real remote control plane needs a live relay this
// suite has none of.
function giveMachineIdentity(h: HostServer, machineId: string): void {
  (h as any).controlPlaneRelay = { deviceId: machineId, close: () => {} };
}

function pushRequest(machines: RemoteDirectoryMachinePush[], notConnected = 0) {
  return { id: "push-1", type: "session-bus:remote-directory", machines, notConnected } as const;
}

// The shared `push()` helper's `observedAt` defaults to a fixed 1_000, which
// reads as stale against a live `Date.now()` clock. These tests read the
// mirror back through the real host on the real clock, so they need a fresh
// timestamp on every push.
function livePush(over: Partial<RemoteDirectoryMachinePush> & { machineId: string }): RemoteDirectoryMachinePush {
  return push({ observedAt: Date.now(), ...over });
}

function ask(h: HostServer, req: unknown): Promise<any> {
  return (h as any).handleControl(req);
}

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-remote-directory-"));
  process.env.ANTGRID_DIR = abDir;
  host = new HostServer({ remote: fakeRemoteConfig(), remoteRuntimeFactory: () => Promise.resolve(fakeRuntime()) });
});

afterEach(async () => {
  await host?.shutdown();
  host = null;
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR; else process.env.ANTGRID_DIR = prevAbDir;
  rmSync(abDir, { recursive: true, force: true });
});

test("gate 1: ingest is refused and the mirror cleared when remote access is off", async () => {
  const h = host!;
  giveMachineIdentity(h, "self-machine");
  await setMobileAccess(h, true);
  await ask(h, pushRequest([push({ machineId: "peer-1", rows: [wireRow({ sessionId: "a" })] })]));
  expect((h as any).remoteDirectory.lastPushAt()).not.toBeNull();

  await setMobileAccess(h, false);
  const res = await ask(h, pushRequest([push({ machineId: "peer-1", rows: [wireRow({ sessionId: "b" })] })]));

  expect(res.ok).toBe(false);
  expect(res.error.code).toBe("NOT_ALLOWED");
  expect((h as any).remoteDirectory.lastPushAt()).toBeNull();
});

test("gate 1: turning remote access off clears the mirror immediately, with no push required", async () => {
  const h = host!;
  giveMachineIdentity(h, "self-machine");
  await setMobileAccess(h, true);
  await ask(h, pushRequest([push({ machineId: "peer-1", rows: [wireRow({ sessionId: "a" })] })]));
  expect((h as any).remoteDirectory.lastPushAt()).not.toBeNull();

  await setMobileAccess(h, false);

  expect((h as any).remoteDirectory.lastPushAt()).toBeNull();
});

test("gate 2: ingest is refused when this machine has no relay identity", async () => {
  const h = host!;
  await setMobileAccess(h, true);
  // No giveMachineIdentity() call: controlPlaneRegistrationId stays null, the
  // state of a fresh host that has not opened a remote project yet.
  expect(h.controlPlaneRegistrationId).toBeNull();

  const res = await ask(h, pushRequest([push({ machineId: "peer-1", rows: [wireRow({ sessionId: "a" })] })]));

  expect(res.ok).toBe(false);
  expect(res.error.code).toBe("NOT_ADDRESSABLE");
  expect((h as any).remoteDirectory.lastPushAt()).toBeNull();
});

test("gate 3: a push is sanitised and counted, reporting accepted/dropped rather than failing the whole push", async () => {
  const h = host!;
  giveMachineIdentity(h, "self-machine");
  await setMobileAccess(h, true);

  const res = await ask(
    h,
    pushRequest(
      [
        // Dropped whole: this push names the answering machine itself.
        livePush({ machineId: "self-machine", rows: [wireRow({ sessionId: "self-a" })] }),
        livePush({
          machineId: "peer-1",
          rows: [
            // Dropped: unsafe projectId fails sanitizeRow outright.
            wireRow({ sessionId: "unsafe", projectId: "../escape" }),
            // Kept, cleaned: a newline is stripped rather than rejecting the row.
            wireRow({ sessionId: "hostile", title: "hi\nfake reach line" }),
            wireRow({ sessionId: "clean" }),
          ],
        }),
      ],
      2,
    ),
  );

  expect(res.ok).toBe(true);
  expect(res.type).toBe("session-bus:remote-directory");
  expect(res.accepted).toBe(2);
  expect(res.dropped).toBe(2);
  // No view() has run anywhere in this test yet, so these are not "some type
  // the field is declared as" but the actual cold-cache values.
  expect(res.lastReadAt).toBeNull();
  expect(res.wantedRepoKeys).toEqual([]);
  expect(res.unservedReads).toBe(0);

  const view = (h as any).remoteDirectory.view(KEY, "self-machine", Date.now());
  expect(view.rows.map((r: any) => r.sessionId).sort()).toEqual(["clean", "hostile"]);
  expect(view.notConnected).toBe(2);
  const peer1 = view.machines.find((m: any) => m.machineId === "peer-1");
  expect(peer1.droppedRows).toBe(1);
});

test("a full-size push fits the loopback body cap it has to travel through", () => {
  // The two bounds are set in different files and neither reads the other, so
  // raising a row cap or a field length silently makes the largest HONEST push
  // 400 at the socket — the code the pump reads as "this bridge is too old"
  // and latches off on. Held to three quarters of the cap rather than to the
  // cap itself, so this fails while the drift is still theoretical instead of
  // on the first push that happens to be maximal.
  const wide = (n: number) => "w".repeat(n);
  const fat: RemoteDirectoryRow = {
    repoKey: wide(512),
    projectId: wide(200),
    projectLabel: wide(120),
    sessionId: wide(200),
    title: wide(200),
    branch: wide(200),
    activity: "running",
    workStatus: "working",
    lastActiveAt: 9_999_999_999_999,
    canReply: true,
  };
  const body = JSON.stringify({
    id: wide(64),
    type: "session-bus:remote-directory",
    machines: Array.from({ length: MAX_REMOTE_DIRECTORY_MACHINES }, (_, i) => ({
      machineId: `${wide(199)}${i}`,
      machineLabel: wide(120),
      observedAt: 9_999_999_999_999,
      outcome: "rows",
      rows: Array.from({ length: MAX_MACHINE_CARD_ROWS }, () => fat),
      truncated: 9_999,
    })),
    notConnected: 99,
  });

  expect(Buffer.byteLength(body, "utf8")).toBeLessThan(MAX_CONTROL_BODY_BYTES * 0.75);
});
