import { existsSync, readFileSync, watch as fsWatch, type FSWatcher } from "node:fs";
import { basename, dirname } from "node:path";
import { parse as parseYaml, stringify as stringifyYaml } from "yaml";
import { AbConfigSchema, type AbConfig, formatZodIssues } from "./config";
import { atomicWriteFile } from "./discovery";
import { logger } from "./logger";
const log = logger.child({ component: "config-controller" });

export type ReadResult =
  | { ok: true; config: AbConfig }
  | { ok: false; missing: true; raw?: undefined; error?: undefined }
  | { ok: false; missing: false; raw: string; error: string };

export type WriteResult = { ok: true } | { ok: false; errors: string[] };

export class ConfigController {
  constructor(private readonly filePath: string) {}

  read(): ReadResult {
    if (!existsSync(this.filePath)) return { ok: false, missing: true };
    let raw: string;
    try {
      raw = readFileSync(this.filePath, "utf8");
    } catch {
      // Gone between the stat and the read — the ordinary race when the
      // checkout under it is being deleted. This runs from a bare `setTimeout`
      // in [watch], where a throw is an uncaught exception on the bridge's main
      // loop, so an absence discovered here must answer like any other.
      return { ok: false, missing: true };
    }
    let parsed: unknown;
    try {
      parsed = parseYaml(raw);
    } catch (err) {
      return {
        ok: false,
        missing: false,
        raw,
        error: err instanceof Error ? err.message : String(err),
      };
    }
    if (parsed === null || parsed === undefined) {
      return { ok: true, config: {} as AbConfig };
    }
    const result = AbConfigSchema.safeParse(parsed);
    if (!result.success) {
      const errors = formatZodIssues(result.error.issues).join(", ");
      return { ok: false, missing: false, raw, error: errors };
    }
    return { ok: true, config: result.data as AbConfig };
  }

  write(config: AbConfig): WriteResult {
    const result = AbConfigSchema.safeParse(config);
    if (!result.success) {
      return { ok: false, errors: formatZodIssues(result.error.issues) };
    }
    atomicWriteFile(this.filePath, stringifyYaml(result.data));
    return { ok: true };
  }

  private watcher: FSWatcher | null = null;
  /** On the instance rather than in [watch]'s closure so [stopWatch] can clear
   *  it. A debounced read fires up to 100ms after the watcher closes and reads
   *  the watched file — which for a managed checkout sits inside the directory
   *  `git worktree remove` is by then sweeping. */
  private debounce: ReturnType<typeof setTimeout> | null = null;
  private lastConfig: AbConfig = {};

  watch(onChange: (next: ReadResult, diff: ConfigDiff) => void): void {
    this.watcher?.close();
    const trigger = () => {
      if (this.debounce) clearTimeout(this.debounce);
      this.debounce = setTimeout(() => {
        const r = this.read();
        const next = r.ok ? r.config : ({} as AbConfig);
        const diff = computeDiff(this.lastConfig, next);
        if (r.ok) this.lastConfig = next;
        onChange(r, diff);
      }, 100);
    };
    const fileName = basename(this.filePath).toLowerCase();
    // The DIRECTORY, never the file: [write] publishes by rename, and an inotify
    // watch is keyed to the inode it was armed on — so on Linux the first save
    // orphans a file-path watch and every later one is invisible for the life of
    // the process (measured on Node and on Bun, on two filesystems). Watching
    // the parent also covers the file not existing yet.
    this.watcher = fsWatch(dirname(this.filePath), (_event, name) => {
      if (namesConfig(name, fileName)) trigger();
    });
    // FSWatcher emits async 'error' events (EPERM/ENOENT on Windows when the
    // watched path is locked or removed at runtime); with no handler Node
    // rethrows them as an uncaught exception. Swallow-and-log, mirroring the
    // chokidar FileWatcher's error handling.
    this.watcher.on("error", (err) => log.error("Config watcher error: %s", err));
    // seed lastConfig from current file
    const r0 = this.read();
    if (r0.ok) this.lastConfig = r0.config;
  }

  stopWatch(): void {
    this.watcher?.close();
    this.watcher = null;
    if (this.debounce) clearTimeout(this.debounce);
    this.debounce = null;
  }
}

/** Whether a directory-watch event is about our config file. It over-accepts in
 *  three deliberate ways, because a spurious hit costs one debounced re-read of a
 *  fixed path while a dropped one is the silent deafness [ConfigController.watch]
 *  exists to fix:
 *
 *  - Case-insensitively, on every platform. antgrid.yaml is USER-authored, so a
 *    repo may carry `Antgrid.yaml`, and every other access to it (existsSync,
 *    readFileSync, the rename in atomicWriteFile) resolves case-insensitively on
 *    Windows and macOS. An exact compare would find the file, seed from it, serve
 *    reads off it — and then ignore every save to it for the life of the process.
 *  - The `<name>.<pid>.tmp` scratch atomicWriteFile renames from. Windows reports
 *    ONLY the scratch name when the rename target does not yet exist, so dropping
 *    it makes a config file's first creation unobservable — and `config:write`
 *    applies nothing itself, so that config would never take effect at all.
 *    Within a save the 100ms debounce coalesces it with the target's own event.
 *  - A nameless event (inotify IN_ATTRIB on the directory itself), which carries
 *    nothing to filter on. */
function namesConfig(name: string | Buffer | null, fileName: string): boolean {
  if (!name) return true;
  const n = name.toString().toLowerCase();
  return n === fileName || (n.startsWith(`${fileName}.`) && n.endsWith(".tmp"));
}

export interface ConfigDiff {
  agentRestartRequired: boolean;
  servicesAdded: Array<{ name: string; command: string }>;
  servicesRemoved: string[];
  servicesModified: Array<{ name: string; command: string }>;
}

function eq(a: unknown, b: unknown): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}

export function computeDiff(prev: AbConfig, next: AbConfig): ConfigDiff {
  const agentRestartRequired = !eq(prev.agent ?? {}, next.agent ?? {});

  const prevServices = new Map((prev.services ?? []).map((s) => [s.name, s] as const));
  const nextServices = new Map((next.services ?? []).map((s) => [s.name, s] as const));

  const servicesAdded: ConfigDiff["servicesAdded"] = [];
  const servicesModified: ConfigDiff["servicesModified"] = [];
  for (const [name, svc] of nextServices) {
    const prior = prevServices.get(name);
    if (!prior) servicesAdded.push({ name, command: svc.command });
    else if (!eq(prior, svc)) servicesModified.push({ name, command: svc.command });
  }
  const servicesRemoved = [...prevServices.keys()].filter((n) => !nextServices.has(n));

  return { agentRestartRequired, servicesAdded, servicesRemoved, servicesModified };
}
