import { describe, expect, test } from "bun:test";
import { TerminalClipboardScanner } from "./scanner";
import { decodeClipboardText } from "./limits";

const osc = (text: string, end = "\x07") => `\x1b]52;c;${Buffer.from(text).toString("base64")}${end}`;
describe("live clipboard extraction", () => {
  for (const end of ["\x07", "\x1b\\", "\x9c"]) {
    const command = osc("hello 世界\n🙂", end);
    test(`every chunk boundary (${JSON.stringify(end)})`, () => {
      for (let split = 0; split <= command.length; split++) {
        const scanner = new TerminalClipboardScanner(() => 42);
        const first = scanner.feed(`before${command.slice(0, split)}`);
        const second = scanner.feed(`${command.slice(split)}after`);
        expect(first.output + second.output).toBe("beforeafter");
        expect([...first.writes, ...second.writes]).toEqual([{ owner: 42, text: "hello 世界\n🙂" }]);
      }
    });
  }
  test("captures the original owner even across the introducer", () => {
    let owner = 1;
    const scanner = new TerminalClipboardScanner(() => owner);
    scanner.feed("\x1b"); owner = 2;
    expect(scanner.feed(osc("first").slice(1)).writes[0]?.owner).toBe(1);
  });
  test("tmux and direct copies deduplicate and preserve ordinary content", () => {
    const command = osc("copied");
    const wrapped = `\x1bPtmux;${(`hello${command}world`).replaceAll("\x1b", "\x1b\x1b")}\x1b\\`;
    for (let split = 0; split <= wrapped.length; split++) {
      const scanner = new TerminalClipboardScanner(() => 1, () => 0);
      const a = scanner.feed(wrapped.slice(0, split));
      const b = scanner.feed(wrapped.slice(split) + command);
      expect([...a.writes, ...b.writes]).toEqual([{ owner: 1, text: "copied" }]);
      expect(a.output + b.output).toBe("\x1bPtmux;helloworld\x1b\\");
    }
  });
  test("C1 OSC, read denial, cancellation, and overflow", () => {
    const scanner = new TerminalClipboardScanner();
    expect(scanner.feed("\x9d52;c;dGV4dA==\x9c").writes[0]?.text).toBe("text");
    expect(scanner.feed("\x1b]52;cs;?\x1b\\").replies).toEqual(["\x1b]52;cs;\x1b\\"]);
    expect(scanner.feed("\x1b]52;c;c2VjcmV0\x18safe").output).toBe("safe");
    expect(scanner.feed("\x1b]52;c;" + "x".repeat(150000)).output).toBe("");
    expect(scanner.feed("secret\x07safe").output).toBe("safe");
  });
  test("a stray ESC cannot bypass C1 clipboard redaction at any chunk boundary", () => {
    const raw = "\x1b\x9d52;c;c2VjcmV0\x07safe";
    for (let split = 0; split <= raw.length; split++) {
      const scanner = new TerminalClipboardScanner(() => 42);
      const first = scanner.feed(raw.slice(0, split));
      const second = scanner.feed(raw.slice(split));
      expect(first.output + second.output).toBe("\x1bsafe");
      expect([...first.writes, ...second.writes]).toEqual([{ owner: 42, text: "secret" }]);
    }
  });
  test("strict payload validation", () => {
    for (const selector of ["c!", "clipboard", "c\n", "c".repeat(17)]) {
      expect(new TerminalClipboardScanner().feed(`\x1b]52;${selector};YQ==\x07`).writes).toEqual([]);
    }
    for (const payload of ["", "dGV4dA", "AB==", "////", "AA==", "Y Q==", Buffer.alloc(100001).toString("base64")]) {
      expect(decodeClipboardText(payload)).toBeUndefined();
      const scan = new TerminalClipboardScanner().feed(`\x1b]52;c;${payload}\x07`);
      expect(scan.output).toBe(""); expect(scan.writes).toEqual([]);
    }
  });
  test("numeric OSC52 aliases and ignored C0 bytes cannot bypass redaction", () => {
    for (const command of ["052", "00052", "5\x002", "5\t2", "5\r2", "5\n2", "\x0052", "52\x00"]) {
      const raw = `\x1b]${command};c;c2VjcmV0\x07`;
      for (let split = 0; split <= raw.length; split++) {
        const scanner = new TerminalClipboardScanner(() => 1);
        const first = scanner.feed(raw.slice(0, split));
        const second = scanner.feed(raw.slice(split));
        expect(first.output + second.output).toBe("");
        expect([...first.writes, ...second.writes]).toEqual([{ owner: 1, text: "secret" }]);
      }
    }
  });
  test("unrelated valid control strings are preserved and malformed nested clipboard strings are discarded", () => {
    const raw = `\x1bPhello${osc("no")}\x1b\\`;
    const result = new TerminalClipboardScanner().feed(raw);
    expect(result.output).toBe("\x1b\\"); expect(result.writes).toEqual([]);
    const ordinary = "\x1bPhello\x1b\\\x1b]0;title\x07\x1b_private\x1b\\";
    expect(new TerminalClipboardScanner().feed(ordinary).output).toBe(ordinary);
    for (const prefix of ["\x1b]0;title\x1b]", "\x1b]0;title\x9d", "\x1b]0;title\x1b\t]", "\x1b]0;title\x1b\x1b]", "\x1b]0;title\x1b\x9d", "\x1b_private\x1b]"]) {
      const nested = `${prefix}052;c;c2VjcmV0\x07\x1b\\`;
      for (let split = 0; split <= nested.length; split++) {
        const scanner = new TerminalClipboardScanner(() => 1);
        const first = scanner.feed(nested.slice(0, split));
        const second = scanner.feed(nested.slice(split));
        expect(first.output + second.output).not.toContain("c2VjcmV0");
        expect([...first.writes, ...second.writes]).toEqual([]);
      }
    }
  });
  test("ignored controls between ESC and OSC introducer cannot expose clipboard text", () => {
    for (const control of ["\x00", "\t", "\r", "\n", "\x7f"]) {
      const result = new TerminalClipboardScanner().feed(`\x1b${control}]52;c;c2VjcmV0\x07`);
      expect(result.output).toBe(control);
      expect(result.writes[0]?.text).toBe("secret");
    }
  });
  test("an ESC command recovers rendering from an unterminated control string across every split", () => {
    const recovery = "\x1b[31mRECOVERED\x1b[0m\r\nprompt> ";
    for (const prefix of ["\x1b]0;title", "\x1b]52;c;c2VjcmV0", "\x1bPprivate", "\x1b_private", "\x1b^private", "\x1bXprivate"]) {
      const raw = prefix + recovery;
      for (let split = 0; split <= raw.length; split++) {
        const scanner = new TerminalClipboardScanner(() => 1);
        const first = scanner.feed(raw.slice(0, split));
        const second = scanner.feed(raw.slice(split));
        expect(first.output + second.output).toBe(recovery);
        expect([...first.writes, ...second.writes]).toEqual([]);
        expect(scanner.feed(osc("next")).writes).toEqual([{ owner: 1, text: "next" }]);
      }
    }
  });
  test("overflowed ordinary strings recover at a new escape command without exposing the discarded body", () => {
    const scanner = new TerminalClipboardScanner();
    expect(scanner.feed("\x1b]52;c;" + "A".repeat(150000) + "\x1b").output).toBe("");
    const recovered = scanner.feed("[32mRECOVERED");
    expect(recovered.output).toBe("\x1b[32mRECOVERED");
    expect(recovered.writes).toEqual([]);
  });
  test("write and query budgets refill independently", () => {
    let now = 0;
    const scanner = new TerminalClipboardScanner(undefined, () => now);
    expect(scanner.feed(["a", "b", "c", "d"].map((v) => osc(v)).join("")).writes).toHaveLength(3);
    now = 1000;
    expect(scanner.feed(osc("d")).writes).toHaveLength(1);
    expect(scanner.feed("\x1b]52;c;?\x07".repeat(4)).replies).toHaveLength(3);
  });
  test("the exact byte ceiling preserves Unicode, tabs, and newlines", () => {
    const text = "\u{1f642}".repeat(24999) + "a\t\n!";
    expect(Buffer.byteLength(text)).toBe(100000);
    expect(decodeClipboardText(Buffer.from(text).toString("base64"))).toBe(text);
    expect(new TerminalClipboardScanner().feed(osc(text)).writes[0]?.text).toBe(text);
  });
  test("overflow inside tmux drains through the outer terminator", () => {
    const scanner = new TerminalClipboardScanner();
    expect(scanner.feed("\x1bPtmux;\x1b\x1b]52;c;" + "A".repeat(150000)).output).toBe("");
    expect(scanner.feed("\x1b\x1b\\secret\x1b\\safe").output).toBe("safe");
    expect(scanner.feed(osc("recovered")).writes[0]?.text).toBe("recovered");
  });
  test("control string memory is bounded by UTF-8 bytes rather than UTF-16 units", () => {
    const scanner = new TerminalClipboardScanner();
    expect(scanner.feed("\x1b]0;" + "\u{1f642}".repeat(40000) + "\x07safe").output).toBe("safe");
    expect(scanner.feed(osc("recovered")).writes[0]?.text).toBe("recovered");
  });
  test("tmux cancellation and malformed escaped bodies cannot emit copies", () => {
    for (const cancel of ["\x18", "\x1a"]) {
      const scanner = new TerminalClipboardScanner();
      expect(scanner.feed(`\x1bPtmux;\x1b\x1b]52;c;c2VjcmV0${cancel}safe`).output).toBe("safe");
      expect(scanner.feed(osc("recovered")).writes[0]?.text).toBe("recovered");
    }
    expect(new TerminalClipboardScanner().feed(`\x1bPtmux;${osc("secret")}\x1b\\`).writes).toEqual([]);
  });
  test("supported selector lists produce one copy and unsupported-only queries stay silent", () => {
    for (const selector of ["", "c", "s", "p", "csp", "0c7"]) {
      expect(new TerminalClipboardScanner().feed(`\x1b]52;${selector};YQ==\x07`).writes).toHaveLength(1);
    }
    for (const selector of ["0", "01234567", "x", "c".repeat(17)]) {
      expect(new TerminalClipboardScanner().feed(`\x1b]52;${selector};?\x07`).replies).toEqual([]);
    }
  });
});
