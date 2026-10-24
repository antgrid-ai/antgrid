import { DB_SERIALIZERS } from "./db-serializers";
import { ByteBudget } from "./snapshot-io";
import { withReadSnapshot } from "./sqlite-read";
import { HandoffSnapshotError } from "./types";
import type { DbSerializedFile, DbSerializeRequest, DbSerializeResponse } from "./db-serialize";

// Worker entry. A large session is serialized and encoded here, off the bridge
// loop, which also forwards every PTY and relay frame; the parent terminates
// this worker on its deadline and writes the files itself.
declare const self: Worker;

function run(request: DbSerializeRequest): DbSerializeResponse {
  try {
    const serializer = DB_SERIALIZERS[request.serializer];
    if (!serializer) throw new HandoffSnapshotError("UNREADABLE", `No serializer named ${request.serializer}.`);
    const output = withReadSnapshot(request.dbPath, (db) => serializer(db, request.args));
    // Counted here too, so an oversized session is refused before its bytes cross over.
    const budget = new ByteBudget(request.budgetMax);
    const encoder = new TextEncoder();
    const files = output.files.map((file): DbSerializedFile => {
      const bytes = encoder.encode(file.text);
      budget.take(bytes.length);
      return {
        name: file.name,
        role: file.role,
        bytes,
        ...(file.originalName !== undefined ? { originalName: file.originalName } : {}),
        ...(file.sourcePath !== undefined ? { sourcePath: file.sourcePath } : {}),
      };
    });
    return { ok: true, output: { files, references: output.references, redactions: output.redactions, warnings: output.warnings } };
  } catch (error) {
    if (error instanceof HandoffSnapshotError) {
      return { ok: false, code: error.code, message: error.message, ...(error.errno !== undefined ? { errno: error.errno } : {}) };
    }
    return { ok: false, code: "UNREADABLE", message: error instanceof Error ? error.message : String(error) };
  }
}

self.onmessage = (event: MessageEvent<DbSerializeRequest>) => {
  const response = run(event.data);
  self.postMessage(response, response.ok ? response.output.files.map((file) => file.bytes.buffer as ArrayBuffer) : []);
};
