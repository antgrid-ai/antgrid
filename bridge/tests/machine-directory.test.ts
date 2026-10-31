import { describe, it, expect } from "bun:test";
import { MachineDirectory, MACHINE_DIRECTORY_KICK_MIN_MS, MACHINE_DIRECTORY_STALE_MS } from "../src/session-bus/machine-directory";

const SELF = "11111111-1111-4111-8111-111111111111";
const PEER = "22222222-2222-4222-8222-222222222222";
const KEY_A = Buffer.alloc(32, 7).toString("base64");
const KEY_B = Buffer.alloc(32, 9).toString("base64");

function body(over: Record<string, unknown> = {}, peerKey: string | null = KEY_B) {
  return {
    accountId: "acct",
    deviceId: SELF,
    allowed: true,
    self: { busPublicKey: KEY_A, orchestrator: false, busControl: false },
    machines: [{ deviceId: PEER, displayName: "peer", machineName: null, ed25519Pub: KEY_A, busPublicKey: peerKey, orchestrator: true, busControl: false }],
    ...over,
  };
}

function rig(payload: () => unknown = () => body()) {
  let t = 1_000_000;
  const fetches: { url: string; auth: string }[] = [];
  const timers: { fn: () => void; ms: number; live: boolean }[] = [];
  const dir = new MachineDirectory({
    licenseApiUrl: "https://api.example.com",
    getToken: () => "tok",
    selfDeviceId: SELF,
    now: () => t,
    random: () => 0.5,
    schedule: (fn, ms) => {
      const e = { fn, ms, live: true };
      timers.push(e);
      return () => {
        e.live = false;
      };
    },
    fetchFn: (async (u: string, i?: RequestInit) => {
      fetches.push({ url: u, auth: (i?.headers as Record<string, string>).authorization });
      return new Response(JSON.stringify(payload()), { status: 200 });
    }) as unknown as typeof fetch,
  });
  return {
    dir,
    fetches,
    timers,
    advance: (ms: number) => {
      t += ms;
    },
  };
}

const tick = () => new Promise((res) => setTimeout(res, 0));

describe("MachineDirectory", () => {
  it("fetches on start, serves the view and reschedules at the refresh cadence", async () => {
    const r = rig();
    r.dir.start();
    await tick();
    expect(r.fetches).toEqual([{ url: "https://api.example.com/account/devices/me/machines", auth: "Bearer tok" }]);
    expect(r.dir.busKeyFor(PEER)).toBe(KEY_B);
    expect(r.dir.machine(PEER)?.orchestrator).toBe(true);
    expect(r.dir.selfBusKey()).toBe(KEY_A);
    expect(r.dir.selfOrchestrator()).toBe(false);
    expect(r.dir.selfBusControl()).toBe(false);
    const next = r.timers.filter((x) => x.live);
    expect(next.length).toBe(1);
    expect(next[0].ms).toBe(20_000);
    next[0].fn();
    await tick();
    expect(r.fetches.length).toBe(2);
    r.dir.stop();
  });

  it("serves selfBusControl and selfOrchestrator from the view", async () => {
    const r = rig(() => body({ self: { busPublicKey: null, orchestrator: true, busControl: true } }));
    await r.dir.refresh();
    expect(r.dir.selfOrchestrator()).toBe(true);
    expect(r.dir.selfBusControl()).toBe(true);
    expect(r.dir.selfBusKey()).toBeNull();
  });

  it("gives no key for an entry without one", async () => {
    const r = rig(() => body({}, null));
    await r.dir.refresh();
    expect(r.dir.busKeyFor(PEER)).toBeNull();
    expect(r.dir.busKeyFor("33333333-3333-4333-8333-333333333333")).toBeNull();
  });

  it("gives no key when the account does not allow this machine", async () => {
    const r = rig(() => body({ allowed: false }));
    await r.dir.refresh();
    expect(r.dir.busKeyFor(PEER)).toBeNull();
  });

  it("expires a stale view", async () => {
    const r = rig();
    await r.dir.refresh();
    r.advance(MACHINE_DIRECTORY_STALE_MS + 1);
    expect(r.dir.current()).toBeNull();
    expect(r.dir.busKeyFor(PEER)).toBeNull();
  });

  it("rejects a directory addressed to another device", async () => {
    const r = rig(() => body({ deviceId: PEER }));
    expect(await r.dir.refresh()).toBe(false);
    expect(r.dir.current()).toBeNull();
  });

  it("backs off after a failure", async () => {
    const r = rig(() => ({ nope: true }));
    r.dir.start();
    await tick();
    const live = r.timers.filter((x) => x.live);
    expect(live.length).toBe(1);
    expect(live[0].ms).toBe(2_000);
    r.dir.stop();
  });

  it("coalesces ten kicks in the window into one deferred fetch", async () => {
    const r = rig();
    await r.dir.refresh();
    expect(r.fetches.length).toBe(1);
    r.advance(1_000);
    for (let i = 0; i < 10; i++) r.dir.kick();
    expect(r.fetches.length).toBe(1);
    const pending = r.timers.filter((x) => x.live);
    expect(pending.length).toBe(1);
    expect(pending[0].ms).toBe(MACHINE_DIRECTORY_KICK_MIN_MS - 1_000);
    r.advance(pending[0].ms);
    pending[0].fn();
    await tick();
    expect(r.fetches.length).toBe(2);
  });

  it("refreshes immediately on a kick outside the window", async () => {
    const r = rig();
    await r.dir.refresh();
    r.advance(MACHINE_DIRECTORY_KICK_MIN_MS);
    r.dir.kick();
    await tick();
    expect(r.fetches.length).toBe(2);
  });

  it("ensureFresh reuses a recent view and single-flights a refetch", async () => {
    const r = rig();
    await r.dir.refresh();
    expect(await r.dir.ensureFresh(5_000)).toBe(true);
    expect(r.fetches.length).toBe(1);
    r.advance(6_000);
    await Promise.all([r.dir.ensureFresh(5_000), r.dir.ensureFresh(5_000)]);
    expect(r.fetches.length).toBe(2);
  });

  it("notifies listeners on a good refresh", async () => {
    const r = rig();
    let n = 0;
    r.dir.onChange(() => n++);
    await r.dir.refresh();
    expect(n).toBe(1);
  });
});
