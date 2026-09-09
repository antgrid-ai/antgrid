/**
 * Repository identity: the one string that says "these two checkouts are the
 * same repo" across machines, so a task follows a repository rather than a
 * folder. Derived from the origin remote and deliberately lossy — every way of
 * cloning one repository must fold to a single key.
 *
 * A remote URL is attacker-influencable (it is whatever a cloned repo's config
 * says) and the key it produces crosses the wire to web, lands in a unique
 * index, and is matched against provider repo names. So this is a strict
 * allowlist that answers `null` for anything it cannot fold confidently —
 * callers turn that into a synthetic per-machine key, never into a guess.
 */

// Bounds the key before it reaches a column or a match path rather than at each
// of them.
const MAX_LENGTH = 512;

const HOST = /^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/;
const SEGMENT = /^[a-z0-9._-]+$/;

/** `null` for any remote that does not name a shareable repository. */
export function normalizeRepoKey(remoteUrl: string | null | undefined): string | null {
  if (!remoteUrl) return null;
  const trimmed = remoteUrl.trim();
  if (!trimmed || trimmed.length > MAX_LENGTH) return null;

  const split = splitRemote(trimmed);
  if (!split) return null;

  const host = split.host.toLowerCase();
  if (!HOST.test(host)) return null;

  // Owner and name are lowercased with the host: GitHub treats them
  // case-insensitively, and two keys differing only in case would be two
  // projects holding one repository's tasks.
  const segments = split.path.toLowerCase().split("/").filter((s) => s.length > 0);
  // The FULL path is kept, not the last two segments — GitLab subgroups are
  // real, and collapsing them would merge distinct repositories into one key.
  if (segments.length < 2) return null;

  const name = segments[segments.length - 1]!.replace(/\.git$/, "");
  if (!name) return null;
  segments[segments.length - 1] = name;
  if (segments.some((s) => s === "." || s === ".." || !SEGMENT.test(s))) return null;

  const key = `${host}/${segments.join("/")}`;
  return key.length > MAX_LENGTH ? null : key;
}

/**
 * Identity for a project whose origin cannot be folded — no remote, a local
 * path remote, or a URL this refuses. Tasks still bind, but to this folder on
 * this machine only: the key names a device, so it can never match a provider
 * repo and never gains an integration link.
 */
export function syntheticRepoKey(deviceId: string, localProjectId: string): string {
  return `local:${deviceId}/${localProjectId}`;
}

/**
 * Shape gate for a repoKey arriving from somewhere else. Keep in lockstep with
 * web's copy in `web/src/util/repo-key.ts` — the bridge produces these and web
 * stores them, so a rule only one side knows is a route that rejects its own
 * bridge's projects. Deliberately duplicated rather than shared: hoisting it
 * into a package would relicense it (see LICENSING.md).
 */
export function isValidRepoKey(value: string): boolean {
  if (!value || value.length > MAX_LENGTH) return false;
  const local = value.startsWith("local:") ? value.slice("local:".length) : null;
  if (local !== null) {
    const parts = local.split("/");
    return parts.length === 2 && parts.every((p) => p !== "." && p !== ".." && SEGMENT.test(p));
  }
  const parts = value.split("/");
  if (parts.length < 3) return false;
  const [host, ...path] = parts;
  return HOST.test(host!) && path.every((p) => p !== "." && p !== ".." && SEGMENT.test(p));
}

function splitRemote(url: string): { host: string; path: string } | null {
  const scheme = /^([a-z][a-z0-9+.-]*):\/\//i.exec(url);
  if (scheme) {
    // `file://` names a directory on one machine, so it is not an identity two
    // machines can share.
    if (scheme[1]!.toLowerCase() === "file") return null;
    const rest = url.slice(scheme[0]!.length);
    const slash = rest.indexOf("/");
    if (slash <= 0) return null;
    return { host: stripUserAndPort(rest.slice(0, slash)), path: rest.slice(slash + 1) };
  }

  // scp-like `[user@]host:path`, which Git recognizes by a colon appearing
  // before any slash.
  const colon = url.indexOf(":");
  if (colon <= 0) return null;
  const slash = url.indexOf("/");
  if (slash >= 0 && slash < colon) return null;
  const authority = url.slice(0, colon);
  // A Windows drive letter is a local path, not a host.
  if (authority.length === 1) return null;
  return { host: stripUserAndPort(authority), path: url.slice(colon + 1) };
}

function stripUserAndPort(authority: string): string {
  const at = authority.lastIndexOf("@");
  const host = at >= 0 ? authority.slice(at + 1) : authority;
  // The port is dropped on purpose: the same repository cloned over ssh on 2222
  // and https on 443 has to be one key, which is the entire point of folding.
  const colon = host.indexOf(":");
  return colon >= 0 ? host.slice(0, colon) : host;
}
