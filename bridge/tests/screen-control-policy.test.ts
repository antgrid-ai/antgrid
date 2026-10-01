import { test, expect, beforeEach, afterEach } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadScreenControlPolicy } from "../src/screen-control-policy";

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "antgrid-screen-control-"));
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

const policyPath = () => join(dir, "agents", "screen-control-policy.json");

function seedPolicy(body: string) {
  mkdirSync(join(dir, "agents"), { recursive: true });
  writeFileSync(policyPath(), body);
}

test("a fresh machine will not share its screen until the user says so", () => {
  expect(loadScreenControlPolicy(dir).isEnabled()).toBe(false);
});

test("nothing is written until the switch is turned on", () => {
  // There is no migration to record, so absent already means off.
  loadScreenControlPolicy(dir);
  expect(existsSync(policyPath())).toBe(false);

  loadScreenControlPolicy(dir).setEnabled(true);
  expect(JSON.parse(readFileSync(policyPath(), "utf8"))).toEqual({ version: 1, enabled: true });
});

test("setEnabled reports whether it changed and persists across a reload", () => {
  const store = loadScreenControlPolicy(dir);
  expect(store.setEnabled(true)).toBe(true);
  expect(store.setEnabled(true)).toBe(false);
  expect(store.isEnabled()).toBe(true);

  expect(loadScreenControlPolicy(dir).isEnabled()).toBe(true);

  expect(store.setEnabled(false)).toBe(true);
  expect(loadScreenControlPolicy(dir).isEnabled()).toBe(false);
});

test("remote screen control is a separate decision from remote access", () => {
  // Sharing a machine's terminal must never enable its screen: the two stores
  // share nothing but a directory.
  mkdirSync(join(dir, "agents"), { recursive: true });
  writeFileSync(join(dir, "agents", "mobile-access-policy.json"), JSON.stringify({ version: 2, enabled: true }));
  expect(loadScreenControlPolicy(dir).isEnabled()).toBe(false);
});

test("a torn file fails closed in memory and is left untouched on disk", () => {
  seedPolicy('{"version": 1, "ena');

  expect(loadScreenControlPolicy(dir).isEnabled()).toBe(false);
  expect(readFileSync(policyPath(), "utf8")).toBe('{"version": 1, "ena');

  // A clean read afterwards still recovers what the user actually chose.
  seedPolicy(JSON.stringify({ version: 1, enabled: true }));
  expect(loadScreenControlPolicy(dir).isEnabled()).toBe(true);
});

test("a file we cannot make sense of is off, never a guess", () => {
  for (const body of ['"nope"', "null", "[]", '{"version": 1}', '{"version": 1, "enabled": "yes"}', '{"version": 9, "enabled": true}']) {
    seedPolicy(body);
    expect(loadScreenControlPolicy(dir).isEnabled()).toBe(false);
    expect(readFileSync(policyPath(), "utf8")).toBe(body);
  }
});

// --- Revocation ---------------------------------------------------------------
// The only enforcement point that reaches a WebRTC datachannel, which never
// passes through the bridge. If these stop holding, the machine-wide kill switch
// silently fails to kill the highest-privilege capability in the product.

test("turning the switch off tears down synchronously, before setEnabled returns", () => {
  const store = loadScreenControlPolicy(dir);
  const torn: string[] = [];
  store.onRevoked(() => torn.push("a"));
  store.onRevoked(() => torn.push("b"));

  store.setEnabled(true);
  expect(torn).toEqual([]);

  store.setEnabled(false);
  expect(torn).toEqual(["a", "b"]);
});

test("a redundant off still tears down — the peer connection, not this boolean, holds the capability", () => {
  const store = loadScreenControlPolicy(dir);
  let torn = 0;
  store.onRevoked(() => torn++);

  expect(store.setEnabled(false)).toBe(false);
  expect(torn).toBe(1);
});

test("one throwing hook does not strand the others", () => {
  const store = loadScreenControlPolicy(dir);
  const torn: string[] = [];
  store.onRevoked(() => { throw new Error("peer connection already gone"); });
  store.onRevoked(() => torn.push("survivor"));

  store.setEnabled(true);
  expect(() => store.setEnabled(false)).not.toThrow();
  expect(torn).toEqual(["survivor"]);
});

test("a hook that unsubscribes itself as it tears down does not skip its neighbours", () => {
  const store = loadScreenControlPolicy(dir);
  const torn: string[] = [];
  const off = store.onRevoked(() => { torn.push("self-removing"); off(); });
  store.onRevoked(() => torn.push("neighbour"));

  store.setEnabled(false);
  expect(torn).toEqual(["self-removing", "neighbour"]);

  store.setEnabled(false);
  expect(torn).toEqual(["self-removing", "neighbour", "neighbour"]);
});

test("an unsubscribed hook stops being called", () => {
  const store = loadScreenControlPolicy(dir);
  let torn = 0;
  const off = store.onRevoked(() => torn++);
  off();

  store.setEnabled(false);
  expect(torn).toBe(0);
});
