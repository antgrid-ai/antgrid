import { existsSync } from "node:fs";
import { runDbSerializer } from "../handoff/db-serialize";
import {
  SAFE_NATIVE_ID,
  refusesRealStoreUnderTest,
  type HandoffSnapshot,
  type HandoffSnapshotFn,
  type HandoffSnapshotOpts,
} from "../handoff/types";
import { resolveOpencodeDbPath } from "./db-read";

export interface OpencodeFamilySnapshotSpec {
  agent: "opencode" | "kilo";
  /** Undefined when the agent has no database file to read. */
  dbPath: string | undefined;
  includeKiloBoard: boolean;
}

/** opencode and Kilo share one database layout, so both snapshot through here.
 * The serialization runs in a worker: a long session would otherwise stall the
 * bridge loop that forwards every terminal frame. */
export async function snapshotOpencodeFamily(spec: OpencodeFamilySnapshotSpec, opts: HandoffSnapshotOpts): Promise<HandoffSnapshot | undefined> {
  const sessionId = opts.agentSessionId;
  if (!sessionId || !SAFE_NATIVE_ID.test(sessionId) || !spec.dbPath || !existsSync(spec.dbPath)) return undefined;
  const result = await runDbSerializer({
    serializer: spec.agent,
    dbPath: spec.dbPath,
    outDir: opts.outDir,
    args: { sessionId, prefix: spec.agent, includeKiloBoard: spec.includeKiloBoard },
    signal: opts.signal,
  });
  if (!result.files.length) return undefined;
  return {
    agent: spec.agent,
    agentSessionId: sessionId,
    method: "db-serialize",
    primary: `${spec.agent}-session.json`,
    files: result.files,
    references: result.references,
    redactions: result.redactions,
    warnings: result.warnings,
  };
}

export const opencodeSnapshot: HandoffSnapshotFn = (opts) =>
  snapshotOpencodeFamily(
    {
      agent: "opencode",
      dbPath: refusesRealStoreUnderTest(opts.opencodeDbPath) ? undefined : (opts.opencodeDbPath ?? resolveOpencodeDbPath()),
      includeKiloBoard: false,
    },
    opts,
  );
