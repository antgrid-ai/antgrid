import { randomBytes } from "node:crypto";
import type { RelayClient } from "../helpers/relay-client";
import { createMessage, type AbMessage } from "../../bridge/src/protocol";

/** The eval-side name for the machine control plane's stream handle — the
 *  session stream carries no bridge-minted id, so this is just the constant
 *  every helper compares against (mirrors `sendOnStream`'s own `"0"` check). */
export const CONTROL_HANDLE = "0";

/**
 * v3 project data-plane helpers.
 *
 * In v3 a machine holds ONE sealed session; each project gets its OWN QUIC
 * stream inside it (Stage A wave A4). The machine control plane (`s` omitted)
 * carries only host verbs, pairing UX, and the catalog adverts
 * (`agent:projects` / `agent:tools`); every project verb (`file:read`,
 * `terminal:*`, `git:*`, …) rides that project's stream, addressed by its
 * handle — which IS `projectId` (D-8), never a bridge-minted id. `setupTestEnv`
 * admits the app, turns the machine's mobile-access switch on and pulls the
 * control-plane snapshot, which seeds the `agent:projects` advert but NOT the
 * per-project state — so a migrated scenario waits for that advert to show the
 * project running, opens its stream, and drives verbs over it via
 * `sendOnStream` / `waitForStreamAbType`.
 *
 * These live outside `evals/helpers/` because the harness is a shared,
 * frozen surface (the gate agent consumes it too); this is additive test glue.
 */

/** Wait for `projectId` to show `running:true` in a fresh `agent:projects`
 *  advert (hazard J: opening a project stream before the core is
 *  relay-registered is refused `NOT_READY`), then open its stream and return
 *  the handle (`projectId`). */
export async function firstProjectStream(
  app: RelayClient,
  projectId: string,
  timeoutMs = 8_000,
): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const remaining = deadline - Date.now();
    if (remaining <= 0) throw new Error(`project ${projectId} was never advertised running`);
    const advert = await app.waitForAbType("agent:projects", remaining);
    const entry = advert.projects.find((p) => p.projectId === projectId);
    if (entry?.running) break;
  }
  return app.openProjectStream(projectId, Math.max(1, deadline - Date.now()));
}

/**
 * Pull the per-project `state.snapshot` over the stream and return the cached
 * frames (agent:status, tree:full, git:status, …). Mirrors what a
 * `ProjectSession` does on bind — the frames live in the RPC response, so a test
 * that asserts project state reads them from here rather than awaiting a live,
 * de-duped push.
 */
export async function streamSnapshot(
  app: RelayClient,
  streamId: string,
  timeoutMs = 8_000,
): Promise<AbMessage[]> {
  const requestId = `snap-${randomBytes(6).toString("hex")}`;
  // Correlate on `requestId`, not the `response` type alone. Several helpers
  // issue RPCs on the same stream and `waitFor` takes the OLDEST queued match,
  // so a type-only waiter can bind to an unrelated call's response — returning
  // its frames, or `[]` because its unrelated `ok:false` looked like ours.
  const responseP = app
    .waitFor(
      (m: any) =>
        m._streamId === streamId && m.type === "response" && m.requestId === requestId,
      timeoutMs,
    )
    .catch(() => null);
  app.sendOnStream(
    streamId,
    createMessage("request", { requestId, method: "state.snapshot", params: { types: ["*"] } } as never),
  );
  const res = (await responseP) as { ok?: boolean; result?: { frames?: AbMessage[] } } | null;
  if (!res?.ok) return [];
  return res.result?.frames ?? [];
}

/**
 * Re-pull the control-plane catalog until `resolve` succeeds (default: the
 * project's advertised streamId).
 *
 * Authorization is machine-level and the harness sets it once, so there is
 * nothing per-project left to grant here — what still races is CATALOG
 * freshness. A project opened through the loopback `project:open` verb lands in
 * the host's catalog (and becomes dialable) asynchronously, and the phone learns
 * about it only from a fresh advert. Draining the queued `agent:projects` before
 * each pull is load-bearing: a stale queued advert from before the open would
 * otherwise satisfy a type-only waiter with pre-open contents.
 */
export async function resolveOnFreshAdvert<T = string>(
  app: RelayClient,
  projectId: string,
  opts: { attempts?: number; gapMs?: number; resolve?: (app: RelayClient) => Promise<T> } = {},
): Promise<T> {
  const attempts = opts.attempts ?? 10;
  const gapMs = opts.gapMs ?? 400;
  const resolve =
    opts.resolve ?? ((a: RelayClient) => firstProjectStream(a, projectId, 3_000) as unknown as Promise<T>);
  let lastErr: unknown;
  for (let i = 0; i < attempts; i++) {
    app.drainQueued("agent:projects");
    await app.pullStateSnapshot();
    try {
      return await resolve(app);
    } catch (err) {
      lastErr = err;
      await Bun.sleep(gapMs);
    }
  }
  throw new Error(`resolveOnFreshAdvert(${projectId}) never resolved: ${String(lastErr)}`);
}

/** Resolve the firstProject stream AND its snapshot frames in one step. */
export async function bindFirstProject(
  app: RelayClient,
  projectId: string,
  timeoutMs = 8_000,
): Promise<{ streamId: string; frames: AbMessage[] }> {
  const streamId = await firstProjectStream(app, projectId, timeoutMs);
  const frames = await streamSnapshot(app, streamId, timeoutMs);
  return { streamId, frames };
}
