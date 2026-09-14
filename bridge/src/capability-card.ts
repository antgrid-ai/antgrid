import os from "node:os";
import { runGitRemote } from "./git-branches";

/**
 * The machine half of the Capability Card (§3.3): what a human needs to
 * recognise a machine in the add-machine dialog before any agent runs on it.
 * Every field here is bridge-observed — nothing is asked of an agent (§3.4).
 */
export interface OsCard {
  name: string;
  version: string;
  arch: string;
}

/** The per-project half. `remote` is the normalized match key (§7.5), never the
 *  raw URL; `branch` is read fresh, so it is never stale by a checkout. */
export interface RepoCard {
  label?: string;
  remote: string | null;
  branch: string | null;
}

export interface CapabilityCard {
  os: OsCard;
  projects: Record<string, RepoCard>;
}

/** One project to probe, as the host's seen-projects catalog holds it. */
export interface CapabilityCardTarget {
  projectId: string;
  path: string;
  label?: string;
}

/** The most projects one card answers for. The explicit-id path enforces it in
 *  the request schema; the whole-catalog default slices to it. `seenProjects`
 *  only ever grows on a long-lived machine — nothing prunes an id whose path
 *  still exists — so an unbounded default would fan a git probe out over every
 *  project the install has ever opened. */
export const MAX_CAPABILITY_CARD_PROJECTS = 50;

/** How many projects are probed at once. Fixed width rather than "all of them":
 *  each project costs up to two `git` spawns, process creation is expensive on
 *  Windows, and this runs beside live PTY I/O — so the spawn count has to be
 *  independent of catalog size, or a big catalog starves the terminals and its
 *  own probes time out into a card that reports "no repo" for repos that have
 *  one. */
const PROBE_CONCURRENCY = 4;

/** A remote URL is near-immutable, but `git remote set-url` must take effect
 *  without a bridge restart. */
const REMOTE_CACHE_TTL_MS = 5 * 60_000;

/** A human is waiting on an open dialog, so the deadline is a UI deadline: a
 *  repo on a disconnected network share degrades to a blank field rather than
 *  hanging the card for every other project in the same request. */
const GIT_PROBE_TIMEOUT_MS = 5_000;

const DEFAULT_PORTS = new Set(["22", "80", "443"]);

/** Transports that can name the same repository from another machine. `file`
 *  is deliberately absent — see [normalizeRemoteUrl]. */
const REMOTE_SCHEMES = new Set(["ssh", "git", "http", "https", "git+ssh"]);

const remoteCache = new Map<string, { readAt: number; remote: string | null }>();

let cachedOsCard: OsCard | undefined;

function osName(platform: NodeJS.Platform): string {
  switch (platform) {
    case "win32": return "Windows";
    case "darwin": return "macOS";
    case "linux": return "Linux";
    default: return platform;
  }
}

/** Memoized: none of these change while the bridge runs. */
export function readOsCard(): OsCard {
  if (!cachedOsCard) {
    cachedOsCard = {
      name: osName(process.platform),
      // `os.version()` is the friendlier string where it has one (a Windows
      // edition name); it is a kernel build string on Linux. The fallback is
      // for a runtime that lacks it, not for a platform.
      version: os.version?.() || os.release(),
      arch: os.arch(),
    };
  }
  return cachedOsCard;
}

/**
 * The repo-identity key (`docs/session-messaging.md` §5.1): scheme-less,
 * credential-free, lowercase `host[:port]/path`, e.g. `github.com/owner/repo`.
 * `null` for anything that cannot identify the same repository from another
 * machine.
 *
 * Stripping userinfo is a security requirement, not tidiness: a remote can
 * embed a credential (`https://x-access-token:ghp_…@host/o/r.git`), and the
 * card leaves this machine and is rendered in a dialog, so an authority carried
 * verbatim would hand a token to another machine's app and to any screenshot of
 * it. Only the normalized form ever reaches the wire.
 *
 * Whole-key lowercasing is deliberate: this pre-selects a dropdown the user can
 * override, so matching `Owner/Repo` to `owner/repo` is worth more than the
 * case-sensitive-path edge it loses. It is a matching key and NEVER an
 * authorization input.
 */
export function normalizeRemoteUrl(raw: string): string | null {
  const trimmed = raw.trim();
  if (!trimmed) return null;

  // A drive letter is shaped exactly like an scp-like `host:path`, so it has to
  // be ruled out before that branch can claim it.
  if (/^[a-zA-Z]:[\\/]/.test(trimmed)) return null;
  // A filesystem remote names a path on THIS machine; a false match on it would
  // pre-select the wrong project on another one.
  if (/^[/\\.~]/.test(trimmed)) return null;

  const scheme = /^([a-zA-Z][a-zA-Z0-9+.-]*):\/\//.exec(trimmed);
  if (scheme) {
    if (!REMOTE_SCHEMES.has(scheme[1]!.toLowerCase())) return null;
    let url: URL;
    try {
      url = new URL(trimmed);
    } catch {
      return null;
    }
    // `url.username`/`url.password` are dropped here, and that is the strip.
    return buildKey(url.hostname, url.port, url.pathname);
  }

  const scp = /^(?:[^@/\\]+@)?([^:/\\]+):(.+)$/.exec(trimmed);
  if (scp) return buildKey(scp[1]!, "", scp[2]!);
  return null;
}

function buildKey(host: string, port: string, rawPath: string): string | null {
  const hostname = host.replace(/^\[|\]$/g, "");
  if (!hostname) return null;
  let path = rawPath.replace(/^[/:]+/, "").replace(/\/+$/, "");
  if (path.toLowerCase().endsWith(".git")) path = path.slice(0, -".git".length);
  path = path.replace(/\/+$/, "");
  if (!path) return null;
  const authority = port && !DEFAULT_PORTS.has(port) ? `${hostname}:${port}` : hostname;
  return `${authority}/${path}`.toLowerCase();
}

async function readBranch(projectPath: string): Promise<string | null> {
  try {
    const r = await runGitRemote(projectPath, ["rev-parse", "--abbrev-ref", "HEAD"], GIT_PROBE_TIMEOUT_MS);
    const name = r.stdout.trim();
    // `--abbrev-ref` answers the literal "HEAD" on a detached HEAD, which is
    // not a branch name — same reading as git-sync.ts.
    if (r.exitCode !== 0 || !name || name === "HEAD") return null;
    return name;
  } catch {
    // A path that no longer exists fails the spawn itself; a card with a blank
    // field beats no card for the rest of the machine's projects.
    return null;
  }
}

/**
 * The normalized repo key for a checkout, or null when it has none.
 *
 * Exported because the session-bus directory keys the addressable set on it
 * (`docs/session-messaging.md` §5.1) and must reach the SAME answer the
 * add-machine dialog does — two probes with two caches would let a project be
 * addressable in one surface and not the other, with nothing to point at.
 */
export async function readRepoKey(projectPath: string): Promise<string | null> {
  const cached = remoteCache.get(projectPath);
  if (cached && Date.now() - cached.readAt < REMOTE_CACHE_TTL_MS) return cached.remote;
  let remote: string | null = null;
  try {
    const r = await runGitRemote(projectPath, ["remote", "get-url", "origin"], GIT_PROBE_TIMEOUT_MS);
    if (r.exitCode === 0) remote = normalizeRemoteUrl(r.stdout.trim());
  } catch {
    remote = null;
  }
  remoteCache.set(projectPath, { readAt: Date.now(), remote });
  return remote;
}

/**
 * `branch` is read fresh on every call and `remote` is cached for
 * [REMOTE_CACHE_TTL_MS]. That split is the whole invalidation story: the card is
 * requested when a dialog opens, not on a timer, so reading the branch each time
 * costs one local `rev-parse` and removes the need to notice a checkout.
 */
export async function readRepoCard(projectPath: string, label?: string): Promise<RepoCard> {
  const [remote, branch] = await Promise.all([readRepoKey(projectPath), readBranch(projectPath)]);
  return label === undefined ? { remote, branch } : { label, remote, branch };
}

/** Probes the targets through a fixed-width pool: the dialog fills one dropdown
 *  from the whole machine, so the ROUND TRIP is what must stay single — the
 *  spawns behind it are bounded by [PROBE_CONCURRENCY] and the target list by
 *  [MAX_CAPABILITY_CARD_PROJECTS], both regardless of how many projects the
 *  caller named. */
export async function readCapabilityCard(targets: CapabilityCardTarget[]): Promise<CapabilityCard> {
  const bounded = targets.slice(0, MAX_CAPABILITY_CARD_PROJECTS);
  const projects: Record<string, RepoCard> = {};
  await inProbePool(bounded, async (t) => {
    projects[t.projectId] = await readRepoCard(t.path, t.label);
  });
  return { os: readOsCard(), projects };
}

/** Narrows `targets` to those whose `readRepoKey` is in `keys`, at the same
 *  cached cost and concurrency `readCapabilityCard` pays. Order-preserving, so
 *  a caller that builds rows off the result gets a stable answer across calls
 *  rather than one shuffled by which probe settled first. Meant to run AFTER a
 *  free, synchronous narrowing (a session-bearing filter): this is the one
 *  that can spawn git, so it should only ever be spent on a target the rest of
 *  the request could still use. */
export async function filterByRepoKeys(
  targets: readonly CapabilityCardTarget[],
  keys: readonly string[],
): Promise<CapabilityCardTarget[]> {
  const wanted = new Set(keys);
  const kept: (CapabilityCardTarget | undefined)[] = new Array(targets.length);
  await inProbePool(
    targets.map((target, index) => ({ target, index })),
    async ({ target, index }) => {
      const key = await readRepoKey(target.path);
      if (key !== null && wanted.has(key)) kept[index] = target;
    },
  );
  return kept.filter((t): t is CapabilityCardTarget => t !== undefined);
}

/** Runs `job` over `items` at most [PROBE_CONCURRENCY] at a time.
 *
 *  Its own function because the width is the whole point of it and is invisible
 *  from the card it produces — a run that spawned four probes and one that
 *  spawned four hundred return the same object, so only a direct caller can hold
 *  the bound. */
export async function inProbePool<T>(
  items: readonly T[],
  job: (item: T) => Promise<void>,
): Promise<void> {
  let next = 0;
  const worker = async (): Promise<void> => {
    while (next < items.length) await job(items[next++]!);
  };
  await Promise.all(Array.from({ length: Math.min(PROBE_CONCURRENCY, items.length) }, () => worker()));
}
