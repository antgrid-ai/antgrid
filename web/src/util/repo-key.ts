/**
 * Shape gate for a `repoKey` arriving from a bridge.
 *
 * Validator only: normalization needs a Git remote and belongs on the machine
 * that has one. Keep in lockstep with `bridge/src/repo-key.ts` — the bridge
 * produces these and web stores them in a unique index, so a rule only one side
 * knows is a route that rejects its own bridge's projects. Deliberately
 * duplicated rather than shared: hoisting it into `packages/antgrid-wire` would
 * relicense it from ELv2 to Apache-2.0, and that direction is one-way (see
 * LICENSING.md).
 */

const MAX_LENGTH = 512;

const HOST = /^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/;
const SEGMENT = /^[a-z0-9._-]+$/;

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
