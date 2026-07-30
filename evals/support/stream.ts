import { randomBytes } from "node:crypto";
import type { RelayClient } from "../helpers/relay-client";
import { createMessage, type AbMessage } from "../../bridge/src/protocol";

/**
 * v3 project data-plane helpers.
 *
 * In v3 a machine holds ONE sealed session; project traffic runs as streams
 * inside it (design §7.1). The machine control plane (`s` omitted) carries only
 * host verbs, pairing UX, and the catalog adverts (`agent:projects` /
 * `agent:tools`); every project verb (`file:read`, `terminal:*`, `git:*`, …)
 * must be tagged with the project's `streamId`. `setupTestEnv` admits the app,
 * turns the machine's mobile-access switch on and pulls the control-plane
 * snapshot, which seeds the `agent:projects` advert but NOT the per-project
 * state — so a migrated scenario resolves the firstProject's stream from that
 * advert and drives verbs over it via `sendOnStream` / `waitForStreamAbType`.
 *
 * These live outside `evals/helpers/` because the harness is a shared,
 * frozen surface (the gate agent consumes it too); this is additive test glue.
 */

/** Resolve the streamId the agent allocated for `projectId`, read from the
 *  `agent:projects` advert setupTestEnv seeds via its control-plane snapshot. */
export async function firstProjectStream(
  app: RelayClient,
  projectId: string,
  timeoutMs = 8_000,
): Promise<string> {
  const advert = await app.waitForAbType("agent:projects", timeoutMs);
  const entry = advert.projects.find((p) => p.projectId === projectId);
  if (!entry?.streamId) {
    throw new Error(`no streamId advertised for project ${projectId} (running=${entry?.running})`);
  }
  return entry.streamId;
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
