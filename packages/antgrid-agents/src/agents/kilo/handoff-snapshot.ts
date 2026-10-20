import { snapshotOpencodeFamily } from "../opencode/handoff-snapshot";
import { refusesRealStoreUnderTest, type HandoffSnapshotFn } from "../handoff/types";
import { resolveKiloDbPath } from "./db-path";

export const kiloSnapshot: HandoffSnapshotFn = (opts) =>
  snapshotOpencodeFamily(
    {
      agent: "kilo",
      dbPath: refusesRealStoreUnderTest(opts.kiloDbPath) ? undefined : (opts.kiloDbPath ?? resolveKiloDbPath()),
      includeKiloBoard: true,
    },
    opts,
  );
