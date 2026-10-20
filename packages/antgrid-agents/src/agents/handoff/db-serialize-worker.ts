import { DB_SERIALIZERS } from "./db-serializers";
import { ByteBudget, writeText } from "./snapshot-io";
import { withReadSnapshot } from "./sqlite-read";
import { HandoffSnapshotError, type HandoffFile } from "./types";
import type { DbSerializeRequest, DbSerializeResponse } from "./db-serialize";

// Worker entry. A large session is serialized here, off the bridge loop, which
// also forwards every PTY and relay frame; the parent terminates this worker on
// its deadline.
declare const self: Worker;

async function run(request: DbSerializeRequest): Promise<DbSerializeResponse> {
  try {
    const serializer = DB_SERIALIZERS[request.serializer];
    if (!serializer) throw new HandoffSnapshotError("UNREADABLE", `No serializer named ${request.serializer}.`);
    const output = withReadSnapshot(request.dbPath, (db) => serializer(db, request.args));
    const budget = new ByteBudget(request.budgetMax);
    const files: HandoffFile[] = [];
    for (const file of output.files) {
      const written = await writeText(request.outDir, file.name, file.text, file.role, budget);
      files.push({
        ...written,
        ...(file.originalName !== undefined ? { originalName: file.originalName } : {}),
        ...(file.sourcePath !== undefined ? { sourcePath: file.sourcePath } : {}),
      });
    }
    return { ok: true, result: { files, references: output.references, redactions: output.redactions, warnings: output.warnings } };
  } catch (error) {
    if (error instanceof HandoffSnapshotError) return { ok: false, code: error.code, message: error.message };
    return { ok: false, code: "UNREADABLE", message: error instanceof Error ? error.message : String(error) };
  }
}

self.onmessage = async (event: MessageEvent<DbSerializeRequest>) => {
  self.postMessage(await run(event.data));
};
