import { test, expect, beforeEach, afterEach } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadMobileAccessPolicy } from "../src/mobile-access-policy";

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "antgrid-mobile-access-"));
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

const policyPath = () => join(dir, "agents", "mobile-access-policy.json");
const phonesPath = () => join(dir, "agents", "paired-phones.json");

function seedAgents() {
  mkdirSync(join(dir, "agents"), { recursive: true });
}

/** A v1 policy file, the per-project opt-in list this store replaced. */
function seedV1Policy(sameAccountDefaultProjects: string[]) {
  seedAgents();
  writeFileSync(policyPath(), JSON.stringify({ version: 1, sameAccountDefaultProjects }, null, 2));
}

/** A v1 paired-phones file: `allowedProjects` was the OTHER half of the old
 *  two-axis authorization, and the only record of a grant made through
 *  `antgrid phones allow`. */
function seedPhones(allowedProjects: string[][]) {
  seedAgents();
  writeFileSync(
    phonesPath(),
    JSON.stringify(
      {
        version: 1,
        phones: allowedProjects.map((allowed, i) => ({
          phonePubkey: `pk${i}`,
          phoneDeviceId: `d${i}`,
          pairedAt: "2026-01-01T00:00:00.000Z",
          lastSeenAt: "2026-01-01T00:00:00.000Z",
          allowedProjects: allowed,
        })),
      },
      null,
      2,
    ),
  );
}

function readPolicyFile(): { version?: number; enabled?: boolean } {
  return JSON.parse(readFileSync(policyPath(), "utf8")) as { version?: number; enabled?: boolean };
}

test("a fresh machine is not mobile-reachable until the user says so", () => {
  expect(loadMobileAccessPolicy(dir).isEnabled()).toBe(false);
});

test("setEnabled reports whether it changed and persists across a reload", () => {
  const store = loadMobileAccessPolicy(dir);
  expect(store.setEnabled(true)).toBe(true);
  expect(store.setEnabled(true)).toBe(false);
  expect(store.isEnabled()).toBe(true);

  expect(loadMobileAccessPolicy(dir).isEnabled()).toBe(true);

  expect(store.setEnabled(false)).toBe(true);
  expect(loadMobileAccessPolicy(dir).isEnabled()).toBe(false);
});

// --- v1 → v2 migration matrix ------------------------------------------------
// The upgrade must not silently revoke access a user already granted, and must
// not grant access they never did.

test("migration: no v1 stores at all → off", () => {
  expect(loadMobileAccessPolicy(dir).isEnabled()).toBe(false);
});

test("migration: a v1 per-project opt-in → on", () => {
  seedV1Policy(["projA"]);
  expect(loadMobileAccessPolicy(dir).isEnabled()).toBe(true);
});

test("migration: an empty v1 opt-in but a phone holding a grant → on", () => {
  // The `antgrid phones allow` user, who never touched the desktop toggle.
  seedV1Policy([]);
  seedPhones([[], ["projA"]]);
  expect(loadMobileAccessPolicy(dir).isEnabled()).toBe(true);
});

test("migration: an empty v1 opt-in and no phone grants → off", () => {
  seedV1Policy([]);
  seedPhones([[], []]);
  expect(loadMobileAccessPolicy(dir).isEnabled()).toBe(false);
});

test("migration: a phone grant alone (no policy file) → on", () => {
  seedPhones([["projA"]]);
  expect(loadMobileAccessPolicy(dir).isEnabled()).toBe(true);
});

test("migration writes v2 even when it lands on false, so it never runs twice", () => {
  expect(loadMobileAccessPolicy(dir).isEnabled()).toBe(false);
  expect(readPolicyFile()).toEqual({ version: 2, enabled: false });
});

test("an existing v2 file is authoritative — the v1 grants are not re-read", () => {
  seedAgents();
  writeFileSync(policyPath(), JSON.stringify({ version: 2, enabled: false }, null, 2));
  // The v1 signal says "on"; a v2 file means the migration already happened and
  // the user has since decided otherwise.
  seedPhones([["projA"]]);

  expect(loadMobileAccessPolicy(dir).isEnabled()).toBe(false);
  expect(readPolicyFile()).toEqual({ version: 2, enabled: false });
});

test("setEnabled(false) is not undone on the next load by leftover v1 grants", () => {
  // The regression the unconditional v2 write exists to prevent: grants still
  // sitting in paired-phones.json would re-migrate the machine back on at boot.
  seedPhones([["projA"]]);
  const store = loadMobileAccessPolicy(dir);
  expect(store.isEnabled()).toBe(true);
  store.setEnabled(false);

  expect(loadMobileAccessPolicy(dir).isEnabled()).toBe(false);
});

test("a malformed policy file re-migrates rather than throwing", () => {
  seedAgents();
  writeFileSync(policyPath(), "{not json");
  seedPhones([["projA"]]);
  expect(loadMobileAccessPolicy(dir).isEnabled()).toBe(true);
});

test("an unreadable policy file is never written over with the re-derived value", () => {
  // The silent-revocation path: `writeFileSync` truncates before it writes, so a
  // load racing a `setEnabled` flush can read a torn file. Post-migration the v1
  // grants are gone, so re-deriving yields `false` — flushing that would revoke
  // an enabled machine for good, surfacing only at the next restart.
  seedAgents();
  writeFileSync(policyPath(), '{"version": 2, "ena');

  expect(loadMobileAccessPolicy(dir).isEnabled()).toBe(false); // fail closed in memory
  expect(readFileSync(policyPath(), "utf8")).toBe('{"version": 2, "ena'); // untouched on disk

  // A clean read afterwards still recovers what the user actually chose.
  writeFileSync(policyPath(), JSON.stringify({ version: 2, enabled: true }));
  expect(loadMobileAccessPolicy(dir).isEnabled()).toBe(true);
});

test("the file is created under agents/ on first load", () => {
  loadMobileAccessPolicy(dir);
  expect(existsSync(policyPath())).toBe(true);
});
