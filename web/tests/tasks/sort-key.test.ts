import { describe, test, expect } from "bun:test";
import { keyBetween, isSortKey, SortKeyError } from "../../src/tasks/sort-key.js";

describe("keyBetween", () => {
  test("the first key of a list leaves room on both sides", () => {
    const first = keyBetween(null, null);
    expect(isSortKey(first)).toBe(true);
    expect(keyBetween(null, first) < first).toBe(true);
    expect(keyBetween(first, null) > first).toBe(true);
  });

  test("appending stays compact rather than halving toward the end", () => {
    let key = keyBetween(null, null);
    const keys = [key];
    for (let i = 0; i < 500; i++) {
      const next = keyBetween(key, null);
      expect(next > key).toBe(true);
      key = next;
      keys.push(key);
    }
    // Halving toward the end of the alphabet would push these past 100
    // characters; the whole point of the append path is that it does not.
    expect(key.length).toBeLessThan(20);
    expect([...keys].sort()).toEqual(keys);
  });

  test("any two adjacent keys still have a midpoint, repeatedly", () => {
    let low = keyBetween(null, null);
    let high = keyBetween(low, null);
    for (let i = 0; i < 200; i++) {
      const mid = keyBetween(low, high);
      expect(mid > low).toBe(true);
      expect(mid < high).toBe(true);
      expect(isSortKey(mid)).toBe(true);
      // Alternate which side closes in, so both the shared-prefix and the
      // adjacent-digit branches get exercised.
      if (i % 2 === 0) low = mid;
      else high = mid;
    }
  });

  test("prepending repeatedly stays ordered", () => {
    let key = keyBetween(null, null);
    for (let i = 0; i < 100; i++) {
      const next = keyBetween(null, key);
      expect(next < key).toBe(true);
      expect(isSortKey(next)).toBe(true);
      key = next;
    }
  });

  test("no key ever ends in the smallest digit", () => {
    // A trailing `0` has no room below it inside its own prefix, which is what
    // would make `keyBetween` non-total.
    let key = keyBetween(null, null);
    for (let i = 0; i < 300; i++) {
      key = keyBetween(key, null);
      expect(key.endsWith("0")).toBe(false);
    }
  });

  test("neighbours in the wrong order are refused, not silently swapped", () => {
    const low = keyBetween(null, null);
    const high = keyBetween(low, null);
    expect(() => keyBetween(high, low)).toThrow(SortKeyError);
    expect(() => keyBetween(low, low)).toThrow(SortKeyError);
  });

  test("a key outside the alphabet is refused", () => {
    expect(isSortKey("A")).toBe(false);
    expect(isSortKey("")).toBe(false);
    expect(isSortKey("a0")).toBe(false);
    expect(() => keyBetween("a-b", null)).toThrow(SortKeyError);
  });
});
