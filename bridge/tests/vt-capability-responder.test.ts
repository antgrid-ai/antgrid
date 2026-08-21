import { describe, expect, test } from "bun:test";
import { VtCapabilityResponder } from "../src/vt-capability-responder";

const COLORS = {
  foreground: "rgb:fafa/fafa/fafa",
  background: "rgb:0909/0909/0b0b",
  cursor: "rgb:8181/8c8c/f8f8",
};

const make = () => new VtCapabilityResponder(COLORS);

const DA1 = "\x1b[?64;1;2;6;9;15;18;21;22c";
const DA2 = "\x1b[>1;1000;0c";

describe("VtCapabilityResponder", () => {
  test("answers each query form", () => {
    const r = make();
    expect(r.feed("\x1b[c")).toBe(DA1);
    expect(r.feed("\x1b[0c")).toBe(DA1);
    expect(r.feed("\x1b[>c")).toBe(DA2);
    expect(r.feed("\x1b[>0c")).toBe(DA2);
    expect(r.feed("\x1b[=c")).toBe("\x1bP!|00000000\x1b\\");
    expect(r.feed("\x1b[>0q")).toBe("\x1bP>|antgrid(1.0)\x1b\\");
    expect(r.feed("\x1b[6n")).toBe("\x1b[1;1R");
    expect(r.feed("\x1b[5n")).toBe("\x1b[0n");
    expect(r.feed("\x1b[?u")).toBe("\x1b[?0u");
  });

  test("answers OSC colour queries with either terminator", () => {
    const r = make();
    expect(r.feed("\x1b]11;?\x07")).toBe(`\x1b]11;${COLORS.background}\x07`);
    expect(r.feed("\x1b]10;?\x1b\\")).toBe(
      `\x1b]10;${COLORS.foreground}\x1b\\`,
    );
    expect(r.feed("\x1b]12;?\x07")).toBe(`\x1b]12;${COLORS.cursor}\x07`);
    // Not a colour slot we define — no answer, rather than a wrong one.
    expect(r.feed("\x1b]17;?\x07")).toBe("");
  });

  test("a DA1 batched with a DA2 still gets its own reply", () => {
    // The whole startup handshake in one write, which is what a TUI does. The
    // old chunk-wide "is there a DA2 anywhere" guard dropped the DA1 here, and
    // DA1 is the barrier the rest of the handshake is ordered against.
    const r = make();
    expect(r.feed("\x1b[>0q\x1b[>c\x1b[c")).toBe(
      `\x1bP>|antgrid(1.0)\x1b\\${DA2}${DA1}`,
    );
  });

  test("replies come out in query order", () => {
    const r = make();
    expect(r.feed("\x1b[c\x1b[6n\x1b[>c")).toBe(`${DA1}\x1b[1;1R${DA2}`);
  });

  test("answers a query split across chunks", () => {
    const r = make();
    expect(r.feed("hello \x1b[")).toBe("");
    expect(r.feed("c world")).toBe(DA1);
  });

  test("answers a query split mid-parameter", () => {
    const r = make();
    expect(r.feed("\x1b[?202")).toBe("");
    expect(r.feed("6$p")).toBe("\x1b[?2026;2$y");
  });

  test("does not carry a completed non-query sequence", () => {
    const r = make();
    expect(r.feed("\x1b[0m")).toBe("");
    // A DA1 arriving next must not be glued onto the SGR above.
    expect(r.feed("\x1b[c")).toBe(DA1);
  });

  test("bounds the carry so binary output cannot grow it", () => {
    const r = make();
    // An unterminated OSC longer than the cap is dropped, not accumulated.
    expect(r.feed(`\x1b]0;${"x".repeat(1024)}`)).toBe("");
    expect(r.feed("\x1b[c")).toBe(DA1);
  });

  test("DECRQM reports reset until the guest sets the mode", () => {
    const r = make();
    expect(r.feed("\x1b[?2004$p")).toBe("\x1b[?2004;2$y");
    r.feed("\x1b[?2004h");
    expect(r.feed("\x1b[?2004$p")).toBe("\x1b[?2004;1$y");
    r.feed("\x1b[?2004l");
    expect(r.feed("\x1b[?2004$p")).toBe("\x1b[?2004;2$y");
  });

  test("DECRQM follows a multi-parameter mode set", () => {
    const r = make();
    r.feed("\x1b[?1000;1002;1006h");
    expect(r.feed("\x1b[?1006$p")).toBe("\x1b[?1006;1$y");
    expect(r.feed("\x1b[?1003$p")).toBe("\x1b[?1003;2$y");
  });

  test("DECRQM reports modes that come up set", () => {
    const r = make();
    expect(r.feed("\x1b[?7$p")).toBe("\x1b[?7;1$y"); // DECAWM
    expect(r.feed("\x1b[?25$p")).toBe("\x1b[?25;1$y"); // DECTCEM
  });

  test("DECRQM reports 0 for a mode nothing here implements", () => {
    const r = make();
    expect(r.feed("\x1b[?9999$p")).toBe("\x1b[?9999;0$y");
  });

  test("plain output produces nothing", () => {
    const r = make();
    expect(r.feed("just some text\r\n")).toBe("");
    expect(r.feed("\x1b[32mgreen\x1b[0m\r\n")).toBe("");
  });
});
