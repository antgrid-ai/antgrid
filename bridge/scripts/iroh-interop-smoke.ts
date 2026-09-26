import assert from "node:assert/strict";
import { existsSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import { TERMINAL_PROTOCOL_VERSION } from "../src/terminal-frames/protocol";
import { startSmokeFixture } from "./iroh-smoke-fixture";

// Cross-binding gate: a real Dart `IrohPeerLink` over `iroh_quic` against a real
// `NativeHostConnection` host over `@number0/iroh`. The two bindings are different
// implementations at different versions, so every gate that binds `@number0/iroh`
// on both ends — iroh-host-smoke included — leaves this pairing unproven.
// Authorization is the same fixture the host smoke uses; this is transport and
// protocol interop, not backend-auth qualification.

const TRANSPORT_DIR = fileURLToPath(new URL("../../packages/antgrid_peer_transport", import.meta.url));

/**
 * Bun cannot exec Flutter's `dart.bat` shim directly on Windows, so prefer the
 * real `dart.exe` in the SDK cache and fall back through cmd.exe. Mirrors
 * `evals/helpers/dart-app-client.ts`, which hit the same uv_spawn limitation.
 */
function dartArgv(script: string[]): string[] {
  const explicit = process.env.IROH_INTEROP_DART;
  if (explicit) return [explicit, ...script];
  const which = Bun.which("dart");
  if (process.platform !== "win32") return ["dart", ...script];
  if (which && which.toLowerCase().endsWith(".bat")) {
    const exe = join(dirname(which), "cache", "dart-sdk", "bin", "dart.exe");
    if (existsSync(exe)) return [exe, ...script];
    const comspec = process.env.ComSpec ?? "C:\\Windows\\System32\\cmd.exe";
    return [comspec, "/c", which, ...script];
  }
  return [which ?? "dart", ...script];
}

/** Reads whole JSON lines from the child without assuming chunk boundaries. */
async function* jsonLines(stream: ReadableStream<Uint8Array>): AsyncGenerator<any> {
  const decoder = new TextDecoder();
  let buffered = "";
  for await (const chunk of stream) {
    buffered += decoder.decode(chunk, { stream: true });
    let cut = buffered.indexOf("\n");
    while (cut >= 0) {
      const line = buffered.slice(0, cut).trim();
      buffered = buffered.slice(cut + 1);
      if (line) yield JSON.parse(line);
      cut = buffered.indexOf("\n");
    }
  }
}

const nativeLibrary = process.env.IROH_INTEROP_NATIVE_LIBRARY;
const child = Bun.spawn(
  dartArgv(["run", "bin/interop_app.dart", ...(nativeLibrary ? [nativeLibrary] : [])]),
  { cwd: TRANSPORT_DIR, stdin: "pipe", stdout: "pipe", stderr: "inherit" },
);
const lines = jsonLines(child.stdout);
async function next(expected?: string): Promise<any> {
  const result = await lines.next();
  assert.equal(result.done, false, `Dart app exited before ${expected ?? "the next line"}`);
  if (expected) assert.equal(result.value.check, expected, `Expected ${expected}, got ${JSON.stringify(result.value)}`);
  return result.value;
}

let fixture: Awaited<ReturnType<typeof startSmokeFixture>> | undefined;
const timeout = setTimeout(() => {
  console.error("iroh-interop-smoke timed out");
  process.exitCode = 1;
  child.kill();
  void fixture?.dispose();
}, 120_000);
try {
  const identity = await next();
  assert.match(identity.endpointId, /^[0-9a-f]{64}$/, "Dart must report a hex endpoint id");
  assert.ok(identity.publicKey, "Dart must report its Ed25519 identity");

  // The Dart child owns its Ed25519 secret; only the public half crosses here.
  const appDeviceId = randomUUID();
  fixture = await startSmokeFixture({
    appEndpointId: identity.endpointId,
    app: { id: appDeviceId, public: identity.publicKey },
    label: "iroh-interop-smoke",
  });
  const native = await fixture.nativeAddress();
  child.stdin.write(JSON.stringify({
    endpointId: native.endpointId,
    addresses: native.addresses,
    machineId: fixture.machine.id,
    machinePublic: fixture.machine.public,
    appId: appDeviceId,
    projects: fixture.projects,
    terminalProtocolVersion: TERMINAL_PROTOCOL_VERSION,
    resumeCycles: 3,
  }) + "\n");
  await child.stdin.flush();

  await next("established");
  await next("session-ping-pong");
  // The Dart app probes a project the host opened local-only: it is
  // cataloged, but no core for it is relay-registered until a project:start
  // promotes it, so the open is refused in-band as NOT_READY.
  const refused = await next("stream-refused");
  assert.equal(refused.code, "NOT_READY");
  // Central goes down only after E2E is up, so everything below proves the
  // native path carried it rather than a surviving WebSocket.
  fixture.takeCentralOffline();
  for (const project of fixture.projects) {
    const verified = await next("project-verified");
    assert.equal(verified.project, project.name);
    if (project.name === "alpha") {
      await next("managed-checkout-git");
      await next("terminal-roundtrip");
    }
  }
  const pass = await next("interop-pass");
  assert.equal(pass.projects, fixture.projects.length);

  const resumeRecoveryMs: number[] = [];
  for (let cycle = 0; cycle < 3; cycle++) {
    for (const project of fixture.projects) writeFileSync(join(fixture.root, project.name, "proof.txt"), `${project.name}:resume:${cycle}`);
    const started = performance.now();
    fixture.host.notePeerResume();
    const resumed = await next("resume-verified");
    assert.equal(resumed.cycle, cycle);
    resumeRecoveryMs.push(performance.now() - started);
  }

  await fixture.host.handleRemoteAccessVerb({ id: "disable", type: "mobile-access:set", enabled: false });
  await next("closed-on-revocation");
  assert.equal(await child.exited, 0, "Dart app must exit cleanly");
  console.log(JSON.stringify({
    result: "pass", gate: "cross-binding", appBinding: pass.appBinding, hostBinding: "@number0/iroh",
    authorization: "fixture", native: "real", host: "real", e2e: "real",
    projects: pass.projects, centralOutage: true, remoteAccessOffClosed: true,
    terminalInputOutput: true, managedCheckoutGit: true, resumeCycles: 3, resumeRecoveryMs,
  }));
} finally {
  clearTimeout(timeout);
  child.kill();
  await fixture?.dispose();
}
