import { spawn } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { generateKeyPairSync } from "node:crypto";
import { computeProjectId } from "../../bridge/src/project-id";
import { readHostFile, type HostFile } from "../../bridge/src/host-discovery";
import { LocalTestClient, type LocalConnectInfo } from "./local-client";

export interface LocalTestEnvOpts {
  /**
   * Static license token threaded into the `promo` fixture for the
   * relay-promotion path. The agent presents it on relay `register`; the eval
   * relay's `fakeLicenseGate` accepts any non-empty token, so this is the
   * offline static-token path (no OAuth refresh). Defaults to undefined; the
   * promotion eval passes `TEST_LICENSE_TOKEN`.
   */
  licenseToken?: string;
  /**
   * Relay HTTP(S) base (WITHOUT a trailing `/ws`) the promotion controller
   * connects to. The controller re-appends `/ws` and upgrades http→ws via
   * `joinRelayWsPath`, so pass the bare base. Used by the promotion eval.
   */
  relayUrl?: string;
}

export interface LocalTestEnv {
  client: LocalTestClient;
  folder: string;
  projectId: string;
  abDir: string;
  connect: LocalConnectInfo;
  /**
   * Promotion fixture: a device UUID + an Ed25519 keypair (raw 32-byte keys,
   * standard-base64, matching the encoding `DeviceIdentity`/`RelayClient`
   * expect) for the `agent:enableRelay` `auth`. The keypair is freshly
   * generated: the eval relay's `fakeLicenseGate` does no `pk`→pubkey binding,
   * so the keys only need to be a valid matching pair for the relay's Ed25519
   * challenge-response, not derived from the license token's `pk` claim.
   */
  promo: { deviceUuid: string; ed25519Pub: string; ed25519Priv: string };
  cleanup: () => Promise<void>;
}

/**
 * Export the raw 32-byte Ed25519 key as standard base64 — the encoding the
 * agent's `DeviceIdentity` / `RelayClient` decode via `Buffer.from(.., "base64")`
 * when signing the relay challenge-response. Mirrors `harness.ts`'s `b64Raw`.
 */
function b64RawKey(key: import("node:crypto").KeyObject, type: "spki" | "pkcs8"): string {
  return Buffer.from(key.export({ format: "der", type }).subarray(-32)).toString("base64");
}

/**
 * Boot an agent in **local mode** by piping a local `BootstrapPayload` to its
 * stdin (the contract in `bridge/src/index.ts`). Local mode is loopback-only:
 * the agent generates a random deviceId and runs a `LocalListener` — no relay,
 * no OAuth, no on-disk identity. The host publishes its control port + token to
 * `host.json`; this helper opens the project over the control plane and attaches
 * the returned `LocalTestClient` over the connect info's port + token.
 */
export async function setupLocalTestEnv(_opts: LocalTestEnvOpts = {}): Promise<LocalTestEnv> {
  // Promotion fixture keypair. Freshly generated: the eval relay's
  // `fakeLicenseGate` accepts any non-empty token and does NOT compare the
  // token's `pk` claim to the presented pubkey, so these keys need only be a
  // valid Ed25519 pair for the relay's challenge-response — not bound to the
  // license token. Fixed UUID for a stable relay-auth identity across runs.
  const promoEd = generateKeyPairSync("ed25519");
  const promo = {
    deviceUuid: "0bbd1111-2222-3333-4444-555566667777",
    ed25519Pub: b64RawKey(promoEd.publicKey, "spki"),
    ed25519Priv: b64RawKey(promoEd.privateKey, "pkcs8"),
  };

  const folder = mkdtempSync(join(tmpdir(), "antgrid-local-eval-"));
  const abDir = mkdtempSync(join(tmpdir(), "antgrid-local-eval-home-"));
  // Pin `name` for the human-facing agent label; projectId is derived from folder.
  writeFileSync(
    join(folder, "antgrid.yaml"),
    "name: local-eval\nagent: { tool: claude }\n",
  );
  writeFileSync(join(folder, "hello.txt"), "world\n");

  const projectId = computeProjectId(folder);
  const hostPath = join(abDir, "host.json");

  const payload = {
    firstProject: {
      projectId,
      projectPath: folder,
      mode: "local" as const,
    },
  };

  const child = spawn(
    "bun",
    [join(import.meta.dir, "..", "..", "bridge", "src", "index.ts")],
    {
      stdio: ["pipe", "pipe", "pipe"],
      env: { ...process.env, ANTGRID_DIR: abDir, LOG_LEVEL: "error" },
    },
  );

  // Hand the agent its bootstrap payload, then close stdin so
  // `readBootstrapPayload` (which reads until EOF) resolves.
  child.stdin.write(JSON.stringify(payload) + "\n");
  child.stdin.end();

  // Wait for the host to publish host.json (control port + token).
  let hf: HostFile | null = null;
  for (let i = 0; i < 30; i++) {
    hf = readHostFile(hostPath);
    if (hf && hf.pid === child.pid) break;
    await new Promise((r) => setTimeout(r, 100));
  }
  if (!hf) {
    child.kill();
    rmSync(folder, { recursive: true, force: true });
    throw new Error("agent did not publish host.json in 3s");
  }

  // Open the project over the control plane to obtain loopback connect info.
  let connect: LocalConnectInfo;
  try {
    const res = await fetch(`http://127.0.0.1:${hf.controlPort}/control`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${hf.token}` },
      body: JSON.stringify({ id: "local-eval", type: "project:open", projectId, projectPath: folder, mode: "local" }),
    });
    const body = (await res.json()) as { ok: boolean; connect?: LocalConnectInfo };
    if (!body.ok || !body.connect) throw new Error("project:open returned no connect info");
    connect = body.connect;
  } catch (err) {
    child.kill("SIGTERM");
    rmSync(folder, { recursive: true, force: true });
    throw err;
  }

  const client = new LocalTestClient();
  try {
    await client.connect(connect);
  } catch (err) {
    child.kill("SIGTERM");
    rmSync(folder, { recursive: true, force: true });
    throw err;
  }

  return {
    client, folder, projectId, abDir, connect, promo,
    cleanup: async () => {
      client.close();
      child.kill("SIGTERM");
      await new Promise((r) => setTimeout(r, 200));
      // EBUSY on Windows when the agent process hasn't fully released its
      // file handles yet — ignore, temp dirs will be cleaned up by the OS.
      try { rmSync(folder, { recursive: true, force: true }); } catch { /* ignore */ }
      try { rmSync(abDir, { recursive: true, force: true }); } catch { /* ignore */ }
    },
  };
}
