import { isFragEnvelope, MAX_FRAGMENT_COUNT, type FragHint } from "antgrid-wire";

export interface ReassemblerOpts {
  timeoutMs: number;
  globalBudgetBytes: number;
  onComplete: (json: string) => void;
  onAbort: (hint: FragHint | null) => void;
  now?: () => number;
}

interface Transfer {
  n: number;
  parts: Array<string | undefined>;
  count: number;
  bytes: number;
  hint: FragHint | null;
  lastTs: number;
}

export class FragReassembler {
  private transfers = new Map<string, Transfer>();
  private totalBytes = 0;
  private readonly now: () => number;

  constructor(private readonly opts: ReassemblerOpts) {
    this.now = opts.now ?? (() => Date.now());
  }

  accept(plaintext: string): boolean {
    // Fast pre-parse filter: buildFragments emits `__frag` first so every
    // fragment frame starts with this prefix (kept in lockstep in frag.ts).
    if (!plaintext.startsWith('{"__frag"')) return false;

    let parsed: unknown;
    try {
      parsed = JSON.parse(plaintext);
    } catch {
      return true;
    }
    if (!isFragEnvelope(parsed)) return true;

    const { id, i, n, hint } = parsed.__frag;
    // Bound `n` before allocating the parts array — see MAX_FRAGMENT_COUNT.
    if (
      !Number.isInteger(i) ||
      !Number.isInteger(n) ||
      i < 0 ||
      n <= 0 ||
      n > MAX_FRAGMENT_COUNT ||
      i >= n
    ) {
      return true;
    }

    let transfer = this.transfers.get(id);
    if (!transfer) {
      transfer = {
        n,
        parts: new Array(n),
        count: 0,
        bytes: 0,
        hint: hint ?? null,
        lastTs: this.now(),
      };
      this.transfers.set(id, transfer);
    } else if (transfer.n !== n) {
      this.discard(id, transfer, true);
      return true;
    }

    if (hint) transfer.hint ??= hint;

    if (transfer.parts[i] === undefined) {
      transfer.parts[i] = parsed.data;
      transfer.count++;
      const bytes = Buffer.byteLength(parsed.data, "utf8");
      transfer.bytes += bytes;
      this.totalBytes += bytes;
    }
    transfer.lastTs = this.now();

    this.enforceBudget();
    if (this.transfers.get(id) === transfer && transfer.count === transfer.n) {
      const json = transfer.parts.join("");
      this.remove(id, transfer);
      this.opts.onComplete(json);
    }

    return true;
  }

  sweep(): void {
    const cutoff = this.now() - this.opts.timeoutMs;
    for (const [id, transfer] of this.transfers) {
      if (transfer.lastTs <= cutoff) this.discard(id, transfer, true);
    }
  }

  private enforceBudget(): void {
    while (this.totalBytes > this.opts.globalBudgetBytes) {
      let oldest: [string, Transfer] | null = null;
      for (const entry of this.transfers) {
        if (!oldest || entry[1].lastTs < oldest[1].lastTs) oldest = entry;
      }
      if (!oldest) return;
      this.discard(oldest[0], oldest[1], true);
    }
  }

  private remove(id: string, transfer: Transfer): void {
    this.totalBytes -= transfer.bytes;
    this.transfers.delete(id);
  }

  private discard(id: string, transfer: Transfer, abort: boolean): void {
    this.remove(id, transfer);
    if (abort) this.opts.onAbort(transfer.hint);
  }
}
