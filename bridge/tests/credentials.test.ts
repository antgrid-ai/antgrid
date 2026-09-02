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

test("accepts an optional ownerBuild and surfaces it verbatim", () => {
  const r = BootstrapPayloadSchema.safeParse({
    firstProject: { projectId: "p", projectPath: "/tmp/p", mode: "local" },
    ownerBuild: "1.20662.412 (0f3b1c) 2026-08-21T00:00:00Z",
  });
  expect(r.success).toBe(true);
  // Opaque to the host — it is echoed into host.json, never interpreted.
  if (r.success) expect(r.data.ownerBuild).toBe("1.20662.412 (0f3b1c) 2026-08-21T00:00:00Z");
  // An app predating the field still boots a host.
  expect(BootstrapPayloadSchema.safeParse({ ownerPid: 1 }).success).toBe(true);
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

// Consent is optional on the wire (an older app, the CLI, a test sends none)
// and index.ts resolves its ABSENCE to off — so the schema's job is only to
// keep a present value honest, never to supply one.
test("telemetryEnabled is optional and must be a boolean when present", () => {
  const base = { firstProject: { projectId: "p", projectPath: "/tmp/p", mode: "local" } };
  // `.success` asserted separately: `.data?.x` is undefined both for a payload
  // that parsed WITHOUT the field and for one the schema rejected outright, so
  // on its own it cannot tell "optional" from "no longer accepted".
  const absent = BootstrapPayloadSchema.safeParse(base);
  expect(absent.success).toBe(true);
  expect(absent.data?.telemetryEnabled).toBeUndefined();
  expect(BootstrapPayloadSchema.safeParse({ ...base, telemetryEnabled: true }).data?.telemetryEnabled).toBe(true);
  expect(BootstrapPayloadSchema.safeParse({ ...base, telemetryEnabled: false }).data?.telemetryEnabled).toBe(false);
  expect(BootstrapPayloadSchema.safeParse({ ...base, telemetryEnabled: "yes" }).success).toBe(false);
});
