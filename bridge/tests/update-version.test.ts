import { describe, it, expect } from "bun:test";
import {
  parseAgentVersion,
  coreLt,
  shouldNotify,
  fetchNpmLatest,
  resolveLatest,
  checkAgentUpdate,
  createUpdateChecker,
  runAgentUpdate,
} from "../src/update/version";

describe("parseAgentVersion", () => {
  it("extracts the semver core from `codex --version` output", () => {
    expect(parseAgentVersion("codex-cli 0.142.2\n")).toBe("0.142.2");
    expect(parseAgentVersion("codex-cli 0.144.3")).toBe("0.144.3");
  });
  it("keeps a prerelease suffix when present", () => {
    expect(parseAgentVersion("codex-cli 0.145.0-alpha.4")).toBe("0.145.0-alpha.4");
  });
  it("returns null when no version is present", () => {
    expect(parseAgentVersion("codex: command not found")).toBeNull();
    expect(parseAgentVersion("")).toBeNull();
  });
});

describe("coreLt", () => {
  it("orders by numeric core, not lexically", () => {
    expect(coreLt("0.142.2", "0.144.3")).toBe(true);
    expect(coreLt("0.144.3", "0.142.2")).toBe(false);
    expect(coreLt("0.142.2", "0.142.10")).toBe(true); // 10 > 2 numerically
  });
  it("treats equal cores as not-less-than", () => {
    expect(coreLt("0.144.3", "0.144.3")).toBe(false);
  });
  it("ignores prerelease suffixes (compares cores only)", () => {
    expect(coreLt("0.145.0-alpha.4", "0.145.0")).toBe(false); // same core
    expect(coreLt("0.144.3", "0.145.0-alpha.4")).toBe(true); // 0.145.0 core wins
  });
});

describe("shouldNotify", () => {
  it("notifies when installed is behind latest and nothing dismissed", () => {
    expect(shouldNotify("0.142.2", "0.144.3", null)).toBe(true);
  });
  it("does not notify when already current", () => {
    expect(shouldNotify("0.144.3", "0.144.3", null)).toBe(false);
  });
  it("suppresses when the exact latest was dismissed", () => {
    expect(shouldNotify("0.142.2", "0.144.3", "0.144.3")).toBe(false);
  });
  it("re-surfaces when a newer release supersedes the dismissed one", () => {
    expect(shouldNotify("0.142.2", "0.144.3", "0.143.0")).toBe(true);
  });
  it("does not notify when latest is unknown", () => {
    expect(shouldNotify("0.142.2", null, null)).toBe(false);
  });
});

describe("fetchNpmLatest", () => {
  const ok = (body: unknown) =>
    (async () => new Response(JSON.stringify(body), { status: 200 })) as unknown as typeof fetch;

  it("returns the dist-tags.latest version on success", async () => {
    expect(await fetchNpmLatest("@openai/codex", ok({ version: "0.144.3" }))).toBe("0.144.3");
  });
  it("returns null on a non-ok response", async () => {
    const notFound = (async () => new Response("nope", { status: 404 })) as unknown as typeof fetch;
    expect(await fetchNpmLatest("@openai/codex", notFound)).toBeNull();
  });
  it("returns null when the request throws (offline)", async () => {
    const boom = (async () => { throw new Error("ENOTFOUND"); }) as unknown as typeof fetch;
    expect(await fetchNpmLatest("@openai/codex", boom)).toBeNull();
  });
  it("returns null on malformed json", async () => {
    const bad = (async () => new Response("<html>", { status: 200 })) as unknown as typeof fetch;
    expect(await fetchNpmLatest("@openai/codex", bad)).toBeNull();
  });
});

describe("resolveLatest (TTL cache, fail-soft)", () => {
  const mkCache = (init: { version: string; at: number } | null) => {
    let cell = init;
    return {
      read: () => cell,
      write: (e: { version: string; at: number }) => { cell = e; },
      current: () => cell,
    };
  };

  it("uses a fresh cache without calling fetch", async () => {
    const cache = mkCache({ version: "0.144.3", at: 1000 });
    let calls = 0;
    const v = await resolveLatest({
      fetchLatest: async () => { calls++; return "9.9.9"; },
      readCache: cache.read, writeCache: cache.write,
      now: () => 1000 + 60_000, ttlMs: 3_600_000,
    });
    expect(v).toBe("0.144.3");
    expect(calls).toBe(0);
  });

  it("fetches and writes cache when cache is stale", async () => {
    const cache = mkCache({ version: "0.140.0", at: 0 });
    const v = await resolveLatest({
      fetchLatest: async () => "0.144.3",
      readCache: cache.read, writeCache: cache.write,
      now: () => 10_000_000, ttlMs: 3_600_000,
    });
    expect(v).toBe("0.144.3");
    expect(cache.current()).toEqual({ version: "0.144.3", at: 10_000_000 });
  });

  it("fetches when cache is absent", async () => {
    const cache = mkCache(null);
    const v = await resolveLatest({
      fetchLatest: async () => "0.144.3",
      readCache: cache.read, writeCache: cache.write,
      now: () => 5, ttlMs: 3_600_000,
    });
    expect(v).toBe("0.144.3");
  });

  it("falls back to a stale cached value when the fetch fails", async () => {
    const cache = mkCache({ version: "0.144.2", at: 0 });
    const v = await resolveLatest({
      fetchLatest: async () => null, // offline
      readCache: cache.read, writeCache: cache.write,
      now: () => 10_000_000, ttlMs: 3_600_000,
    });
    expect(v).toBe("0.144.2");
  });

  it("returns null when there is neither a cache nor a successful fetch", async () => {
    const cache = mkCache(null);
    const v = await resolveLatest({
      fetchLatest: async () => null,
      readCache: cache.read, writeCache: cache.write,
      now: () => 5, ttlMs: 3_600_000,
    });
    expect(v).toBeNull();
  });
});

describe("checkAgentUpdate (orchestration)", () => {
  it("returns an update payload when the spawned binary is behind", async () => {
    const out = await checkAgentUpdate({
      execVersion: async () => "codex-cli 0.142.2\n",
      resolveLatest: async () => "0.144.3",
      dismissed: null,
    });
    expect(out).toEqual({ installed: "0.142.2", latest: "0.144.3" });
  });

  it("returns null when current", async () => {
    const out = await checkAgentUpdate({
      execVersion: async () => "codex-cli 0.144.3",
      resolveLatest: async () => "0.144.3",
      dismissed: null,
    });
    expect(out).toBeNull();
  });

  it("returns null (never throws) when the version probe fails", async () => {
    const out = await checkAgentUpdate({
      execVersion: async () => { throw new Error("spawn failed"); },
      resolveLatest: async () => "0.144.3",
      dismissed: null,
    });
    expect(out).toBeNull();
  });

  it("returns null when the installed version is unparseable", async () => {
    const out = await checkAgentUpdate({
      execVersion: async () => "garbage",
      resolveLatest: async () => "0.144.3",
      dismissed: null,
    });
    expect(out).toBeNull();
  });

  it("suppresses a dismissed version", async () => {
    const out = await checkAgentUpdate({
      execVersion: async () => "codex-cli 0.142.2",
      resolveLatest: async () => "0.144.3",
      dismissed: "0.144.3",
    });
    expect(out).toBeNull();
  });
});

describe("createUpdateChecker (shared cache, single-flight, warm hint)", () => {
  it("reads dismissed_version from codex's own version.json state", async () => {
    const check = createUpdateChecker({
      execVersion: async () => "codex-cli 0.142.2",
      readState: () => ({ latest_version: "0.144.3", dismissed_version: "0.144.3" }),
      fetchLatest: async () => "0.144.3",
      now: () => 0, ttlMs: 3_600_000,
    });
    expect(await check()).toBeNull(); // dismissed
  });

  it("collapses concurrent checks into a single network fetch", async () => {
    let fetches = 0;
    const check = createUpdateChecker({
      execVersion: async () => "codex-cli 0.142.2",
      readState: () => null,
      fetchLatest: async () => { fetches++; await Promise.resolve(); return "0.144.3"; },
      now: () => 1000, ttlMs: 3_600_000,
    });
    const [a, b] = await Promise.all([check(), check()]);
    expect(a).toEqual({ installed: "0.142.2", latest: "0.144.3" });
    expect(b).toEqual({ installed: "0.142.2", latest: "0.144.3" });
    expect(fetches).toBe(1); // shared inflight + then warm cache
  });

  it("reuses the cached latest within the TTL (no second fetch)", async () => {
    let fetches = 0;
    let clock = 1000;
    const check = createUpdateChecker({
      execVersion: async () => "codex-cli 0.142.2",
      readState: () => null,
      fetchLatest: async () => { fetches++; return "0.144.3"; },
      now: () => clock, ttlMs: 3_600_000,
    });
    await check();
    clock += 60_000; // still within TTL
    await check();
    expect(fetches).toBe(1);
  });

  it("still surfaces offline by falling back to the version.json warm hint", async () => {
    const check = createUpdateChecker({
      execVersion: async () => "codex-cli 0.142.2",
      readState: () => ({ latest_version: "0.144.2", dismissed_version: null }),
      fetchLatest: async () => null, // offline
      now: () => 0, ttlMs: 3_600_000,
    });
    expect(await check()).toEqual({ installed: "0.142.2", latest: "0.144.2" });
  });
});

describe("runAgentUpdate", () => {
  // Records the order of lifecycle calls so we can assert the invariant that
  // every codex session is fully stopped BEFORE the binary-replacing update runs,
  // and restarted AFTER it settles.
  function tracer() {
    const events: string[] = [];
    return {
      events,
      stop: (id: string) => { events.push(`stop:${id}`); return Promise.resolve(); },
      start: (id: string) => { events.push(`start:${id}`); },
    };
  }

  it("quiesces all sessions, runs update once, then restarts them (happy path)", async () => {
    const t = tracer();
    const out = await runAgentUpdate({
      sessionIds: ["a", "b"],
      stop: t.stop,
      start: t.start,
      execUpdate: async () => { t.events.push("update"); return { exitCode: 0, output: "updated" }; },
      installedAfter: async () => "0.144.3",
    });
    expect(out).toEqual({ ok: true, exitCode: 0, output: "updated", installed: "0.144.3" });
    // Both stops precede the update; both restarts follow it.
    expect(t.events.indexOf("update")).toBeGreaterThan(t.events.indexOf("stop:a"));
    expect(t.events.indexOf("update")).toBeGreaterThan(t.events.indexOf("stop:b"));
    expect(t.events.indexOf("start:a")).toBeGreaterThan(t.events.indexOf("update"));
    expect(t.events.indexOf("start:b")).toBeGreaterThan(t.events.indexOf("update"));
  });

  it("restarts the stopped sessions even when the update fails", async () => {
    const t = tracer();
    const out = await runAgentUpdate({
      sessionIds: ["a"],
      stop: t.stop,
      start: t.start,
      execUpdate: async () => ({ exitCode: 1, output: "binary in use" }),
      installedAfter: async () => "0.142.2",
    });
    expect(out.ok).toBe(false);
    expect(out.exitCode).toBe(1);
    expect(out.output).toBe("binary in use");
    expect(t.events).toContain("start:a"); // still brought back to life
  });

  it("treats an execUpdate throw as failure and still restarts", async () => {
    const t = tracer();
    const out = await runAgentUpdate({
      sessionIds: ["a"],
      stop: t.stop,
      start: t.start,
      execUpdate: async () => { throw new Error("spawn failed"); },
      installedAfter: async () => null,
    });
    expect(out.ok).toBe(false);
    expect(out.output).toContain("spawn failed");
    expect(t.events).toContain("start:a");
  });

  it("swallows a failed stop so it neither blocks the update nor the restart", async () => {
    const events: string[] = [];
    const out = await runAgentUpdate({
      sessionIds: ["a"],
      stop: async () => { throw new Error("stuck"); },
      start: (id) => { events.push(`start:${id}`); },
      execUpdate: async () => { events.push("update"); return { exitCode: 0, output: "" }; },
      installedAfter: async () => "0.144.3",
    });
    expect(out.ok).toBe(true);
    expect(events).toEqual(["update", "start:a"]);
  });

  it("runs the update with no stop/restart when there are no live sessions", async () => {
    const t = tracer();
    const out = await runAgentUpdate({
      sessionIds: [],
      stop: t.stop,
      start: t.start,
      execUpdate: async () => { t.events.push("update"); return { exitCode: 0, output: "ok" }; },
      installedAfter: async () => "0.144.3",
    });
    expect(out.ok).toBe(true);
    expect(t.events).toEqual(["update"]);
  });

  it("reports installed=null when the post-update version probe fails", async () => {
    const t = tracer();
    const out = await runAgentUpdate({
      sessionIds: [],
      stop: t.stop,
      start: t.start,
      execUpdate: async () => ({ exitCode: 0, output: "ok" }),
      installedAfter: async () => { throw new Error("probe failed"); },
    });
    expect(out.installed).toBeNull();
  });
});
