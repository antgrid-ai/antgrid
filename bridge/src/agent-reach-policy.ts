import { readFileSync } from "node:fs";
import { join } from "node:path";
import { atomicWriteFile } from "./discovery";

/**
 * Whether an agent on ANOTHER of this account's machines may see what is
 * running here and reach into it — E12, `docs/session-messaging.md`.
 *
 * Subordinate to the remote-access switch, never a replacement for it: this
 * store answers only the second question, and every call site consults it AFTER
 * `RemoteAccessPolicyStore.isEnabled()`. With remote access off, nothing here
 * can grant anything.
 *
 * It exists because the two bits do not make the same promise. Remote access
 * says *my other devices may drive this machine*, with a human at the far end of
 * every frame. This one says *a program on another of my machines may read what
 * I am working on and interrupt me about it, with nobody watching* — and it
 * gates both halves of that together, because an agent allowed to message a
 * session it may not see would be a stranger shape than either.
 *
 * Defaults ON. The objection to a second switch was discovery — a second thing
 * off by default that a user must find before the feature works at all — and
 * the default is what answers it: turning remote access on still works end to
 * end, and this bit exists for the user who wants devices-yes / agents-no.
 *
 * No watcher on the backing file, for the reason `remote-access-policy.ts`
 * has none: the bridge is its only writer and every mutation arrives through
 * the loopback `agent-reach:set` verb.
 */
export interface AgentReachPolicyStore {
  isEnabled(): boolean;
  /** True if the value changed. Unlike `RemoteAccessPolicyStore`'s, nothing
   *  branches on it: flipping this bit claws nothing back by design (E12), so
   *  there is no re-advertise or mirror clear for a no-op to skip. It is
   *  reported because "set to what it already was" and "set to something new"
   *  are different facts, not because a caller acts on the difference. */
  setEnabled(enabled: boolean): boolean;
}

interface FileShape {
  version: 1;
  enabled: boolean;
}

export const AGENT_REACH_DEFAULT = true;

export function loadAgentReachPolicy(abDir: string): AgentReachPolicyStore {
  const path = join(abDir, "agents", "agent-reach-policy.json");
  let enabled = readStored(path);

  return {
    isEnabled: () => enabled,
    setEnabled: (next) => {
      if (next === enabled) return false;
      // Persist before flipping memory, for the reason the remote-access store
      // does: a failed write must not leave the gate reading one way here and
      // the other way on disk, where the next restart silently restores it.
      atomicWriteFile(path, JSON.stringify({ version: 1, enabled: next } satisfies FileShape, null, 2), {
        fileMode: 0o600,
      });
      enabled = next;
      return true;
    },
  };
}

/**
 * Absent and unreadable are DIFFERENT answers here, and the difference is
 * deliberate.
 *
 * Absent means nobody has ever set this, so the value is the default the user
 * was promised — on. Unreadable means a value exists that we cannot see, and
 * guessing "on" would re-grant something the user may have turned off. Nothing
 * is written back either way: a `false` we invented would outlive the corruption
 * that produced it, and a clean read later still recovers the real value.
 *
 * There is no v0 to migrate from — the switch has never had another shape — so
 * unlike `remote-access-policy.ts` this needs no absence re-check: a missing
 * file routes to a default, not to a derivation that would be persisted.
 *
 * Absence is decided by the read that fails, never by a separate `existsSync`:
 * between such a check and the read sits the rename `atomicWriteFile` finishes
 * with, and a file that vanished for that instant is not a file nobody has
 * written — reading it as the default would be the one direction that re-grants
 * something the user turned off.
 */
function readStored(path: string): boolean {
  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch (err) {
    return (err as NodeJS.ErrnoException)?.code === "ENOENT" ? AGENT_REACH_DEFAULT : false;
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return false;
  }
  if (typeof parsed !== "object" || parsed === null) return false;
  const { version, enabled } = parsed as Partial<FileShape>;
  // An unknown version is a newer build's file under a rollback — its `enabled`
  // may not mean what this build thinks it does, so it is unreadable, not older.
  if (version !== 1 || typeof enabled !== "boolean") return false;
  return enabled;
}
