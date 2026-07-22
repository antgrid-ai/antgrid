import { describe, expect, test } from "bun:test";
import { computeProjectId } from "../src/project-id";

describe("computeProjectId", () => {
  test("is deterministic for the same path", () => {
    expect(computeProjectId("/Users/me/proj")).toBe(computeProjectId("/Users/me/proj"));
  });

  test("differs for different paths", () => {
    expect(computeProjectId("/a")).not.toBe(computeProjectId("/b"));
  });

  test("returns 16 hex characters", () => {
    expect(computeProjectId("/x")).toMatch(/^[0-9a-f]{16}$/);
  });

  test("normalizes case on case-insensitive platforms", () => {
    // Force the lowercasing path regardless of host OS
    expect(computeProjectId("/Foo/Bar", { caseInsensitive: true })).toBe(
      computeProjectId("/foo/bar", { caseInsensitive: true }),
    );
  });

  test("resolves symlinks via provided resolver", () => {
    const resolver = (p: string) => (p === "/link" ? "/real" : p);
    expect(computeProjectId("/link", { realpath: resolver })).toBe(computeProjectId("/real"));
  });
});
