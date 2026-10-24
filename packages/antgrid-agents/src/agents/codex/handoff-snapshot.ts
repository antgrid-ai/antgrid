import {
  ByteBudget,
  HandoffSnapshotError,
  SAFE_NATIVE_ID,
  copyWholeLines,
  refusesRealStoreUnderTest,
  writePrefix,
  type HandoffFile,
  type HandoffSnapshotFn,
  type RolloutSource,
} from "../handoff";
import { codexHomeDir } from "./home";
import {
  locateBaseRollout,
  locateThreadRollout,
  readFirstRecord,
  rolloutKey,
  wholeLineLength,
} from "./rollout-locate";

const MAX_LINEAGE_DEPTH = 16;

interface Segment {
  source: RolloutSource;
  /** Decompressed bytes of this file that belong to the thread; undefined for the leaf. */
  end?: number;
}

function historyBase(meta: unknown): { threadId: unknown; end: unknown } | undefined {
  const base = (meta as { payload?: { history_base?: { thread_id?: unknown; end_byte_offset?: unknown } | null } } | undefined)
    ?.payload?.history_base;
  return base ? { threadId: base.thread_id, end: base.end_byte_offset } : undefined;
}

/** A forked or rolled-back thread keeps its earlier turns, including the
 * original task, in another file that its first record points into. */
async function lineage(leaf: RolloutSource, home: string, signal: AbortSignal): Promise<Segment[]> {
  const chain: Segment[] = [{ source: leaf }];
  const visited = new Set([rolloutKey(leaf)]);
  for (;;) {
    const current = chain[chain.length - 1]!;
    const base = historyBase(await readFirstRecord(current.source));
    if (!base) return chain;
    if (chain.length > MAX_LINEAGE_DEPTH) {
      throw new HandoffSnapshotError("UNREADABLE", "A Codex thread's history is chained too deeply to copy.");
    }
    if (typeof base.threadId !== "string" || !SAFE_NATIVE_ID.test(base.threadId)) {
      throw new HandoffSnapshotError("UNREADABLE", "A Codex history base names an unsafe thread id.");
    }
    if (typeof base.end !== "number" || !Number.isSafeInteger(base.end) || base.end <= 0) {
      throw new HandoffSnapshotError("UNREADABLE", "A Codex history base has no usable byte offset.");
    }
    const source = await locateBaseRollout(base.threadId, visited, { home, signal });
    if (!source) throw new HandoffSnapshotError("UNREADABLE", "A Codex history base rollout was not found.");
    visited.add(rolloutKey(source));
    chain.push({ source, end: base.end });
  }
}

export const codexSnapshot: HandoffSnapshotFn = async (opts) => {
  const threadId = opts.agentSessionId;
  if (!threadId || !SAFE_NATIVE_ID.test(threadId)) return undefined;
  if (refusesRealStoreUnderTest(opts.codexHome)) return undefined;
  const home = opts.codexHome ?? codexHomeDir();

  const leaf = await locateThreadRollout(threadId, opts.transcriptPath, { home, signal: opts.signal });
  if (!leaf) return undefined;
  // Root first, so the file a reader opens first holds the original task.
  const segments = (await lineage(leaf, home, opts.signal)).reverse();

  const budget = new ByteBudget(undefined, opts.signal);
  const files: HandoffFile[] = [];
  for (const [index, segment] of segments.entries()) {
    const name = `codex-rollout-${String(index + 1).padStart(2, "0")}.jsonl`;
    const isLeaf = index === segments.length - 1;
    const { source } = segment;
    if (isLeaf && !source.compressed) {
      files.push(await copyWholeLines(source.path, opts.outDir, name, "transcript", budget));
      continue;
    }
    // A compressed leaf is immutable (Codex only compresses idle rollouts), so
    // measuring its last whole line first cannot race an append.
    const end = isLeaf ? await wholeLineLength(source) : segment.end!;
    files.push(
      await writePrefix(
        source,
        end,
        opts.outDir,
        name,
        { role: isLeaf ? "transcript" : "segment", sourcePath: source.path, sourceRange: { start: 0, end } },
        budget,
      ),
    );
  }

  return {
    agent: "codex",
    agentSessionId: threadId,
    // No .zst bytes are kept: no target agent can grep zstd.
    method: segments.some((s) => s.source.compressed) ? "decompress" : "copy",
    primary: files[files.length - 1]!.name,
    files,
    references: [],
    redactions: [],
    warnings: [],
  };
};
