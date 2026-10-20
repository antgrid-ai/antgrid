import type { ForkHandoffOpts } from "../types";

/** Flat, lowercase output names only: native ids and sidecar names never become
 * path components, and lowercasing ids instead would collide on
 * case-insensitive filesystems. */
export const HANDOFF_FILE_NAME = /^[a-z0-9][a-z0-9._-]{0,95}$/;
/** Every native id is checked against this before any path or glob use. */
export const SAFE_NATIVE_ID = /^[A-Za-z0-9_-]{1,128}$/;
/** Counted as bytes are WRITTEN (decompressed or serialized), never from stat. */
export const MAX_HANDOFF_SNAPSHOT_BYTES = 256 * 1024 * 1024;
/** Bridge-side deadline for one staging pass; the app's fork timeout is longer. */
export const HANDOFF_STAGE_DEADLINE_MS = 60_000;

export type HandoffMethod = "copy" | "decompress" | "db-serialize";

export interface HandoffFile {
  /** Relative to outDir; matches HANDOFF_FILE_NAME. */
  name: string;
  role: "transcript" | "segment" | "sidecar";
  /** The native name an indexed output name stands for (a checkpoint, a child session id). */
  originalName?: string;
  /** Provenance only; the bridge never re-reads it. */
  sourcePath?: string;
  /** Byte range of the decompressed source. */
  sourceRange?: { start: number; end: number };
  bytes: number;
  sha256: string;
}

/** An absolute source path deliberately left in place (subagent logs, tool results). */
export interface HandoffReference { path: string; note: string }

export interface HandoffSnapshot {
  /** Registry key of the SOURCE agent. */
  agent: string;
  agentSessionId?: string;
  method: HandoffMethod;
  /** Name of the file a reader starts with. */
  primary: string;
  /** In reading order (Codex: root segment first). */
  files: HandoffFile[];
  references: HandoffReference[];
  redactions: string[];
  warnings: string[];
}

export interface HandoffSnapshotOpts extends ForkHandoffOpts {
  /** Empty and bridge-created; the adapter writes ONLY here. */
  outDir: string;
  /** Source launch cwd: resolve(checkoutPath, workingDir). */
  sourceCwd: string;
  /** Aborted at HANDOFF_STAGE_DEADLINE_MS. */
  signal: AbortSignal;
  // Test seams; production leaves them undefined.
  copilotHome?: string;
  antigravityHome?: string;
  kimiHome?: string;
  codexHome?: string;
  cursorConfigDir?: string;
  vibeHome?: string;
  kiloDbPath?: string;
  opencodeDbPath?: string;
  claudeProjectsRoot?: string;
}

/** `undefined` means no native store was found for this identity; the bridge
 * then falls back to the terminal scrollback. */
export type HandoffSnapshotFn = (opts: HandoffSnapshotOpts) => Promise<HandoffSnapshot | undefined>;

/** WRITE is a failure on the output side (a full disk, a locked staging dir):
 * unlike UNREADABLE it says nothing about the source store, so falling back to
 * the scrollback would hit the same failure and hide it. */
export type HandoffSnapshotErrorCode = "TOO_LARGE" | "UNREADABLE" | "WRITE";

export class HandoffSnapshotError extends Error {
  constructor(readonly code: HandoffSnapshotErrorCode, message: string, readonly errno?: string) {
    super(message);
    this.name = "HandoffSnapshotError";
  }
}

/** True under the test runner when the caller passed no seam: a snapshot then
 * returns undefined instead of reading the developer's real agent store. Same
 * guard as kimi/hooks.ts. */
export function refusesRealStoreUnderTest(seam: string | undefined): boolean {
  return seam === undefined && /\.(test|spec)\.[cm]?[jt]sx?$/.test(Bun.main);
}
