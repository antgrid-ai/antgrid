import { describe, expect, it } from "bun:test";
import { Readable } from "node:stream";
import { readBootstrapPayload } from "../../src/auth/credentials";

const local = JSON.stringify({
  firstProject: { projectId: "proj1", projectPath: "/tmp/proj1", mode: "local" },
});
const remote = JSON.stringify({
  machine: {
    licenseApiUrl: "http://localhost:8787",
    relayUrl: "wss://relay.example.com",
    auth: {
      clientId: "client-abc",
      clientSecret: "secret-xyz",
      ed25519Priv: Buffer.alloc(32, 1).toString("base64"),
      ed25519Pub: Buffer.alloc(32, 2).toString("base64"),
      x25519Priv: Buffer.alloc(32, 3).toString("base64"),
      x25519Pub: Buffer.alloc(32, 4).toString("base64"),
      deviceUuid: "00000000-0000-0000-0000-000000000001",
    },
  },
  firstProject: { projectId: "proj1", projectPath: "/tmp/proj1", mode: "remote" },
});

function streamOf(s: string): NodeJS.ReadableStream {
  return Readable.from([Buffer.from(s + "\n")]);
}

describe("readBootstrapPayload", () => {
  it("parses a local-only first project", async () => {
    const p = await readBootstrapPayload({ stdin: streamOf(local) });
    expect(p.firstProject?.mode).toBe("local");
    expect(p.firstProject?.projectId).toBe("proj1");
    expect(p.firstProject?.projectPath).toBe("/tmp/proj1");
    expect(p.machine).toBeUndefined();
  });

  it("parses a remote first project with a machine block", async () => {
    const p = await readBootstrapPayload({ stdin: streamOf(remote) });
    expect(p.firstProject?.mode).toBe("remote");
    expect(p.machine?.auth.clientId).toBe("client-abc");
    expect(p.machine?.licenseApiUrl).toBe("http://localhost:8787");
  });

  it("rejects malformed JSON", async () => {
    await expect(readBootstrapPayload({ stdin: streamOf("not json") })).rejects.toThrow(/bootstrap payload/i);
  });

  it("rejects a remote first project missing auth fields", async () => {
    const bad = JSON.stringify({
      machine: {
        licenseApiUrl: "http://x",
        relayUrl: "ws://x",
        auth: { clientId: "only-this" },
      },
      firstProject: { projectId: "p", projectPath: "/p", mode: "remote" },
    });
    await expect(readBootstrapPayload({ stdin: streamOf(bad) })).rejects.toThrow();
  });

  it("rejects a remote first project with no machine block", async () => {
    const bad = JSON.stringify({
      firstProject: { projectId: "p", projectPath: "/p", mode: "remote" },
    });
    await expect(readBootstrapPayload({ stdin: streamOf(bad) })).rejects.toThrow();
  });

  it("parses a machine-only payload with no first project", async () => {
    const machineOnly = JSON.stringify({
      machine: {
        licenseApiUrl: "http://localhost:8787",
        relayUrl: "wss://relay.example.com",
        auth: {
          clientId: "client-abc",
          clientSecret: "secret-xyz",
          ed25519Priv: Buffer.alloc(32, 1).toString("base64"),
          ed25519Pub: Buffer.alloc(32, 2).toString("base64"),
          x25519Priv: Buffer.alloc(32, 3).toString("base64"),
          x25519Pub: Buffer.alloc(32, 4).toString("base64"),
          deviceUuid: "00000000-0000-0000-0000-000000000001",
        },
      },
    });
    const p = await readBootstrapPayload({ stdin: streamOf(machineOnly) });
    expect(p.firstProject).toBeUndefined();
    expect(p.machine?.auth.deviceUuid).toBe("00000000-0000-0000-0000-000000000001");
  });

  it("parses a project-less payload with no machine block (warm local host)", async () => {
    const p = await readBootstrapPayload({ stdin: streamOf(JSON.stringify({})) });
    expect(p.firstProject).toBeUndefined();
    expect(p.machine).toBeUndefined();
  });

  it("times out on inert stdin", async () => {
    const inert = new Readable({ read() {} });
    const t0 = Date.now();
    await expect(readBootstrapPayload({ stdin: inert, timeoutMs: 200 })).rejects.toThrow(/bootstrap payload/i);
    expect(Date.now() - t0).toBeLessThan(1000);
  });

  it("prints a human-launch notice when stdin is a TTY", async () => {
    const tty = new Readable({ read() {} }) as Readable & { isTTY?: boolean };
    tty.isTTY = true;
    const lines: string[] = [];
    await expect(
      readBootstrapPayload({ stdin: tty, timeoutMs: 200, writeNotice: (l) => lines.push(l) }),
    ).rejects.toThrow(/bootstrap payload/i);
    expect(lines.join("\n")).toContain("Antgrid desktop app");
    expect(lines.join("\n")).toContain("Ctrl+C");
  });

  it("stays silent on a piped (non-TTY) stdin", async () => {
    const lines: string[] = [];
    const p = await readBootstrapPayload({ stdin: streamOf(local), writeNotice: (l) => lines.push(l) });
    expect(p.firstProject?.projectId).toBe("proj1");
    expect(lines).toEqual([]);
  });
});
