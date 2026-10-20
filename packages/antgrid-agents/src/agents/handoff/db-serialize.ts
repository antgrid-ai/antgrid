import { HandoffSnapshotError, type HandoffFile, type HandoffReference } from "./types";

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

export type DbSerializeResponse =
  | { ok: true; result: DbSerializeResult }
  | { ok: false; code: "TOO_LARGE" | "UNREADABLE"; message: string };

/** Serializes part of an agent database in a Worker and resolves with the files
 * it wrote into `outDir`. Aborting `signal` terminates the worker; whatever it
 * had written stays for the caller to delete with the rest of the partial dir. */
export function runDbSerializer(request: DbSerializeRequest & { signal: AbortSignal }): Promise<DbSerializeResult> {
  const { signal, ...message } = request;
  return new Promise((resolve, reject) => {
    if (signal.aborted) {
      reject(new HandoffSnapshotError("UNREADABLE", "The handoff snapshot ran past its deadline."));
      return;
    }
    const worker = new Worker(new URL("./db-serialize-worker.ts", import.meta.url).href);
    const finish = (settle: () => void) => {
      signal.removeEventListener("abort", onAbort);
      worker.terminate();
      settle();
    };
    const onAbort = () => finish(() => reject(new HandoffSnapshotError("UNREADABLE", "The handoff snapshot ran past its deadline.")));
    signal.addEventListener("abort", onAbort, { once: true });
    worker.onmessage = (event: MessageEvent<DbSerializeResponse>) => finish(() => {
      const response = event.data;
      if (response.ok) resolve(response.result);
      else reject(new HandoffSnapshotError(response.code, response.message));
    });
    worker.onerror = (event) => finish(() => reject(new HandoffSnapshotError("UNREADABLE", `Database serializer failed: ${event.message}`)));
    worker.postMessage(message satisfies DbSerializeRequest);
  });
}
