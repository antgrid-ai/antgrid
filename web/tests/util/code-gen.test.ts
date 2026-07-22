import { describe, test, expect } from "bun:test";
import { generateUserCode, generateDeviceCode } from "../../src/util/code-gen.js";

describe("code-gen", () => {
  test("user code is ABCD-EFGH shape", () => {
    expect(generateUserCode()).toMatch(/^[A-Z2-9]{4}-[A-Z2-9]{4}$/);
  });
  test("device code is url-safe and long", () => {
    const c = generateDeviceCode();
    expect(c).toMatch(/^[A-Za-z0-9_-]+$/);
    expect(c.length).toBeGreaterThanOrEqual(40);
  });
});
