import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { setupTestEnv, type TestEnv } from "../helpers/harness";

// Deterministic E2E for the plugin-notification delivery chain: a plugin hook
// POSTs the bridge's loopback /notify endpoint; the bridge emits
// notification:push, which must reach the paired app over relay + E2E. This
// covers Tasks 1-2 (app consumer) + the api-server wiring without needing a
// real coding-agent binary (the agent-internal hook trigger + codex fingerprint
// are validated separately: Task 5 golden hash, Task 8 drift probe).
test("bridge /notify delivers notification:push to the app", async () => {
  const env: TestEnv = await setupTestEnv({ fixtureName: "basic" });
  try {
    // The api-server writes its dynamically-allocated port to abDir/api.port on
    // startup (same file the harness's openPairingWindow reads). AgentHandle.port
    // is always 0 — the file is the only place the HTTP port is exposed.
    const apiPort = Number(readFileSync(join(env.abDir, "api.port"), "utf8").trim());

    const res = await fetch(`http://127.0.0.1:${apiPort}/notify`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ type: "task_complete", message: "build done" }),
    });
    expect(res.ok).toBe(true);

    const push = await env.app.waitForAbType("notification:push", 10_000);
    expect(push.notificationType).toBe("task_complete");
    expect(push.message).toBe("build done");
    expect(push.projectId).toBe(env.projectId);
  } finally {
    await env.teardown();
  }
}, 60_000);

// Full-chain validation (agent CLI loads the injected plugin, fires its
// turn-complete hook, the hook POSTs /notify → notification:push reaches the
// app) requires a real claude-code / codex binary + API credentials in the
// eval environment, which this suite does not provision; real-LLM turns are
// also non-deterministic. The codex hook-trust fingerprint — the highest-risk
// element — is instead validated by the golden-pinned unit test (Task 5,
// cargo-verified against the live codex) and the runtime /hook-alive drift
// probe (Task 8). Enable this manually when a binary is available.
test.skip("REAL-AGENT full chain: claude-code Stop → notification:push (needs binary)", () => {});
