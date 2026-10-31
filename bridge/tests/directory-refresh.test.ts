import { expect, test } from "bun:test";
import type { MachineEntry } from "antgrid-wire";
import type { BusRequestResult } from "../src/session-bus/bus-requests";
import { MAX_REMOTE_DIRECTORY_MACHINES, REMOTE_DIRECTORY_REFRESH_MS } from "../src/session-bus/constants";
import { DirectoryRefresher, outcomeFor } from "../src/session-bus/directory-refresh";
import { RemoteDirectoryCache, type RemoteDirectoryReport } from "../src/session-bus/remote-directory";

const SELF = "00000000-0000-4000-8000-000000000000";
const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;

function machine(n: number, over: Partial<MachineEntry> = {}): MachineEntry {
  return {
    deviceId: id(n), displayName: `display-${n}`, machineName: `name-${n}`,
    ed25519Pub: "k", busPublicKey: "b", orchestrator: false, busControl: false, ...over,
  };
}

function rig(opts: {
  machines: MachineEntry[];
  online?: string[];
  remoteAccess?: () => boolean;
  answer?: (to: string) => BusRequestResult;
  wanted?: () => string[];
}) {
  let t = 10_000;
  const asks: { to: string; method: string; params: any; timeoutMs: number }[] = [];
  const reports: RemoteDirectoryReport[] = [];
  const synced: { askable: string[]; notConnected: number }[] = [];
  const timers: { at: number; fn: () => void; live: boolean }[] = [];
  let remoteAccess = true;
  const refresher = new DirectoryRefresher({
    directory: { current: () => ({ deviceId: SELF, allowed: true, machines: opts.machines }) as never },
    requests: {
      request: async (i) => {
        asks.push(i as never);
        return (opts.answer ?? (() => ({ ok: true, result: { sessions: [] } })))(i.to);
      },
    },
    cache: {
      ingest: (r) => { reports.push(r); return { accepted: r.rows.length, dropped: 0 }; },
      syncAccount: (askable, notConnected) => { synced.push({ askable: [...askable], notConnected }); },
      wantedRepoKeys: opts.wanted ?? (() => ["github.com/o/r"]),
    },
    online: () => new Set(opts.online ?? []),
    remoteAccessEnabled: opts.remoteAccess ?? (() => remoteAccess),
    now: () => t,
    schedule: (fn, ms) => {
      const e = { at: t + ms, fn, live: true };
      timers.push(e);
      return () => { e.live = false; };
    },
  });
  return {
    refresher, asks, reports, synced, timers,
    advance: (ms: number) => { t += ms; },
    setRemoteAccess: (v: boolean) => { remoteAccess = v; },
  };
}

test("asks every machine with a key, never itself and never one without a key, and counts the unaskable", async () => {
  const r = rig({ machines: [machine(1), machine(2, { busPublicKey: null }), machine(3), { ...machine(4), deviceId: SELF }] });
  await r.refresher.kick();
  expect(r.asks.map((a) => a.to).sort()).toEqual([id(1), id(3)]);
  expect(r.synced.at(-1)).toEqual({ askable: [id(1), id(3)].sort(), notConnected: 1 });
});

test("each ask names the method, the wanted repo keys and the session half, with a 20 second deadline", async () => {
  const r = rig({ machines: [machine(1)] });
  await r.refresher.kick();
  expect(r.asks[0]).toEqual({
    to: id(1),
    method: "machine.capability-card",
    params: { includeSessions: true, repoKeys: ["github.com/o/r"] },
    timeoutMs: 20_000,
  });
});

test("with no repository wanted yet nothing is asked, though the account is still synced", async () => {
  const r = rig({ machines: [machine(1)], wanted: () => [] });
  await r.refresher.kick();
  expect(r.asks).toEqual([]);
  expect(r.reports).toEqual([]);
  expect(r.synced.at(-1)).toEqual({ askable: [id(1)], notConnected: 0 });
});

test("the report names the repo keys its ask carried, so the mirror knows what the card speaks for", async () => {
  const r = rig({ machines: [machine(1)] });
  await r.refresher.kick();
  expect(r.reports[0]!.repoKeys).toEqual(["github.com/o/r"]);
});

test("a read the mirror could not serve kicks an ask that names that read's repository", async () => {
  const REPO = "github.com/o/r";
  const LATER = "github.com/o/later";
  const cache = new RemoteDirectoryCache();
  const asks: { params: any }[] = [];
  const refresher = new DirectoryRefresher({
    directory: { current: () => ({ deviceId: SELF, allowed: true, machines: [machine(1)] }) as never },
    requests: {
      request: async (i) => {
        asks.push(i as never);
        return { ok: true, result: { sessions: [] } };
      },
    },
    cache,
    online: () => new Set(),
    remoteAccessEnabled: () => true,
    now: () => 10_000,
  });
  cache.setUnservedListener(() => void refresher.kick());

  expect(cache.view(REPO, SELF, 10_000).served).toBe(false);
  await new Promise((res) => setTimeout(res, 0));
  expect(asks.map((a) => a.params.repoKeys)).toEqual([[REPO]]);
  expect(cache.view(REPO, SELF, 10_000).served).toBe(true);

  // Answered about REPO only: an empty card is no answer about LATER, so that
  // read is unserved, says so, and asks again naming it.
  const later = cache.view(LATER, SELF, 10_000);
  expect(later.served).toBe(false);
  expect(later.machines).toEqual([expect.objectContaining({ machineId: id(1), status: "not-asked", rows: 0 })]);
});

test("selection puts online machines first, then the least recently refreshed, up to the product bound", async () => {
  const machines = Array.from({ length: MAX_REMOTE_DIRECTORY_MACHINES + 3 }, (_, i) => machine(i + 1));
  const r = rig({ machines, online: [id(11), id(10)] });

  await r.refresher.kick();
  expect(r.asks).toHaveLength(MAX_REMOTE_DIRECTORY_MACHINES);
  expect(new Set(r.asks.slice(0, 2).map((a) => a.to))).toEqual(new Set([id(10), id(11)]));
  const first = new Set(r.asks.map((a) => a.to));

  // The three left out are the least recently refreshed, so they go next.
  r.asks.length = 0;
  r.advance(10_000);
  await r.refresher.kick();
  const second = r.asks.map((a) => a.to);
  for (const left of machines.map((m) => m.deviceId).filter((m) => !first.has(m))) expect(second).toContain(left);
});

test("the outcome table", () => {
  const rows = [{ sessionId: "a" }];
  expect(outcomeFor({ ok: true, result: { sessions: rows, sessionsTruncated: 4 } })).toEqual({ outcome: "rows", rows, truncated: 4 });
  expect(outcomeFor({ ok: true, result: { sessions: [] } })).toEqual({ outcome: "rows", rows: [], truncated: 0 });
  expect(outcomeFor({ ok: true, result: { projects: {} } }).outcome).toBe("no-card");
  expect(outcomeFor({ ok: true, result: null }).outcome).toBe("no-card");
  const code = (c: string) => outcomeFor({ ok: false, code: c }).outcome;
  expect(code("NOT_ALLOWED_AGENT_REACH")).toBe("reach-refused");
  expect(code("NOT_ALLOWED")).toBe("refused");
  expect(code("REMOTE_ACCESS_OFF")).toBe("refused");
  expect(code("E_UNKNOWN_METHOD")).toBe("no-card");
  expect(code("E_BAD_PARAMS")).toBe("no-card");
  expect(code("METHOD_NOT_ALLOWED")).toBe("no-card");
  expect(code("REQUEST_TIMEOUT")).toBe("unreachable");
  expect(code("REQUEST_RATE")).toBe("unreachable");
  expect(code("SOMETHING_NEW")).toBe("unreachable");
});

test("machineLabel and truncated reach ingest, and the label falls back to the display name", async () => {
  const r = rig({
    machines: [machine(1), machine(2, { machineName: null })],
    answer: () => ({ ok: true, result: { sessions: [], sessionsTruncated: 3 } }),
  });
  await r.refresher.kick();
  const byId = new Map(r.reports.map((x) => [x.machineId, x]));
  expect(byId.get(id(1))).toMatchObject({ machineLabel: "name-1", outcome: "rows", truncated: 3 });
  expect(byId.get(id(2))).toMatchObject({ machineLabel: "display-2" });
});

test("a refused machine is ingested as refused, not as empty", async () => {
  const r = rig({ machines: [machine(1)], answer: () => ({ ok: false, code: "NOT_ALLOWED_AGENT_REACH" }) });
  await r.refresher.kick();
  expect(r.reports[0]).toMatchObject({ machineId: id(1), outcome: "reach-refused", rows: [] });
});

test("with remote access off nothing is sent, on a tick or a kick", async () => {
  const r = rig({ machines: [machine(1)] });
  r.setRemoteAccess(false);
  r.refresher.start();
  await r.refresher.kick();
  await r.refresher.kick(id(1));
  expect(r.asks).toEqual([]);
  expect(r.reports).toEqual([]);
  r.refresher.stop();
});

test("a kick is throttled per machine, and a different machine is not held back by it", async () => {
  const r = rig({ machines: [machine(1), machine(2)] });
  await r.refresher.kick(id(1));
  await r.refresher.kick(id(1));
  expect(r.asks).toHaveLength(1);

  await r.refresher.kick(id(2));
  expect(r.asks).toHaveLength(2);

  r.advance(5_000);
  await r.refresher.kick(id(1));
  expect(r.asks).toHaveLength(3);
});

test("the interval tick asks every machine again and reschedules itself", async () => {
  const r = rig({ machines: [machine(1)] });
  r.refresher.start();
  await new Promise((res) => setTimeout(res, 10));
  expect(r.asks).toHaveLength(1);
  const next = r.timers.filter((t) => t.live);
  expect(next).toHaveLength(1);
  expect(next[0]!.at - 10_000).toBe(REMOTE_DIRECTORY_REFRESH_MS);

  r.advance(REMOTE_DIRECTORY_REFRESH_MS);
  next[0]!.fn();
  await new Promise((res) => setTimeout(res, 10));
  expect(r.asks).toHaveLength(2);
  r.refresher.stop();
});

test("a request that is abandoned records nothing and does not break the loop", async () => {
  const r = rig({ machines: [machine(1)] });
  (r.refresher as any).deps.requests.request = async () => { throw new Error("bus requests stopped"); };
  await r.refresher.kick();
  expect(r.reports).toEqual([]);
});
