import { existsSync, readFileSync, watch as fsWatch, type FSWatcher } from "node:fs";
import { dirname } from "node:path";
import { parse as parseYaml, stringify as stringifyYaml } from "yaml";
import { AbConfigSchema, type AbConfig, formatZodIssues } from "./config";
import { atomicWriteFile } from "./discovery";
import { logger } from "./logger";

export type ReadResult =
  | { ok: true; config: AbConfig }
  | { ok: false; missing: true; raw?: undefined; error?: undefined }
  | { ok: false; missing: false; raw: string; error: string };

export type WriteResult = { ok: true } | { ok: false; errors: string[] };

export class ConfigController {
  constructor(private readonly filePath: string) {}

  read(): ReadResult {
    if (!existsSync(this.filePath)) return { ok: false, missing: true };
    const raw = readFileSync(this.filePath, "utf8");
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
  private lastConfig: AbConfig = {};

  watch(onChange: (next: ReadResult, diff: ConfigDiff) => void): void {
    this.watcher?.close();
    let debounce: ReturnType<typeof setTimeout> | null = null;
    const trigger = () => {
      if (debounce) clearTimeout(debounce);
      debounce = setTimeout(() => {
        const r = this.read();
        const next = r.ok ? r.config : ({} as AbConfig);
        const diff = computeDiff(this.lastConfig, next);
        if (r.ok) this.lastConfig = next;
        onChange(r, diff);
      }, 100);
    };
    try {
      this.watcher = fsWatch(this.filePath, trigger);
    } catch {
      // file may not exist yet — also watch the parent dir
      this.watcher = fsWatch(dirname(this.filePath), (_event, name) => {
        if (typeof name === "string" && name.endsWith("antgrid.yaml")) trigger();
      });
    }
    // FSWatcher emits async 'error' events (EPERM/ENOENT on Windows when the
    // watched path is locked or removed at runtime); with no handler Node
    // rethrows them as an uncaught exception. Swallow-and-log, mirroring the
    // chokidar FileWatcher's error handling.
    this.watcher.on("error", (err) => logger.error("Config watcher error: %s", err));
    // seed lastConfig from current file
    const r0 = this.read();
    if (r0.ok) this.lastConfig = r0.config;
  }

  stopWatch(): void {
    this.watcher?.close();
    this.watcher = null;
  }
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
