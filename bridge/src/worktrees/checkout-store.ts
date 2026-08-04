import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { z } from "zod";
import { CHECKOUT_KINDS, type CheckoutRecord } from "./checkout-types";

const RecordSchema = z.object({
  id: z.string().min(1),
  projectId: z.string().min(1),
  kind: z.enum(CHECKOUT_KINDS),
  path: z.string().min(1),
  branch: z.string().nullable(),
  baseRef: z.string().nullable(),
  managed: z.boolean(),
  sessionId: z.string().nullable(),
  createdAt: z.number().finite(),
});
const FileSchema = z.object({ version: z.literal(1), checkouts: z.array(z.unknown()) });

/** Durable metadata for managed checkouts. Corrupt rows are ignored individually
 * so a single interrupted/manual edit never hides healthy sibling worktrees. */
export class CheckoutStore {
  private readonly path: string;

  constructor(private readonly storeDir: string, readonly projectId: string) {
    this.path = join(storeDir, "agents", projectId, "checkouts.json");
  }

  async list(): Promise<CheckoutRecord[]> {
    let raw: string;
    try { raw = await readFile(this.path, "utf8"); } catch { return []; }
    try {
      const parsed = FileSchema.safeParse(JSON.parse(raw));
      if (!parsed.success) return [];
      return parsed.data.checkouts.flatMap((value) => {
        const row = RecordSchema.safeParse(value);
        return row.success && row.data.projectId === this.projectId ? [row.data] : [];
      });
    } catch { return []; }
  }

  async get(id: string): Promise<CheckoutRecord | undefined> {
    return (await this.list()).find((record) => record.id === id);
  }

  async put(record: CheckoutRecord): Promise<void> {
    if (record.projectId !== this.projectId) throw new Error("checkout projectId mismatch");
    await this.mutate((records) =>
      [...records.filter((item) => item.id !== record.id), RecordSchema.parse(record)]);
  }

  async remove(id: string): Promise<boolean> {
    let removed = false;
    await this.mutate((records) => {
      const next = records.filter((record) => record.id !== id);
      removed = next.length !== records.length;
      return removed ? next : null;
    });
    return removed;
  }

  /** Serializes the read-modify-write against every other holder of this file.
   * The lock is keyed by path and static because callers mint a fresh store per
   * call (WorktreeManager.storeFor), so an instance field would guard nothing:
   * two concurrent deletes would each write back the other's row. */
  private async mutate(
    apply: (records: CheckoutRecord[]) => CheckoutRecord[] | null,
  ): Promise<void> {
    const previous = CheckoutStore.writeLocks.get(this.path) ?? Promise.resolve();
    // Settles rather than rejects, so one failed write never poisons the queue
    // behind it; the caller still sees the original error via `failure`.
    let failure: unknown;
    const mine = previous.then(async () => {
      try {
        const next = apply(await this.list());
        if (next) await this.write(next);
      } catch (error) { failure = error; }
    });
    CheckoutStore.writeLocks.set(this.path, mine);
    try {
      await mine;
      if (failure !== undefined) throw failure;
    } finally {
      if (CheckoutStore.writeLocks.get(this.path) === mine) CheckoutStore.writeLocks.delete(this.path);
    }
  }

  private static readonly writeLocks = new Map<string, Promise<void>>();

  private async write(checkouts: CheckoutRecord[]): Promise<void> {
    await mkdir(join(this.storeDir, "agents", this.projectId), { recursive: true });
    const tmp = `${this.path}.tmp`;
    await writeFile(tmp, JSON.stringify({ version: 1, checkouts }, null, 2), "utf8");
    await rename(tmp, this.path);
  }
}
