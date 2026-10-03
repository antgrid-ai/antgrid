import { posix, win32 } from "node:path";
import type { DetectRow } from "../../src/terminal-links/detector";
import type { LinkFs, LinkFsStats } from "../../src/terminal-links/stat-cache";

type Kind = "file" | "dir";

const statsOf = (kind: Kind): LinkFsStats => ({
  isFile: () => kind === "file",
  isDirectory: () => kind === "dir",
  isSymbolicLink: () => false,
});

/**
 * A filesystem whose every call settles on a later macrotask, so nothing a
 * cache asks of it is answered before the asker has returned. Adding a file
 * adds its ancestors as directories.
 */
export class AsyncFs implements LinkFs {
  readonly nodes = new Map<string, Kind>();
  readonly lstats: string[] = [];
  readonly stats: string[] = [];
  private readonly holds = new Map<string, Array<() => void>>();
  private readonly held = new Set<string>();

  constructor(private readonly api: typeof posix = posix) {}

  add(abs: string, kind: Kind = "file"): this {
    this.nodes.set(abs, kind);
    let dir = this.api.dirname(abs);
    while (dir !== this.api.dirname(dir)) {
      this.nodes.set(dir, "dir");
      dir = this.api.dirname(dir);
    }
    return this;
  }

  remove(abs: string): void {
    this.nodes.delete(abs);
  }

  hold(abs: string): void {
    this.held.add(abs);
  }

  release(abs: string): void {
    this.held.delete(abs);
    for (const go of this.holds.get(abs) ?? []) go();
    this.holds.delete(abs);
  }

  get calls(): string[] {
    return [...this.lstats, ...this.stats];
  }

  private async hop(abs: string): Promise<void> {
    if (this.held.has(abs)) {
      await new Promise<void>((resolve) => {
        const list = this.holds.get(abs) ?? [];
        list.push(resolve);
        this.holds.set(abs, list);
      });
    }
    await new Promise<void>((resolve) => setImmediate(resolve));
  }

  async lstat(p: string): Promise<LinkFsStats> {
    this.lstats.push(p);
    await this.hop(p);
    const kind = this.nodes.get(p);
    if (!kind) throw new Error("ENOENT");
    return statsOf(kind);
  }

  async stat(p: string): Promise<LinkFsStats> {
    this.stats.push(p);
    await this.hop(p);
    const kind = this.nodes.get(p);
    if (!kind) throw new Error("ENOENT");
    return statsOf(kind);
  }

  async readlink(): Promise<string> {
    throw new Error("EINVAL");
  }
}

/** A clock and timer wheel the test advances by hand. */
export class Clock {
  time = 1_000_000;
  private timers: Array<{ at: number; fn: () => void; live: boolean }> = [];
  now = (): number => this.time;
  timer = (fn: () => void, ms: number): { cancel(): void } => {
    const t = { at: this.time + ms, fn, live: true };
    this.timers.push(t);
    return { cancel: () => void (t.live = false) };
  };
  advance(ms: number): void {
    this.time += ms;
    for (const t of [...this.timers]) {
      if (t.live && t.at <= this.time) {
        t.live = false;
        t.fn();
      }
    }
    this.timers = this.timers.filter((t) => t.live);
  }
}

/** Lets every pending fake-fs hop (one macrotask each) run to completion. */
export async function settle(ticks = 60): Promise<void> {
  for (let i = 0; i < ticks; i++) await new Promise<void>((resolve) => setImmediate(resolve));
}

function isWide(cp: number): boolean {
  return (
    (cp >= 0x1100 && cp <= 0x115f) ||
    (cp >= 0x2e80 && cp <= 0xa4cf) ||
    (cp >= 0xac00 && cp <= 0xd7a3) ||
    (cp >= 0xf900 && cp <= 0xfaff) ||
    (cp >= 0xff00 && cp <= 0xff60)
  );
}

export interface MkRowOptions {
  wrapped?: boolean;
  /** The last row of its logical line is cut at its last visible character. */
  last: boolean;
  /** Column to the program's own link on it. */
  explicit?: Record<number, string>;
}

/** One terminal row from printed text: a wide character takes two columns and
 *  contributes only its own char to `text`, exactly like the live adapter. */
export function mkRow(src: string, cols: number, o: MkRowOptions): DetectRow {
  let text = "";
  const colAt: number[] = [];
  const widthAt = new Uint8Array(cols);
  let col = 0;
  let endCol = 0;
  let keep = 0;
  const put = (ch: string, width: number): void => {
    for (let u = 0; u < ch.length; u++) colAt.push(col);
    text += ch;
    widthAt[col] = width;
    if (ch !== " ") {
      endCol = col + width;
      keep = text.length;
    }
    col += width;
  };
  for (const ch of src) put(ch, isWide(ch.codePointAt(0)!) ? 2 : 1);
  while (col < cols) put(" ", 1);
  const explicit: (string | undefined)[] = new Array<string | undefined>(cols).fill(undefined);
  for (const [c, uri] of Object.entries(o.explicit ?? {})) explicit[Number(c)] = uri;
  const cut = o.last ? keep : text.length;
  return {
    text: text.slice(0, cut),
    colAt: Int32Array.from(colAt.slice(0, cut)),
    widthAt,
    cols,
    wrapped: o.wrapped === true,
    endCol,
    explicit,
  };
}

export interface MkRowsOptions {
  /** Row indexes that continue the previous row (terminal soft wrap). */
  wrapped?: number[];
  /** Row index to column to uri. */
  explicit?: Record<number, Record<number, string>>;
}

export function mkRows(lines: readonly string[], cols: number, o: MkRowsOptions = {}): DetectRow[] {
  const wrapped = new Set(o.wrapped ?? []);
  return lines.map((src, i) =>
    mkRow(src, cols, { wrapped: wrapped.has(i), last: !wrapped.has(i + 1), explicit: o.explicit?.[i] }),
  );
}

export interface PathParams {
  p: string;
  b: string;
  k: string;
  n?: number;
  c?: number;
}

export function pathParams(uri: string): PathParams {
  const q = new URL(`x://h/${uri.slice(uri.indexOf("?"))}`).searchParams;
  const params: PathParams = { p: q.get("p")!, b: q.get("b")!, k: q.get("k")! };
  if (q.has("n")) params.n = Number(q.get("n"));
  if (q.has("c")) params.c = Number(q.get("c"));
  return params;
}
