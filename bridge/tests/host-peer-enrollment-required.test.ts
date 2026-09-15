import { expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostServer } from "../src/host-server";
import { computeProjectId } from "../src/project-id";

test("production WebSocket host cannot start remote transport without secure endpoint enrollment", async () => {
  const root = mkdtempSync(join(tmpdir(), "antgrid-enrollment-required-"));
  const previousDirectory = process.env.ANTGRID_DIR;
  const previousMode = process.env.ANTGRID_PEER_TRANSPORT;
  process.env.ANTGRID_DIR = join(root, "state");
  process.env.ANTGRID_PEER_TRANSPORT = "websocket";
  writeFileSync(join(root, "antgrid.yaml"), "name: enrollment-required\nagent:\n  tool: claude-code\n");
  const host = new HostServer({ remote: {
    relayUrl: "ws://127.0.0.1:1", licenseApiUrl: "http://127.0.0.1:1",
    identity: { deviceId: "test-device", deviceName: "test", createdAt: "" },
    auth: { clientId: "credential", clientSecret: "test-only", deviceUuid: "test-device" },
    onAuthRevoked: () => {},
  }, remoteRuntimeFactory: async () => ({ maint: { getToken: () => "test-only", stop: () => {} } }) });
  try {
    await expect(host.open(computeProjectId(root), root, "remote")).rejects.toThrow("secure endpoint enrollment");
    expect(host.list()).toEqual([]);
  } finally {
    await host.shutdown();
    if (previousDirectory === undefined) delete process.env.ANTGRID_DIR; else process.env.ANTGRID_DIR = previousDirectory;
    if (previousMode === undefined) delete process.env.ANTGRID_PEER_TRANSPORT; else process.env.ANTGRID_PEER_TRANSPORT = previousMode;
    rmSync(root, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
  }
});
