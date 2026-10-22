import { ByteBudget, writeBytes } from "./snapshot-io";
import { HandoffSnapshotError, type HandoffFile, type HandoffReference, type HandoffSnapshotErrorCode } from "./types";

export interface DbSerializeRequest {
  /** Key into `DB_SERIALIZERS`. */
  serializer: string;
  dbPath: string;
  outDir: string;
  /** Structured-clone-safe input for the serializer (a session id, flags). */
  args?: unknown;
  budgetMax?: number;
}

export interface DbSerializeResult {
  files: HandoffFile[];
  references: HandoffReference[];
  redactions: string[];
  warnings: string[];
}

/** A serialized file as encoded bytes, transferred rather than copied out of the worker. */
export interface DbSerializedFile {
  name: string;
  role: HandoffFile["role"];
  bytes: Uint8Array;
  originalName?: string;
  sourcePath?: string;
}

interface DbSerialized {
  files: DbSerializedFile[];
  references: HandoffReference[];
  redactions: string[];
  warnings: string[];
}

export type DbSerializeResponse =
  | { ok: true; output: DbSerialized }
  | { ok: false; code: HandoffSnapshotErrorCode; message: string; errno?: string };

// A compiled bridge has no file to resolve a URL against: Bun embeds a worker
// entrypoint under the path it was given on the build command line, and only a
// string literal is recognised as one. The bridge build lists this worker as an
// extra entrypoint from the repo root, so that literal is repo-root relative.
const IN_COMPILED_BINARY = import.meta.dir.includes("~BUN") || import.meta.dir.startsWith("/$bunfs");

/** Serializes part of an agent database in a Worker, then writes the files it
 * produced into `outDir` from this side. Aborting `signal` terminates a worker
 * still serializing or stops the writes; whatever was written stays for the
 * caller to delete with the rest of the partial dir. */
export async function runDbSerializer(request: DbSerializeRequest & { signal: AbortSignal }): Promise<DbSerializeResult> {
  const { signal, ...message } = request;
  const output = await serializeInWorker(message, signal);
  const budget = new ByteBudget(request.budgetMax, signal);
  const files: HandoffFile[] = [];
  for (const file of output.files) {
    const written = await writeBytes(request.outDir, file.name, file.bytes, file.role, budget);
    files.push({
      ...written,
      ...(file.originalName !== undefined ? { originalName: file.originalName } : {}),
      ...(file.sourcePath !== undefined ? { sourcePath: file.sourcePath } : {}),
    });
  }
  return { files, references: output.references, redactions: output.redactions, warnings: output.warnings };
}

/** The worker does no file I/O of its own: Bun crashes the whole process when a
 * worker is terminated while the fs pool still holds one of its requests, and
 * the deadline terminates it at any point. */
function serializeInWorker(message: DbSerializeRequest, signal: AbortSignal): Promise<DbSerialized> {
  return new Promise((resolve, reject) => {
    if (signal.aborted) {
      reject(new HandoffSnapshotError("UNREADABLE", "The handoff snapshot ran past its deadline."));
      return;
    }
    const worker = IN_COMPILED_BINARY
      ? new Worker("./packages/antgrid-agents/src/agents/handoff/db-serialize-worker.ts")
      : new Worker(new URL("./db-serialize-worker.ts", import.meta.url).href);
    const finish = (settle: () => void) => {
      signal.removeEventListener("abort", onAbort);
      worker.terminate();
      settle();
    };
    const onAbort = () => finish(() => reject(new HandoffSnapshotError("UNREADABLE", "The handoff snapshot ran past its deadline.")));
    signal.addEventListener("abort", onAbort, { once: true });
    worker.onmessage = (event: MessageEvent<DbSerializeResponse>) => finish(() => {
      const response = event.data;
      if (response.ok) resolve(response.output);
      else reject(new HandoffSnapshotError(response.code, response.message, response.errno));
    });
    worker.onerror = (event) => finish(() => reject(new HandoffSnapshotError("UNREADABLE", `Database serializer failed: ${event.message}`)));
    worker.postMessage(message satisfies DbSerializeRequest);
  });
}
