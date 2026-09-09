import { describe, test, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  sendProjectBinding,
  ProjectBindingReporter,
  type ProjectBindingCredentials,
} from "../src/project-binding";
import { HostServer, type HostRemoteConfig, type RemoteRuntime } from "../src/host-server";
import { computeProjectId } from "../src/project-id";
import type { RelayClient } from "../src/relay-client";

interface Call {
  url: string;
  init?: RequestInit;
}

function recordingFetch(calls: Call[], status: () => number = () => 200): typeof fetch {
  return (async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
    calls.push({ url: input as string, init: init as RequestInit });
    return new Response(null, { status: status() });
  }) as typeof fetch;
}

function bodyOf(call: Call): Record<string, unknown> {
  return JSON.parse(call.init?.body as string);
}

// report() is fire-and-forget, so its outcome handling (the 409 log, the retry
// re-arm) lands a microtask later than the caller returns.
const settle = () => new Promise((r) => setTimeout(r, 0));

describe("sendProjectBinding", () => {
  it("POSTs the bindings URL with bearer auth and the contract body", async () => {
    const calls: Call[] = [];

    const outcome = await sendProjectBinding({
      licenseApiUrl: "https://api.example.com",
      getToken: () => "test-token",
      deviceUuid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
      localProjectId: "abc123",
      localPath: "/home/me/repo",
      repoKey: "github.com/acme/widgets",
      fetchFn: recordingFetch(calls),
    });

    expect(outcome).toBe("ok");
    expect(calls).toHaveLength(1);
    expect(calls[0]!.url).toBe("https://api.example.com/account/projects/bindings");
    expect(calls[0]!.init?.method).toBe("POST");
    const headers = calls[0]!.init?.headers as Record<string, string>;
    expect(headers["authorization"]).toBe("Bearer test-token");
    expect(headers["content-type"]).toBe("application/json");

    const body = bodyOf(calls[0]!);
    expect(body).toEqual({
      deviceUuid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
      localProjectId: "abc123",
      localPath: "/home/me/repo",
      repoKey: "github.com/acme/widgets",
    });
    // The label belongs to the repository, not to one machine's folder — web
    // derives it from the repoKey when it is absent.
    expect(body).not.toHaveProperty("displayName");
  });

  it("maps 409 to conflict and every other non-2xx to failed", async () => {
    const send = (status: number) =>
      sendProjectBinding({
        licenseApiUrl: "https://api.example.com",
        getToken: () => "tok",
        deviceUuid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
        localProjectId: "abc123",
        localPath: "/repo",
        repoKey: "github.com/acme/widgets",
        fetchFn: (async (
          _input: Parameters<typeof fetch>[0],
          _init?: Parameters<typeof fetch>[1],
        ) => new Response(null, { status })) as typeof fetch,
      });

    expect(await send(200)).toBe("ok");
    expect(await send(409)).toBe("conflict");
    expect(await send(403)).toBe("failed");
    expect(await send(404)).toBe("failed");
    expect(await send(500)).toBe("failed");
  });

  it("returns failed on a network error rather than throwing", async () => {
    const outcome = await sendProjectBinding({
      licenseApiUrl: "https://api.example.com",
      getToken: () => "tok",
      deviceUuid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
      localProjectId: "abc123",
      localPath: "/repo",
      repoKey: "github.com/acme/widgets",
      fetchFn: (async (
        _input: Parameters<typeof fetch>[0],
        _init?: Parameters<typeof fetch>[1],
      ): Promise<Response> => {
        throw new Error("network failure");
      }) as typeof fetch,
    });
    expect(outcome).toBe("failed");
  });
});

describe("ProjectBindingReporter", () => {
  const creds: ProjectBindingCredentials = {
    licenseApiUrl: "https://api.example.com",
    getToken: () => "tok",
    deviceUuid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
  };

  const binding = {
    localProjectId: "abc123",
    localPath: "/home/me/repo",
    repoKey: "github.com/acme/widgets" as string | undefined,
  };

  it("reports a binding once and does not re-POST unchanged values", async () => {
    const calls: Call[] = [];
    const reporter = new ProjectBindingReporter({
      credentials: () => creds,
      fetchFn: recordingFetch(calls),
    });

    reporter.report(binding);
    await settle();
    reporter.report({ ...binding });
    reporter.report({ ...binding });
    await settle();

    expect(calls).toHaveLength(1);
    expect(bodyOf(calls[0]!).repoKey).toBe("github.com/acme/widgets");
  });

  it("sends nothing when the project has no repoKey", async () => {
    const calls: Call[] = [];
    const reporter = new ProjectBindingReporter({
      credentials: () => creds,
      fetchFn: recordingFetch(calls),
    });

    reporter.report({ ...binding, repoKey: undefined });
    await settle();

    expect(calls).toHaveLength(0);
  });

  it("sends nothing when the machine has no remote credentials", async () => {
    const calls: Call[] = [];
    const reporter = new ProjectBindingReporter({
      credentials: () => null,
      fetchFn: recordingFetch(calls),
    });

    reporter.report(binding);
    await settle();

    expect(calls).toHaveLength(0);
  });

  it("re-POSTs when the repoKey or the local path moves", async () => {
    const calls: Call[] = [];
    const reporter = new ProjectBindingReporter({
      credentials: () => creds,
      fetchFn: recordingFetch(calls),
    });

    reporter.report(binding);
    await settle();
    reporter.report({ ...binding, repoKey: "github.com/acme/gadgets" });
    await settle();
    reporter.report({ ...binding, repoKey: "github.com/acme/gadgets", localPath: "/home/me/moved" });
    await settle();

    expect(calls).toHaveLength(3);
    expect(bodyOf(calls[1]!).repoKey).toBe("github.com/acme/gadgets");
    expect(bodyOf(calls[2]!).localPath).toBe("/home/me/moved");
  });

  it("does not retry a 409 — no retry can resolve another account's claim", async () => {
    const calls: Call[] = [];
    const reporter = new ProjectBindingReporter({
      credentials: () => creds,
      fetchFn: recordingFetch(calls, () => 409),
    });

    reporter.report(binding);
    await settle();
    reporter.report({ ...binding });
    reporter.report({ ...binding });
    await settle();

    expect(calls).toHaveLength(1);
  });

  it("survives a non-2xx and lets the next open retry it", async () => {
    const calls: Call[] = [];
    let status = 500;
    const reporter = new ProjectBindingReporter({
      credentials: () => creds,
      fetchFn: recordingFetch(calls, () => status),
    });

    expect(() => reporter.report(binding)).not.toThrow();
    await settle();
    expect(calls).toHaveLength(1);

    status = 200;
    reporter.report({ ...binding });
    await settle();
    expect(calls).toHaveLength(2);

    // Now that it landed, the memo holds again.
    reporter.report({ ...binding });
    await settle();
    expect(calls).toHaveLength(2);
  });

  it("survives a throwing fetch without breaking the caller", async () => {
    const reporter = new ProjectBindingReporter({
      credentials: () => creds,
      fetchFn: (async (
        _input: Parameters<typeof fetch>[0],
        _init?: Parameters<typeof fetch>[1],
      ): Promise<Response> => {
        throw new Error("offline");
      }) as typeof fetch,
    });

    expect(() => reporter.report(binding)).not.toThrow();
    await settle();
  });
});

describe("HostServer wiring", () => {
  let host: HostServer | null = null;
  let prevAbDir: string | undefined;
  let abDir: string | undefined;
  let realFetch: typeof fetch;
  const folders: string[] = [];
  const calls: Call[] = [];

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

  // Inert machine relay client: keeps startRemoteControlPlane off a real socket.
  function stubRelayClient(): RelayClient {
    return {
      deviceId: "control-plane-dev",
      currentPeerPubkey: () => null,
      setBus: () => {},
      connect: () => {},
      close: () => {},
      attachStream: () => ({ streamId: "s1", detach: () => {}, sendTunnel: () => {} }),
      sendPushDeliver: () => {},
    } as unknown as RelayClient;
  }

  function remoteFolder(): string {
    const f = mkdtempSync(join(tmpdir(), "antgrid-binding-"));
    folders.push(f);
    writeFileSync(join(f, "antgrid.yaml"), "name: test-remote\nagent:\n  tool: claude-code\n");
    return f;
  }

  beforeEach(() => {
    prevAbDir = process.env.ANTGRID_DIR;
    abDir = mkdtempSync(join(tmpdir(), "antgrid-abdir-"));
    process.env.ANTGRID_DIR = abDir;
    calls.length = 0;
    realFetch = globalThis.fetch;
    globalThis.fetch = (async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
      const url = String(input);
      if (url.includes("/account/projects/bindings")) {
        calls.push({ url, init: init as RequestInit });
      }
      return new Response(null, { status: 200 });
    }) as typeof fetch;
  });

  afterEach(async () => {
    await host?.shutdown();
    host = null;
    globalThis.fetch = realFetch;
    if (prevAbDir === undefined) delete process.env.ANTGRID_DIR;
    else process.env.ANTGRID_DIR = prevAbDir;
    if (abDir) rmSync(abDir, { recursive: true, force: true });
    while (folders.length) {
      const f = folders.pop()!;
      for (let i = 0; i < 20; i++) {
        try {
          rmSync(f, { recursive: true, force: true });
          break;
        } catch {
          await new Promise((r) => setTimeout(r, 25));
        }
      }
    }
  });

  test("a remote open reports the project's binding, and a re-open does not repeat it", async () => {
    host = new HostServer({
      remote: fakeRemoteConfig(),
      remoteRuntimeFactory: async () => fakeRuntime(),
      relayClientFactory: () => stubRelayClient(),
    });
    const folder = remoteFolder();
    const id = computeProjectId(folder);

    await host.open(id, folder, "remote");
    await settle();

    expect(calls).toHaveLength(1);
    const body = bodyOf(calls[0]!);
    expect(body.deviceUuid).toBe("uuid-1");
    expect(body.localProjectId).toBe(id);
    expect(body.localPath).toBeTruthy();
    // A folder with no shareable origin still binds — under this machine's
    // synthetic key (see repoKeyFor).
    expect(body.repoKey).toBe(`local:uuid-1/${id}`);

    await host.open(id, folder, "remote");
    await settle();
    expect(calls).toHaveLength(1);
  });

  test("a local open reports nothing — no OAuth runtime, same guard as the heartbeat", async () => {
    host = new HostServer({
      remote: fakeRemoteConfig(),
      remoteRuntimeFactory: async () => fakeRuntime(),
      relayClientFactory: () => stubRelayClient(),
    });
    const folder = remoteFolder();
    const id = computeProjectId(folder);

    await host.open(id, folder, "local");
    await settle();

    expect(calls).toHaveLength(0);
  });
});
