import type { Database } from "bun:sqlite";
import type { HandoffFile, HandoffReference } from "./types";

export interface DbSerializeFile {
  name: string;
  role: HandoffFile["role"];
  text: string;
  originalName?: string;
  sourcePath?: string;
}

export interface DbSerializeOutput {
  files: DbSerializeFile[];
  references: HandoffReference[];
  redactions: string[];
  warnings: string[];
}

/** Runs inside `withReadSnapshot`, so it must be synchronous and return text
 * only; the worker writes the files after the read transaction has closed, so
 * a slow disk never holds a reader against the agent's checkpoint. */
export type DbSerializer = (db: Database, args: unknown) => DbSerializeOutput;

/** The worker imports this statically rather than loading a serializer by path:
 * a compiled bridge bundles only what its entrypoints reach, and a dynamic
 * import of a computed path would be absent from the binary. Register a
 * serializer here to make it available to `runDbSerializer`. */
export const DB_SERIALIZERS: Record<string, DbSerializer> = {};
