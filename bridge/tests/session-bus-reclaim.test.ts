// What a delete actually reclaims, asked through the loaders rather than of the
// filesystem.
//
// Today every one of these stores is a JSON file under the session or project
// directory, so both deletes are one `rm -rf` and this suite is nearly a
// tautology. That is exactly why it is written now: the moment any of them
// stops being a file under that tree — a machine-level store of any kind — the
// `rm -rf` reclaims only what is left behind it, and the rows survive under a
// project id nothing on the machine can name again. Nothing would say so. A
// test phrased against `existsSync` would move with the implementation and
// keep passing; one phrased against the loaders cannot.
import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostServer, type HostRemoteConfig, type RemoteRuntime } from "../src/host-server";
import { computeProjectId } from "../src/project-id";
import { setLogLevel } from "../src/logger";
import {
  addArtifact,
  loadArtifacts,
  readArtifactContent,
  saveArtifacts,
  writeArtifactContent,
  type ArtifactRecord,
} from "../src/session-bus/artifact-store";
import { emptyDeliveries, enqueueLine, loadDeliveries, saveDeliveries } from "../src/session-bus/delivery-queue";
import { emptyHeld, holdMessage, loadHeld, saveHeld } from "../src/session-bus/held-store";
import { appendLog, emptyLog, loadMessageLog, saveMessageLog } from "../src/session-bus/message-log";
import { stampEnvelope } from "../src/session-bus/envelope";
import { removeSessionBusSession } from "../src/session-bus/store-fs";

setLogLevel("error");

const PEER = { machineId: "m2", projectId: "p-remote", sessionId: "s-remote" };

let prevAbDir: string | undefined;
let abDir: string;
let host: HostServer | null = null;

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-bus-reclaim-"));
  process.env.ANTGRID_DIR = abDir;
});

afterEach(async () => {
  await host?.shutdown();
  host = null;
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR;
  else process.env.ANTGRID_DIR = prevAbDir;
  rmSync(abDir, { recursive: true, force: true });
});

function artifact(id: string): ArtifactRecord {
  return {
    artifactId: id,
    contextId: "ctx-1",
    taskId: null,
    author: { ...PEER, sessionName: "remote" },
    name: `${id}.txt`,
    mediaType: "text/plain",
    bytes: 3,
    sha256: "0".repeat(64),
    summary: "a summary",
    createdAt: 1,
  };
}

/** Everything one session can leave behind, written the way the bus writes it. */
function seedSession(projectId: string, sessionId: string): void {
  saveMessageLog(
    abDir,
    projectId,
    sessionId,
    appendLog(emptyLog(), {
      at: 1,
      direction: "out",
      peer: PEER,
      envelope: stampEnvelope(
        { taskId: null, contextId: "ctx-1", parts: [{ kind: "text", text: "hello" }], summary: "a summary" },
        { messageId: "m-1", peer: { ...PEER, sessionName: "remote" }, now: 1 },
      ),
    }),
  );
  saveHeld(
    abDir,
    projectId,
    sessionId,
    holdMessage(emptyHeld(), {
      messageId: "m-1",
      contextId: "ctx-1",
      role: "lead",
      to: PEER,
      frame: { type: "session-bus:message" },
      heldAt: 1,
    }),
  );
  saveArtifacts(abDir, projectId, sessionId, addArtifact({ artifacts: [] }, artifact(`art-${sessionId}`)));
  writeArtifactContent(abDir, projectId, sessionId, `art-${sessionId}`, new Uint8Array([1, 2, 3]));
}

/** Read back everything `seedSession` wrote, as a caller would. */
function readSession(projectId: string, sessionId: string) {
  return {
    log: loadMessageLog(abDir, projectId, sessionId).entries.length,
    held: loadHeld(abDir, projectId, sessionId).held.length,
    artifacts: loadArtifacts(abDir, projectId, sessionId).artifacts.length,
    content: readArtifactContent(abDir, projectId, sessionId, `art-${sessionId}`, 0, 8)?.data.length ?? null,
  };
}

function seedDeliveries(projectId: string, sessionId: string): void {
  saveDeliveries(
    abDir,
    projectId,
    enqueueLine(emptyDeliveries(), {
      id: "line-1",
      sessionId,
      kind: "wake",
      text: "a rendered line",
      queuedAt: 1,
    }),
  );
}

test("deleting one session reclaims all four of its stores and leaves its sibling's alone", () => {
  const projectId = "p-alpha";
  seedSession(projectId, "s-doomed");
  seedSession(projectId, "s-kept");
  expect(readSession(projectId, "s-doomed")).toEqual({ log: 1, held: 1, artifacts: 1, content: 3 });

  removeSessionBusSession(abDir, projectId, "s-doomed");

  // A null `content` is the honest answer for bytes that are gone: the fetch
  // path reads it as ARTIFACT_NOT_FOUND, where a zero-length buffer would read
  // as an empty artifact (artifact-store.ts's own note on readArtifactContent).
  expect(readSession(projectId, "s-doomed")).toEqual({ log: 0, held: 0, artifacts: 0, content: null });
  expect(readSession(projectId, "s-kept")).toEqual({ log: 1, held: 1, artifacts: 1, content: 3 });
});

test("deleting one session leaves the project's delivery queue standing", () => {
  // The queue is per PROJECT and outlives any one session in it. A reclaim that
  // widened to cover it would drop lines rendered for every other session in
  // the project — and the coordinator acked whatever produced them long before
  // they were queued, so nothing would retry one.
  const projectId = "p-alpha";
  seedSession(projectId, "s-doomed");
  seedDeliveries(projectId, "s-other");

  removeSessionBusSession(abDir, projectId, "s-doomed");

  expect(loadDeliveries(abDir, projectId).lines).toHaveLength(1);
});

function fakeRemoteConfig(): HostRemoteConfig {
  return {
    relayUrl: "ws://127.0.0.1:1",
    licenseApiUrl: "http://127.0.0.1:1",
    identity: { deviceId: "dev-1", deviceName: "dev-1", createdAt: "2026-01-01T00:00:00.000Z" },
    auth: { clientId: "cid", clientSecret: "secret", deviceUuid: "uuid-1" },
    onAuthRevoked: () => {},
  };
}

function fakeRuntime(): RemoteRuntime {
  return { maint: { getToken: () => "tok", stop: () => {} } };
}

/** A real project folder, so `open` resolves the id it will later be forgotten
 *  under — `forget()` reclaims by that id and nothing else. */
function tempProject(): { folder: string; projectId: string } {
  const folder = mkdtempSync(join(tmpdir(), "antgrid-bus-reclaim-proj-"));
  writeFileSync(join(folder, "antgrid.yaml"), "name: reclaim\nagent:\n  tool: claude-code\n");
  return { folder, projectId: computeProjectId(folder) };
}

test("forgetting a project reclaims every session's bus state and its delivery queue", async () => {
  const h = (host = new HostServer({
    remote: fakeRemoteConfig(),
    remoteRuntimeFactory: () => Promise.resolve(fakeRuntime()),
  }));
  const doomed = tempProject();
  const kept = tempProject();
  await h.open(doomed.projectId, doomed.folder, "local");
  await h.open(kept.projectId, kept.folder, "local");
  // `forget()` deletes the whole store dir, so a project with no sessions.json
  // is not the case that matters — seed one, as SessionManager would.
  for (const p of [doomed, kept]) {
    mkdirSync(join(abDir, "agents", p.projectId), { recursive: true });
    writeFileSync(
      join(abDir, "agents", p.projectId, "sessions.json"),
      JSON.stringify({ version: 1, sessions: [{ id: "s1", name: "S", createdAt: 1, lastUsedAt: 1, archived: false }] }),
    );
    seedSession(p.projectId, "s1");
    seedDeliveries(p.projectId, "s1");
  }

  await h.forget(doomed.projectId);

  expect(readSession(doomed.projectId, "s1")).toEqual({ log: 0, held: 0, artifacts: 0, content: null });
  expect(loadDeliveries(abDir, doomed.projectId).lines).toHaveLength(0);
  // Every assertion above is also true of a project that was never seeded, so
  // the untouched neighbour is what makes them mean anything.
  expect(readSession(kept.projectId, "s1")).toEqual({ log: 1, held: 1, artifacts: 1, content: 3 });
  expect(loadDeliveries(abDir, kept.projectId).lines).toHaveLength(1);
});
