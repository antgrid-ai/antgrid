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
 * must be tagged with the project's `streamId`. `setupTestEnv` pairs + pulls the
 * control-plane snapshot, which seeds the `agent:projects` advert but NOT the
 * per-project state — so a migrated scenario resolves the firstProject's stream
 * from that advert and drives verbs over it via `sendOnStream` /
 * `waitForStreamAbType`.
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
  const responseP = app
    .waitForStreamAbType(streamId, "response" as AbMessage["type"], timeoutMs)
    .catch(() => null);
  app.sendOnStream(
    streamId,
    createMessage("request", { requestId, method: "state.snapshot", params: { types: ["*"] } } as never),
  );
  const res = (await responseP) as { ok?: boolean; result?: { frames?: AbMessage[] } } | null;
  if (!res?.ok) return [];
  return res.result?.frames ?? [];
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
