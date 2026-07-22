import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
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

test("defaults to no same-account project grants", () => {
  const store = loadMobileAccessPolicy(dir);
  expect(store.listSameAccountDefaultProjects()).toEqual([]);
});

test("enableProject persists one project idempotently", () => {
  const store = loadMobileAccessPolicy(dir);
  store.enableProject("projA");
  store.enableProject("projA");

  const fresh = loadMobileAccessPolicy(dir);
  expect(fresh.listSameAccountDefaultProjects()).toEqual(["projA"]);
  expect(fresh.isEnabled("projA")).toBe(true);
  expect(fresh.isEnabled("projB")).toBe(false);
});

test("disableProject removes a project and reports whether it changed", () => {
  const store = loadMobileAccessPolicy(dir);
  store.enableProject("projA");
  store.enableProject("projB");

  expect(store.disableProject("projA")).toBe(true);
  expect(store.disableProject("projA")).toBe(false);

  const fresh = loadMobileAccessPolicy(dir);
  expect(fresh.listSameAccountDefaultProjects()).toEqual(["projB"]);
});
