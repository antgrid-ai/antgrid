import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { z } from "zod";
import { CHECKOUT_KINDS, DURABLE_SETUP_STATES, type CheckoutRecord } from "./checkout-types";

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
  setupState: z.enum(DURABLE_SETUP_STATES).optional(),
  setupFinishedAt: z.number().finite().optional(),
  setupExitCode: z.number().int().optional(),
});
const FileSchema = z.object({ version: z.literal(1), checkouts: z.array(z.unknown()) });

export interface CheckoutStoreState {
  /** True only when the file was absent or read whole with every row parsed. A
   * false here means "there may be rows I could not see", which is emphatically
   * not the same answer as "there are no rows" — anything that DELETES on the
   * strength of a checkout being unlisted must refuse to act on it. */
  healthy: boolean;
  records: CheckoutRecord[];
}

/** Five tries, so four waits of 20/40/60/80ms. Long enough to outlast a reader
 *  or a scanner holding the file, short enough that a write which is genuinely
 *  stuck still reports rather than hanging a session action behind it. */
export const RENAME_ATTEMPTS = 5;
const RENAME_BACKOFF_MS = 20;

/**
 * Replace `to` with `from`, waiting out a destination somebody else has open.
 *
 * The write half of the race {@link CheckoutStore.read} already documents from
 * the read side. Windows refuses a rename onto a path any other handle holds,
 * and this file has far more readers than writers — every `list()` is one, and
 * the indexer or a virus scanner will open it uninvited. Those openings last
 * milliseconds, so waiting one out turns a lost write into a slightly later
 * one; without it a single concurrent reader is enough to surface EPERM to the
 * caller as a failed session action.
 *
 * `renameFn` is a test seam — production passes nothing.
 */
export async function renameReplacing(
  from: string, to: string, renameFn: typeof rename = rename,
): Promise<void> {
  for (let attempt = 1; ; attempt++) {
    try { return await renameFn(from, to); }
    catch (error) {
      // Only the "someone else has it open" family is worth waiting out. A bad
      // path or a missing source answers the same on every attempt, so retrying
      // those would delay the report and change nothing else.
      const code = (error as NodeJS.ErrnoException | undefined)?.code;
      const busy = code === "EPERM" || code === "EACCES" || code === "EBUSY";
      if (!busy || attempt >= RENAME_ATTEMPTS) throw error;
      await new Promise((resolve) => setTimeout(resolve, RENAME_BACKOFF_MS * attempt));
    }
  }
}

/** Durable metadata for managed checkouts. Corrupt rows are ignored individually
 * so a single interrupted/manual edit never hides healthy sibling worktrees. */
export class CheckoutStore {
  private readonly path: string;

  constructor(private readonly storeDir: string, readonly projectId: string) {
    this.path = join(storeDir, "agents", projectId, "checkouts.json");
  }

  async list(): Promise<CheckoutRecord[]> {
    return (await this.read()).records;
  }

  /** `list()` plus whether the answer is complete. Readers that only display or
   * look up a row want `list()`; a reader deriving "nothing names this" wants
   * this one. */
  async read(): Promise<CheckoutStoreState> {
    let raw: string;
    try { raw = await readFile(this.path, "utf8"); }
    catch (error) {
      // No file is the honest empty state. Anything else — EPERM/EBUSY while a
      // sibling process renames the replacement into place, a half-written
      // file — is an unknown one.
      const absent = (error as NodeJS.ErrnoException | undefined)?.code === "ENOENT";
      return { healthy: absent, records: [] };
    }
    try {
      const parsed = FileSchema.safeParse(JSON.parse(raw));
      if (!parsed.success) return { healthy: false, records: [] };
      const records: CheckoutRecord[] = [];
      let healthy = true;
      for (const value of parsed.data.checkouts) {
        const row = RecordSchema.safeParse(value);
        // A foreign projectId is filtered rather than trusted, but it is still a
        // row this file should never have carried: `put` refuses the mismatch.
        if (!row.success || row.data.projectId !== this.projectId) { healthy = false; continue; }
        records.push(row.data);
      }
      return { healthy, records };
    } catch { return { healthy: false, records: [] }; }
  }

  async get(id: string): Promise<CheckoutRecord | undefined> {
    return (await this.list()).find((record) => record.id === id);
  }

  async put(record: CheckoutRecord): Promise<void> {
    if (record.projectId !== this.projectId) throw new Error("checkout projectId mismatch");
    await this.mutate((records) =>
      [...records.filter((item) => item.id !== record.id), RecordSchema.parse(record)]);
  }

  /**
   * Rewrite one row from its current value, under the same lock the write takes.
   *
   * The only safe way to annotate a row a caller does not own outright: a
   * `get()` followed by a `put()` spans two lock acquisitions, so a `remove()`
   * landing between them is undone — the put RESURRECTS a checkout whose
   * directory Git has already deleted. Returns false when the row is gone, which
   * is the annotation quietly dropping rather than a failure.
   */
  async update(id: string, patch: (record: CheckoutRecord) => CheckoutRecord): Promise<boolean> {
    let applied = false;
    await this.mutate((records) => {
      const current = records.find((item) => item.id === id);
      if (!current) return null;
      const next = RecordSchema.parse(patch(current));
      if (next.id !== id) throw new Error("checkout id mismatch");
      if (next.projectId !== this.projectId) throw new Error("checkout projectId mismatch");
      applied = true;
      return [...records.filter((item) => item.id !== id), next];
    });
    return applied;
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

  private static tmpSeq = 0;

  private async write(checkouts: CheckoutRecord[]): Promise<void> {
    await mkdir(join(this.storeDir, "agents", this.projectId), { recursive: true });
    // Unique per write rather than one fixed `.tmp`. The lock above orders THIS
    // process's writes, but nothing orders a second process holding the same
    // store, and on a shared name the two overwrite each other's bytes before
    // either renames — so what lands is the loser's file under the winner's
    // name, with no error anywhere.
    const tmp = `${this.path}.${process.pid}.${++CheckoutStore.tmpSeq}.tmp`;
    await writeFile(tmp, JSON.stringify({ version: 1, checkouts }, null, 2), "utf8");
    try {
      await renameReplacing(tmp, this.path);
    } catch (error) {
      // The replacement never landed, so the temp file is litter in a directory
      // the user can open — and litter that accumulates, since the name it was
      // given is never reused.
      await rm(tmp, { force: true }).catch(() => { /* the rethrow is the report */ });
      throw error;
    }
  }
}
