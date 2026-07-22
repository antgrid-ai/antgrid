import { describe, it, expect } from "bun:test";
import { isFragEnvelope, FRAG_THRESHOLD, MAX_FRAME_PAYLOAD } from "../src/index";

describe("isFragEnvelope", () => {
  it("accepts a well-formed envelope", () => {
    expect(isFragEnvelope({ __frag: { id: "a", i: 0, n: 2 }, data: "x" })).toBe(true);
  });
  it("rejects a normal message", () => {
    expect(isFragEnvelope({ type: "file:content", path: "a" })).toBe(false);
  });
  it("rejects non-objects and missing data", () => {
    expect(isFragEnvelope(null)).toBe(false);
    expect(isFragEnvelope({ __frag: { id: "a", i: 0, n: 1 } })).toBe(false);
  });
  it("exposes the budget constants", () => {
    expect(FRAG_THRESHOLD).toBe(1_400_000);
    expect(MAX_FRAME_PAYLOAD).toBe(1_500_000);
  });
});

import { splitForJsonData, buildFragments } from "../src/index";

describe("splitForJsonData", () => {
  it("never exceeds the escaped budget per slice and rejoins exactly", () => {
    const s = "a".repeat(2500);
    const slices = splitForJsonData(s, 1000);
    expect(slices.length).toBe(3);
    for (const sl of slices) expect(Buffer.byteLength(sl, "utf8")).toBeLessThanOrEqual(1000);
    expect(slices.join("")).toBe(s);
  });
  it("never splits a multibyte codepoint", () => {
    const s = "😀😀😀";
    const slices = splitForJsonData(s, 5);
    expect(slices).toEqual(["😀", "😀", "😀"]);
    expect(slices.join("")).toBe(s);
  });
  it("returns a single slice for short input", () => {
    expect(splitForJsonData("hello", 1000)).toEqual(["hello"]);
  });
  it("counts JSON-escaped cost so the serialized envelope stays within budget", () => {
    const json = "\\".repeat(4000) + '"'.repeat(4000);
    const frames = buildFragments(json, "tid", undefined, 1000);
    for (const f of frames) {
      expect(Buffer.byteLength(f, "utf8")).toBeLessThanOrEqual(1000 + 200);
    }
    expect(frames.map((f) => JSON.parse(f).data).join("")).toBe(json);
  });
  it("counts lone surrogate code units as JSON unicode escapes", () => {
    const s = "\uD800\uD800";
    const slices = splitForJsonData(s, 6);
    expect(slices).toEqual(["\uD800", "\uD800"]);
    for (const sl of slices) {
      expect(Buffer.byteLength(JSON.stringify(sl), "utf8") - 2).toBeLessThanOrEqual(6);
    }
    expect(slices.join("")).toBe(s);
  });
  it("throws for non-positive escaped budgets", () => {
    expect(() => splitForJsonData("hello", 0)).toThrow();
    expect(() => splitForJsonData("hello", -1)).toThrow();
  });
});

describe("buildFragments", () => {
  it("wraps each slice, repeats hint for recoverable transfers, n is the slice count", () => {
    const json = JSON.stringify({ type: "file:content", path: "a.png", content: "x".repeat(2500) });
    const frames = buildFragments(json, "tid", { type: "file:content", key: "a.png" }, 1000);
    const parsed = frames.map((f) => JSON.parse(f));
    expect(parsed.length).toBeGreaterThan(1);
    expect(parsed[0].__frag).toMatchObject({ id: "tid", i: 0, n: parsed.length, hint: { type: "file:content", key: "a.png" } });
    expect(parsed[1].__frag.hint).toEqual({ type: "file:content", key: "a.png" });
    expect(parsed.map((p) => p.data).join("")).toBe(json);
  });
});
