import { describe, test, expect } from "bun:test";
import { ScrollbackBuffer } from "../src/scrollback";

describe("ScrollbackBuffer", () => {
  test("append and getContents round-trip", () => {
    const buf = new ScrollbackBuffer();
    buf.append("hello ");
    buf.append("world");
    expect(buf.getContents()).toBe("hello world");
  });

  test("overflow truncates from front", () => {
    const buf = new ScrollbackBuffer(10);
    buf.append("abcdefghij"); // exactly 10
    expect(buf.getContents()).toBe("abcdefghij");

    buf.append("klm"); // now 13, should keep last 10
    expect(buf.getContents()).toBe("defghijklm");
  });

  test("clear empties buffer", () => {
    const buf = new ScrollbackBuffer();
    buf.append("some data");
    buf.clear();
    expect(buf.getContents()).toBe("");
  });

  test("empty buffer returns empty string", () => {
    const buf = new ScrollbackBuffer();
    expect(buf.getContents()).toBe("");
  });

  test("large overflow keeps only maxLength chars", () => {
    const buf = new ScrollbackBuffer(5);
    buf.append("abcdefghijklmnop"); // 16 chars, keep last 5
    expect(buf.getContents()).toBe("lmnop");
  });
});
