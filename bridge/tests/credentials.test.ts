import { test, expect } from "bun:test";
import { BootstrapPayloadSchema } from "../src/auth/credentials";

const AUTH = {
  clientId: "cid", clientSecret: "csecret",
  ed25519Pub: "abc", ed25519Priv: "abc", x25519Pub: "abc", x25519Priv: "abc",
  deviceUuid: "00000000-0000-0000-0000-000000000000",
};

test("accepts a local-only payload with no machine block", () => {
  const r = BootstrapPayloadSchema.safeParse({
    firstProject: { projectId: "p", projectPath: "/tmp/p", mode: "local" },
  });
  expect(r.success).toBe(true);
});

test("accepts a remote payload with a machine block", () => {
  const r = BootstrapPayloadSchema.safeParse({
    machine: { relayUrl: "ws://localhost:1", licenseApiUrl: "https://x.test", auth: AUTH },
    firstProject: { projectId: "p", projectPath: "/tmp/p", mode: "remote" },
  });
  expect(r.success).toBe(true);
});

test("rejects a remote first project with no machine block", () => {
  const r = BootstrapPayloadSchema.safeParse({
    firstProject: { projectId: "p", projectPath: "/tmp/p", mode: "remote" },
  });
  expect(r.success).toBe(false);
});

test("accepts a payload with no firstProject (machine-only warm-up spawn)", () => {
  // firstProject is optional: an eager warm-up spawn opens no project — the host
  // boots its control plane and waits for project:open RPCs.
  expect(BootstrapPayloadSchema.safeParse({ machine: undefined }).success).toBe(true);
});

test("accepts an optional ownerPid and surfaces it", () => {
  const r = BootstrapPayloadSchema.safeParse({
    firstProject: { projectId: "p", projectPath: "/tmp/p", mode: "local" },
    ownerPid: 4242,
  });
  expect(r.success).toBe(true);
  if (r.success) expect(r.data.ownerPid).toBe(4242);
});

test("rejects a non-positive ownerPid", () => {
  for (const ownerPid of [0, -1, 1.5]) {
    const r = BootstrapPayloadSchema.safeParse({
      firstProject: { projectId: "p", projectPath: "/tmp/p", mode: "local" },
      ownerPid,
    });
    expect(r.success).toBe(false);
  }
});
