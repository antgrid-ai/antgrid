import { readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// Proactive "a newer codex CLI exists" detection for chat mode.
//
// This answers only "a newer codex exists" — NOT "my selected model needs a
// newer codex" (codex exposes no per-model minimum version; only the backend
// knows, and only at turn time as a 400). So this is an advisory signal: surface
// it as a dismissible chip, never a modal. The precise, actionable case is the
// reactive turn-error path. See docs / the update-available design discussion.
//
// Everything here is fail-soft: a failed probe or offline registry yields "no
// update" (null), never an exception — proactive detection must not perturb
// chat-session start.

// npm dist-tags.latest is the authority for "latest". We pin to /latest so
// prerelease tags (alpha/beta) can never be surfaced as an upgrade.
const NPM_REGISTRY = "https://registry.npmjs.org";

// Pull the semver token out of `codex --version` ("codex-cli 0.142.2"). Keeps a
// prerelease suffix if one is present so the raw string round-trips; comparison
// (coreLt) strips it.
export function parseCodexVersion(stdout: string): string | null {
  const m = stdout.match(/(\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?)/);
  return m ? m[1] : null;
}

// True iff a's semver CORE is strictly below b's. Prerelease suffixes are
// ignored (split on "-"), so 0.145.0-alpha.4 and 0.145.0 compare equal — we
// never nudge a user from a release toward a prerelease of the same core.
export function coreLt(a: string, b: string): boolean {
  const core = (v: string) => v.split("-")[0].split(".").map((n) => Number(n) || 0);
  const pa = core(a);
  const pb = core(b);
  for (let i = 0; i < 3; i++) {
    const x = pa[i] ?? 0;
    const y = pb[i] ?? 0;
    if (x !== y) return x < y;
  }
  return false;
}

// Notify only when installed is behind latest AND that exact latest wasn't
// dismissed. A genuinely newer release (latest > dismissed) re-surfaces.
export function shouldNotify(installed: string, latest: string | null, dismissed: string | null): boolean {
  if (!latest) return false;
  if (!coreLt(installed, latest)) return false;
  return latest !== dismissed;
}

// GET <registry>/<package>/latest and read `.version` — the single npm probe
// for every tool. Scoped names (@anthropic-ai/claude-code) keep their `/`
// unencoded: the registry serves `/@scope/name/latest` literally. Fail-soft:
// any network/parse/status error resolves to null. `fetchFn` injectable for tests.
export async function fetchNpmLatest(
  npmPackage: string,
  fetchFn: typeof fetch = fetch,
): Promise<string | null> {
  try {
    const res = await fetchFn(`${NPM_REGISTRY}/${npmPackage}/latest`, {
      headers: { accept: "application/json" },
    });
    if (!res.ok) return null;
    const body = (await res.json()) as { version?: unknown };
    return typeof body.version === "string" ? body.version : null;
  } catch {
    return null;
  }
}

export interface LatestCacheEntry {
  version: string;
  at: number;
}

export interface ResolveLatestDeps {
  fetchLatest: () => Promise<string | null>;
  readCache: () => LatestCacheEntry | null;
  writeCache: (e: LatestCacheEntry) => void;
  now: () => number;
  ttlMs: number;
}

// The authoritative "latest" with a TTL cache in front of the network. A fresh
// cache short-circuits the fetch entirely; a stale/absent cache triggers a
// fetch. On fetch failure we fall back to whatever cached value exists (a stale
// answer beats no chip) and only return null when there's nothing at all.
export async function resolveLatest(deps: ResolveLatestDeps): Promise<string | null> {
  const cached = deps.readCache();
  if (cached && deps.now() - cached.at < deps.ttlMs) return cached.version;

  const fetched = await deps.fetchLatest();
  if (fetched) {
    deps.writeCache({ version: fetched, at: deps.now() });
    return fetched;
  }
  return cached?.version ?? null;
}

export interface CheckCodexUpdateDeps {
  // Runs `codex --version` on the exact binary the bridge will spawn and returns
  // its stdout. May reject — checkCodexUpdate swallows it.
  execVersion: () => Promise<string>;
  resolveLatest: () => Promise<string | null>;
  // The version the user has already dismissed (e.g. codex's own
  // version.json.dismissed_version, or our persisted value), or null.
  dismissed: string | null;
}

// Orchestrates: installed (spawned binary) vs latest (cached npm) vs dismissed.
// Returns the emit payload when an update should be surfaced, else null. Never
// throws — a failed probe is "no update".
export async function checkCodexUpdate(
  deps: CheckCodexUpdateDeps,
): Promise<{ installed: string; latest: string } | null> {
  let installed: string | null;
  try {
    installed = parseCodexVersion(await deps.execVersion());
  } catch {
    return null;
  }
  if (!installed) return null;

  const latest = await deps.resolveLatest();
  if (!shouldNotify(installed, latest, deps.dismissed)) return null;
  return { installed, latest: latest as string };
}

// Default TTL between authoritative npm checks. The registry answer changes on
// the order of days; 12h keeps the chip fresh without hammering npm on every
// chat-session start.
const DEFAULT_TTL_MS = 12 * 60 * 60 * 1000;

export interface CodexHomeState {
  latest_version?: string;
  dismissed_version?: string | null;
}

export interface CodexUpdateCheckerOpts {
  execVersion: () => Promise<string>;
  // codex's own updater state (~/.codex/version.json): a free `latest_version`
  // warm hint (used offline) and the `dismissed_version` to honor.
  readState?: () => CodexHomeState | null;
  fetchLatest?: () => Promise<string | null>;
  now?: () => number;
  ttlMs?: number;
}

// Build a project-scoped checker that shares one latest-version cache across all
// of that project's codex chat sessions. Concurrent session starts collapse
// onto a single in-flight npm fetch; subsequent starts reuse the TTL cache. The
// returned function never throws.
export function createCodexUpdateChecker(
  opts: CodexUpdateCheckerOpts,
): () => Promise<{ installed: string; latest: string } | null> {
  const now = opts.now ?? Date.now;
  const ttlMs = opts.ttlMs ?? DEFAULT_TTL_MS;
  const fetchLatest = opts.fetchLatest ?? (() => fetchNpmLatest("@openai/codex"));
  let cache: LatestCacheEntry | null = null;
  let inflight: Promise<string | null> | null = null;
  let warmed = false;

  return async () => {
    const state = (opts.readState ?? (() => null))();
    // Seed the cache from codex's own updater state exactly once, marked stale
    // (at:0) so it acts as an offline fallback, not a substitute for the real
    // npm check.
    if (!warmed) {
      warmed = true;
      if (state?.latest_version) cache = { version: state.latest_version, at: 0 };
    }
    return checkCodexUpdate({
      execVersion: opts.execVersion,
      resolveLatest: () =>
        resolveLatest({
          fetchLatest: () => (inflight ??= fetchLatest().finally(() => { inflight = null; })),
          readCache: () => cache,
          writeCache: (e) => { cache = e; },
          now,
          ttlMs,
        }),
      dismissed: state?.dismissed_version ?? null,
    });
  };
}

// ---- real-environment adapters (thin glue; the logic above is unit-tested) ----

// Resolve `~/.codex` (or $CODEX_HOME) — where codex keeps version.json.
export function codexHomeDir(env: Record<string, string | undefined> = process.env): string {
  return env.CODEX_HOME ?? join(homedir(), ".codex");
}

// Read codex's updater state file. Fail-soft: missing/garbage -> null.
export function readCodexVersionJson(codexHome: string): CodexHomeState | null {
  try {
    const j = JSON.parse(readFileSync(join(codexHome, "version.json"), "utf8")) as Record<string, unknown>;
    return {
      latest_version: typeof j.latest_version === "string" ? j.latest_version : undefined,
      dismissed_version: typeof j.dismissed_version === "string" ? j.dismissed_version : null,
    };
  } catch {
    return null;
  }
}

// Resolve the exact on-disk binary the bridge would spawn: PATH shim ->
// realpath, so a multi-install PATH can't make us target the wrong one. Falls
// back to the bare command name. The single resolver: spawn-codex spawns with
// it and agent-update probes/updates with it, so version-probe and spawn can
// never diverge onto different installs.
export function resolveToolLaunchPath(command: string, path?: string): string {
  const onPath = Bun.which(command, path ? { PATH: path } : undefined);
  if (!onPath) return command;
  try { return realpathSync.native(onPath); } catch { return onPath; }
}

// ---- in-app `codex update` orchestration ----

export interface CodexUpdateDeps {
  // The live codex chat sessions to quiesce before, and restart after, the
  // update. `codex update` replaces the on-disk binary, which (on Windows) fails
  // while any codex process still holds it — so every one of these must fully
  // exit first. The update itself is machine-global; one run covers them all.
  sessionIds: string[];
  // Tear down one session's codex process. MUST resolve only once the process
  // has exited (releasing the exe handle + codex's ~/.codex sqlite lock).
  stop: (sessionId: string) => Promise<void>;
  // Respawn one session's codex on the fresh binary. May throw/reject — swallowed.
  start: (sessionId: string) => Promise<void> | void;
  // Run `codex update`; resolves with the process exit code and combined output.
  execUpdate: () => Promise<{ exitCode: number; output: string }>;
  // Re-read the installed version after the update, fail-soft to null.
  installedAfter: () => Promise<string | null>;
}

export interface CodexUpdateOutcome {
  ok: boolean;
  exitCode: number;
  output: string;
  installed: string | null;
}

// Orchestrate an in-app `codex update`: quiesce the live codex sessions (freeing
// the binary), run the update once, then ALWAYS restart what we stopped — even
// when the update fails — so a user's chat is never left dead. Never throws; a
// failure surfaces as ok:false with the captured output.
export async function runCodexUpdate(deps: CodexUpdateDeps): Promise<CodexUpdateOutcome> {
  // Wait every process fully out before touching the binary. A failed stop is
  // swallowed: a stuck session must not block the update, and its restart below
  // still runs.
  await Promise.all(
    deps.sessionIds.map((id) => Promise.resolve(deps.stop(id)).catch(() => {})),
  );

  let exitCode = 1;
  let output = "";
  try {
    const r = await deps.execUpdate();
    exitCode = r.exitCode;
    output = r.output;
  } catch (err) {
    output = err instanceof Error ? err.message : String(err);
  } finally {
    // Restart one at a time: a fresh codex spawn re-acquires the ~/.codex lock,
    // so don't kick them all off at once. This only serializes as far as `start`
    // resolves — a start that returns before its codex is fully up (the current
    // SessionManager.start is fire-and-forget) can't be fully ordered here; in
    // practice codex allows one app-server per CODEX_HOME, so there's ≤1 to
    // restart. Each is fail-soft on its own.
    for (const id of deps.sessionIds) {
      try { await deps.start(id); } catch { /* one dead restart must not sink the rest */ }
    }
  }

  const installed = await deps.installedAfter().catch(() => null);
  return { ok: exitCode === 0, exitCode, output, installed };
}
