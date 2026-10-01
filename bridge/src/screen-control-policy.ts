import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { logger } from "./logger";

const log = logger.child({ component: "screen-control-policy" });

/** Whether a remote device may watch this machine's screen and drive its input
 *  — one boolean for the whole machine, deliberately its own switch rather than
 *  a facet of remote access: remote *terminal* control must not imply remote
 *  *screen* control. Same stance on the backing file as
 *  {@link ./remote-access-policy}: the bridge is its only writer and every
 *  mutation arrives over loopback, so there is no watcher and an out-of-band
 *  edit is not a supported input.
 *
 *  Per-frame gating cannot enforce this switch on its own. Remote input rides a
 *  WebRTC datachannel that never reaches the bridge, so revocation has to be
 *  pushed at whoever holds the peer connection: {@link onRevoked} subscribers
 *  run synchronously inside `setEnabled(false)` and are the actual kill switch,
 *  not a courtesy layered over one. */
export interface ScreenControlPolicyStore {
  isEnabled(): boolean;
  /** Returns true if the value changed — callers use it to skip the
   *  re-advertise a no-op set doesn't warrant. Teardown hooks are independent of
   *  that: they run on every `false`. */
  setEnabled(enabled: boolean): boolean;
  /** Register a teardown to run the instant the switch goes off; returns an
   *  unsubscribe. */
  onRevoked(fn: () => void): () => void;
}

interface FileShape {
  version: 1;
  enabled: boolean;
}

export function loadScreenControlPolicy(abDir: string): ScreenControlPolicyStore {
  const dir = join(abDir, "agents");
  const path = join(dir, "screen-control-policy.json");

  // Unlike remote access there is no v1 state to derive from, so an absent file
  // says exactly what a fresh install means — off — and nothing needs writing
  // until the user turns the switch on. Unreadable bytes are left alone for the
  // same reason they are there: `writeFileSync` truncates before it writes, so a
  // load racing a flush can read a torn file, and persisting the fail-closed
  // reading would turn a transient race into a permanent revocation.
  const stored = readStored(path);
  let enabled = stored.kind === "v1" && stored.enabled;
  const teardowns = new Set<() => void>();

  function flush() {
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    const data: FileShape = { version: 1, enabled };
    writeFileSync(path, JSON.stringify(data, null, 2));
    if (process.platform !== "win32") chmodSync(path, 0o600);
  }

  function revoke() {
    // Snapshot, so a hook that unsubscribes itself as it tears down doesn't
    // mutate the set mid-iteration; and swallow throws, because every other
    // subscriber still holding a live session must be reached regardless.
    for (const fn of [...teardowns]) {
      try {
        fn();
      } catch (err) {
        log.error({ err }, "screen-control teardown hook threw");
      }
    }
  }

  return {
    isEnabled: () => enabled,
    setEnabled: (next) => {
      const changed = next !== enabled;
      enabled = next;
      // Tear down before the flush, and on every `false` rather than only on a
      // change: the capability lives in a peer connection the bridge cannot see,
      // so neither a failing disk nor a redundant off may be the reason a remote
      // peer keeps input.
      if (!next) revoke();
      if (changed) flush();
      return changed;
    },
    onRevoked: (fn) => {
      teardowns.add(fn);
      return () => {
        teardowns.delete(fn);
      };
    },
  };
}

/** What the backing file holds. `absent` is an unambiguous state — a machine
 *  nobody has enabled — whereas `unreadable` means the real value is unknown. */
type StoredPolicy =
  | { kind: "v1"; enabled: boolean }
  | { kind: "absent" }
  | { kind: "unreadable" };

function readStored(path: string): StoredPolicy {
  if (!existsSync(path)) return { kind: "absent" };
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return { kind: "unreadable" };
  }
  if (typeof parsed !== "object" || parsed === null) return { kind: "unreadable" };
  const { version, enabled } = parsed as Partial<FileShape>;
  // An unknown version (a newer build wrote it, then the user rolled back) is
  // unknown, not off — the same reason a v1 file with a non-boolean `enabled` is
  // corrupt rather than absent.
  if (version !== 1) return { kind: "unreadable" };
  return typeof enabled === "boolean" ? { kind: "v1", enabled } : { kind: "unreadable" };
}
