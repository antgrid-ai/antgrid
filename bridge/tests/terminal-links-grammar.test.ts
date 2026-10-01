import { describe, it, expect } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import {
  scanLine,
  splitPathToken,
  trimTrailingPunct,
  trimUrl,
  isRefusedPathShape,
  parseOsc7,
  encodePathLink,
  encodeUrlLink,
  isAntgridLinkUri,
  MAX_LINK_URI_BYTES,
  type ScannedPath,
} from "../src/terminal-links/grammar";

type Platform = NodeJS.Platform;

function pathsOf(text: string, platform: Platform = "linux"): ScannedPath[] {
  return scanLine(text, platform).paths;
}

function findPath(text: string, first: string, platform: Platform = "linux"): ScannedPath | undefined {
  return pathsOf(text, platform).find((p) => p.text.variants[0] === first);
}

describe("scanLine paths that link", () => {
  const cases: Array<[string, string, number | undefined, number | undefined, Platform?]> = [
    ["Updated bridge/src/agent-core.ts", "bridge/src/agent-core.ts", undefined, undefined],
    ["Edited app\\lib\\main.dart", "app\\lib\\main.dart", undefined, undefined],
    ["bridge/src/a.ts:120", "bridge/src/a.ts", 120, undefined],
    ["src/a.ts:12:5: error", "src/a.ts", 12, 5],
    ["src/a.ts(12,5): error TS2322", "src/a.ts", 12, 5],
    ["docs/x.md#L42", "docs/x.md", 42, undefined],
    ['File "C:\\x\\y.py", line 12, in <module>', "C:\\x\\y.py", 12, undefined],
    ["./scripts/dev.ts", "./scripts/dev.ts", undefined, undefined],
    ["../out/a.png", "../out/a.png", undefined, undefined],
    ["C:/Users/x/proj/a.ts", "C:/Users/x/proj/a.ts", undefined, undefined],
    ["C:\\Users\\x\\proj\\a.ts:10", "C:\\Users\\x\\proj\\a.ts", 10, undefined],
    ["/home/u/proj/a.ts:3", "/home/u/proj/a.ts", 3, undefined, "linux"],
    ["● Read(app/lib/main.dart)", "app/lib/main.dart", undefined, undefined],
    ["(see docs/architecture.md).", "docs/architecture.md", undefined, undefined],
    ['"docs/My File.md"', "docs/My File.md", undefined, undefined],
    ["`src/a b.ts`", "src/a b.ts", undefined, undefined],
    ["‘src/a.ts’", "src/a.ts", undefined, undefined],
    ["“src/a.ts”", "src/a.ts", undefined, undefined],
    ["**src/a.ts**", "src/a.ts", undefined, undefined],
    ["--config=antgrid.yaml", "antgrid.yaml", undefined, undefined],
    ["src/a.ts:12:const x", "src/a.ts", 12, undefined],
    ["src/a.ts.", "src/a.ts", undefined, undefined],
    ["at fn (file:///C:/x/a.mjs:3:4)", "C:/x/a.mjs", 3, 4, "win32"],
    ["Don't touch src/a.ts, it's fine", "src/a.ts", undefined, undefined],
    ["node_modules/@types/x/index.d.ts", "node_modules/@types/x/index.d.ts", undefined, undefined],
    ["@scope/pkg/lib.js", "@scope/pkg/lib.js", undefined, undefined],
    ["README.md", "README.md", undefined, undefined],
  ];

  for (const [printed, first, line, col, platform] of cases) {
    it(`links ${JSON.stringify(printed)}`, () => {
      const found = findPath(printed, first, platform);
      expect(found).toBeDefined();
      expect(found!.text.line).toBe(line);
      expect(found!.text.col).toBe(col);
    });
  }

  it("keeps the quote flag on quoted tokens and drops it on bare ones", () => {
    expect(findPath('"docs/My File.md"', "docs/My File.md")!.quoted).toBe(true);
    expect(findPath("docs/x.md", "docs/x.md")!.quoted).toBe(false);
  });

  it("covers only the inner text of a quoted token", () => {
    const text = 'see "docs/My File.md" now';
    const found = findPath(text, "docs/My File.md")!;
    expect(text.slice(found.start, found.end)).toBe("docs/My File.md");
  });

  it("reads a Python 'line N' suffix after the closing quote", () => {
    expect(findPath('File "C:\\x\\y.py", line 12, in <module>', "C:\\x\\y.py")!.text.line).toBe(12);
  });

  it("offers the stripped diff-prefix variant first, then the printed one", () => {
    const found = pathsOf("+++ b/bridge/src/x.ts").find((p) => p.text.variants.length === 2);
    expect(found!.text.variants).toEqual(["bridge/src/x.ts", "b/bridge/src/x.ts"]);
  });

  it("covers the original printed cells for a file URL and not the decoded text", () => {
    const text = "at fn (file:///C:/x/a%20b.mjs:3:4)";
    const found = findPath(text, "C:/x/a b.mjs", "win32")!;
    expect(text.slice(found.start, found.end)).toBe("file:///C:/x/a%20b.mjs:3:4");
  });

  it("decodes a posix file URL without a drive", () => {
    expect(findPath("file:///home/u/a.ts:3", "/home/u/a.ts", "linux")!.text.line).toBe(3);
  });

  it("drops a file URL whose escapes do not decode", () => {
    expect(pathsOf("file:///home/%E0%A4%A/a.ts", "linux")).toEqual([]);
  });

  it("shifts a flag assignment's range onto the value", () => {
    const text = "--config=antgrid.yaml";
    const found = findPath(text, "antgrid.yaml")!;
    expect(text.slice(found.start, found.end)).toBe("antgrid.yaml");
  });

  it("flags a bare token that is followed by an open paren", () => {
    const text = "see run.ts(";
    expect(pathsOf(text)).toEqual([]);
  });

  it("offers an unquoted alternative inside a quoted range that failed to link", () => {
    const text = '{"stack":"at Object.fetch (C:/r/src/server.ts:15:26)\\nat …"}';
    const found = findPath(text, "C:/r/src/server.ts");
    expect(found).toBeDefined();
    expect(found!.quoted).toBe(false);
    expect(found!.text.line).toBe(15);
    expect(found!.text.col).toBe(26);
  });

  it("returns a quoted claim alongside the unquoted tokens inside it", () => {
    const text = '"docs/My File.md"';
    const all = pathsOf(text);
    expect(all.some((p) => p.quoted && p.text.variants[0] === "docs/My File.md")).toBe(true);
    const inner = all.filter((p) => !p.quoted).map((p) => p.text.variants[0]);
    expect(inner).toEqual(["docs/My", "File.md"]);
  });

  it("keeps an apostrophe inside a word from opening a quote", () => {
    expect(pathsOf("Don't touch src/a.ts, it's fine").every((p) => !p.quoted)).toBe(true);
  });

  it("accepts a single-quoted path whose neighbours are not word characters", () => {
    expect(findPath("run 'src/a b.ts' now", "src/a b.ts")!.quoted).toBe(true);
  });

  it("does not link a path inside a URL", () => {
    expect(pathsOf("see https://example.com/a/b.ts now")).toEqual([]);
  });

  it("orders overlapping claims outer first", () => {
    const all = pathsOf('"src/a.ts"');
    expect(all[0]!.quoted).toBe(true);
    expect(all[1]!.quoted).toBe(false);
  });
});

describe("scanLine text that is not a path", () => {
  const none: Array<[string, Platform?]> = [
    ["https://e.com/a/b"],
    ["package:foo/bar.dart"],
    ["dart:io"],
    ["node:fs"],
    ["git@github.com:org/repo.git"],
    ["x@users.noreply.github.com"],
    ["file.ts::$DATA"],
    ["C:a.png"],
    ["\\\\host\\share\\a.png"],
    ["//host/share/a.png"],
    ["/\\host\\share\\a.png"],
    ["\\/host/share/a.png"],
    ["\\\\?\\C:\\x.png"],
    ["\\\\.\\pipe\\x"],
    ["a/" + "b".repeat(1023)],
    ["Done."],
    ["1.5"],
    ["v1.2.3"],
    ["10.0.0.1:8080"],
    ["3/4 done"],
    ["[1/5]"],
    ["$_.FullName"],
    ["%APPDATA%/x.txt"],
    ["foo.bar("],
    ["/docs", "win32"],
    ["name?.ts"],
  ];

  for (const [printed, platform] of none) {
    it(`finds no path in ${JSON.stringify(printed.length > 40 ? `${printed.slice(0, 40)}...` : printed)}`, () => {
      expect(pathsOf(printed, platform ?? "linux")).toEqual([]);
    });
  }

  it("still links a posix absolute path on a posix platform", () => {
    expect(findPath("/docs", "/docs", "linux")).toBeDefined();
  });

  it("accepts a path of exactly the cap and refuses one past it", () => {
    const atCap = "a/" + "b".repeat(1022);
    expect(atCap.length).toBe(1024);
    expect(pathsOf(atCap)).toHaveLength(1);
    expect(pathsOf(atCap + "b")).toEqual([]);
  });
});

describe("scanLine urls", () => {
  const urls = (text: string) => scanLine(text, "linux").urls.map((u) => u.url);

  it("trims sentence punctuation", () => {
    expect(urls("see https://example.com/a?b=1#c.")).toEqual(["https://example.com/a?b=1#c"]);
  });

  it("keeps a balanced paren pair and drops the sentence's own closer", () => {
    expect(urls("(https://en.wikipedia.org/wiki/Foo_(bar))")).toEqual(["https://en.wikipedia.org/wiki/Foo_(bar)"]);
  });

  it("splits adjacent markdown links into two urls", () => {
    expect(urls("[a](https://x/a)[b](https://x/b)")).toEqual(["https://x/a", "https://x/b"]);
  });

  it("gives none for a bare scheme or an empty host", () => {
    expect(urls("https://")).toEqual([]);
    expect(urls("see https://. now")).toEqual([]);
    expect(urls("https:///path")).toEqual([]);
  });

  it("reports offsets that cover exactly the trimmed url", () => {
    const text = "go https://example.com/a. ok";
    const [u] = scanLine(text, "linux").urls;
    expect(text.slice(u!.start, u!.end)).toBe("https://example.com/a");
  });

  it("stops at quotes, angle brackets and whitespace", () => {
    expect(urls('<https://a.com/x> "https://b.com/y" https://c.com/z d')).toEqual([
      "https://a.com/x",
      "https://b.com/y",
      "https://c.com/z",
    ]);
  });

  it("is case-insensitive on the scheme and needs a word boundary", () => {
    expect(urls("HTTPS://E.COM/a")).toEqual(["HTTPS://E.COM/a"]);
    expect(urls("xhttps://e.com/a")).toEqual([]);
  });

  it("claims its range so a trailing path-looking segment does not link", () => {
    const { paths, urls: found } = scanLine("https://example.com/a/b.ts", "linux");
    expect(found).toHaveLength(1);
    expect(paths).toEqual([]);
  });
});

describe("trimTrailingPunct and trimUrl", () => {
  it("drops runs of prose punctuation", () => {
    expect(trimTrailingPunct("src/a.ts.,;:!?")).toBe("src/a.ts");
  });

  it("keeps a position tail and a balanced pair", () => {
    expect(trimTrailingPunct("a.ts(12,5)")).toBe("a.ts(12,5)");
    expect(trimTrailingPunct("Read(a.ts)")).toBe("Read(a.ts)");
  });

  it("drops one unbalanced closer and the punctuation it exposes", () => {
    expect(trimTrailingPunct("a.ts).")).toBe("a.ts");
    expect(trimTrailingPunct("a.ts.)")).toBe("a.ts");
  });

  it("cuts a url at the first unbalanced closer", () => {
    expect(trimUrl("https://x/a)[b](https://x/b)")).toBe("https://x/a");
    expect(trimUrl("https://x/Foo_(bar)).")).toBe("https://x/Foo_(bar)");
  });
});

describe("splitPathToken", () => {
  it("drops an out-of-range line but keeps the path", () => {
    expect(splitPathToken("x/b.ts:99999999")).toEqual({ variants: ["x/b.ts"] });
    expect(splitPathToken("x/b.ts:0")).toEqual({ variants: ["x/b.ts"] });
  });

  it("drops a column that has no line", () => {
    expect(splitPathToken("x/b.ts:99999999:5")).toEqual({ variants: ["x/b.ts"] });
  });

  it("drops an out-of-range column only", () => {
    expect(splitPathToken("x/b.ts:3:100001")).toEqual({ variants: ["x/b.ts"], line: 3 });
  });

  it("takes a ranged anchor's first line", () => {
    expect(splitPathToken("docs/x.md#L10C2-L20C4")).toEqual({ variants: ["docs/x.md"], line: 10, col: 2 });
  });

  it("needs an extension when there is no separator", () => {
    expect(splitPathToken("Makefile")).toBeUndefined();
    expect(splitPathToken("main.go")).toBeDefined();
    expect(splitPathToken("README.MD")).toBeDefined();
    expect(splitPathToken("a.Bar")).toBeUndefined();
    expect(splitPathToken(".env")).toBeUndefined();
  });

  it("keeps a directory path that has no extension", () => {
    expect(splitPathToken("app/lib/")).toEqual({ variants: ["app/lib/"] });
    expect(splitPathToken("src")).toBeUndefined();
  });

  it("refuses a control character and an empty token", () => {
    expect(splitPathToken("a/b\u0007.ts")).toBeUndefined();
    expect(splitPathToken("")).toBeUndefined();
  });

  it("refuses a posix-absolute path only on win32", () => {
    expect(splitPathToken("/src/a.ts", { platform: "win32" })).toBeUndefined();
    expect(splitPathToken("/src/a.ts", { platform: "linux" })).toBeDefined();
  });
});

describe("isRefusedPathShape", () => {
  const refusedOnWin32 = [
    "\\\\host\\share\\a.png",
    "//host/share/a.png",
    "/\\host\\share\\a.png",
    "\\/host/share/a.png",
    "\\\\?\\C:\\x.png",
    "\\\\.\\pipe\\x",
    "a:b.md",
    "C:a.png",
    "x::$DATA",
    "C:\\x\\y.png:Zone.Identifier",
  ];

  for (const p of refusedOnWin32) {
    it(`refuses ${JSON.stringify(p)} on win32`, () => {
      expect(isRefusedPathShape(p, "win32")).toBe(true);
    });
  }

  it("allows an ordinary drive path on win32", () => {
    expect(isRefusedPathShape("C:\\Users\\x\\a.png", "win32")).toBe(false);
    expect(isRefusedPathShape("C:/Users/x/a.png", "win32")).toBe(false);
    expect(isRefusedPathShape("src/a.ts", "win32")).toBe(false);
  });

  it("keeps a colon and a double slash legal on linux", () => {
    expect(isRefusedPathShape("notes/2024-01-01T10:00.md", "linux")).toBe(false);
    expect(isRefusedPathShape("//x/y", "linux")).toBe(false);
  });

  it("refuses control characters on both platforms", () => {
    for (const platform of ["win32", "linux"] as const) {
      expect(isRefusedPathShape("a/b\u0000.ts", platform)).toBe(true);
      expect(isRefusedPathShape("a/b\u001b.ts", platform)).toBe(true);
      expect(isRefusedPathShape("a/b\u007f.ts", platform)).toBe(true);
      expect(isRefusedPathShape("a/b\u0085.ts", platform)).toBe(true);
    }
  });
});

describe("encoders", () => {
  it("encodes the documented example exactly", () => {
    expect(encodePathLink({ path: "src/a b.ts", base: "s", kind: "f", line: 12, col: 5 })).toBe(
      "antgrid-path:?p=src%2Fa%20b.ts&b=s&k=f&n=12&c=5",
    );
    expect(encodePathLink({ path: "src/a.ts", base: "r", kind: "f", line: 12 })).toBe(
      "antgrid-path:?p=src%2Fa.ts&b=r&k=f&n=12",
    );
    expect(encodePathLink({ path: "app/lib", base: "r", kind: "d" })).toBe("antgrid-path:?p=app%2Flib&b=r&k=d");
  });

  it("never emits a raw plus", () => {
    const uri = encodePathLink({ path: "a+b/c d.ts", base: "r", kind: "f" })!;
    expect(uri).toContain("%2B");
    expect(uri.includes("+")).toBe(false);
  });

  it("drops a column that has no line and an out-of-range line", () => {
    expect(encodePathLink({ path: "a/b.ts", base: "r", kind: "f", col: 5 })).not.toContain("&c=");
    expect(encodePathLink({ path: "a/b.ts", base: "r", kind: "f", line: 0, col: 5 })).not.toContain("&n=");
    expect(encodePathLink({ path: "a/b.ts", base: "r", kind: "f", line: 3, col: 100001 })).toBe(
      "antgrid-path:?p=a%2Fb.ts&b=r&k=f&n=3",
    );
  });

  it("refuses an empty path, a lone surrogate and an over-long path", () => {
    expect(encodePathLink({ path: "", base: "r", kind: "f" })).toBeUndefined();
    expect(encodePathLink({ path: "a/\ud800.ts", base: "r", kind: "f" })).toBeUndefined();
    expect(encodePathLink({ path: "a/" + "b".repeat(1023), base: "r", kind: "f" })).toBeUndefined();
  });

  it("returns undefined above the byte cap and accepts a link just under it", () => {
    const under = encodePathLink({ path: `src/${"€".repeat(217)}.ts`, base: "r", kind: "f" });
    expect(under).toBeDefined();
    expect(under!.length).toBe(33 + 9 * 217);
    expect(under!.length).toBeLessThanOrEqual(MAX_LINK_URI_BYTES);
    expect(encodePathLink({ path: `src/${"€".repeat(219)}.ts`, base: "r", kind: "f" })).toBeUndefined();
  });

  it("percent-encodes only the non-ascii part of a url", () => {
    expect(encodeUrlLink("https://例え.jp/ä")).toBe("antgrid-url:https://%E4%BE%8B%E3%81%88.jp/%C3%A4");
    expect(encodeUrlLink("https://e.com/a?b=1#c%20d")).toBe("antgrid-url:https://e.com/a?b=1#c%20d");
  });

  it("encodes characters outside printable ascii", () => {
    expect(encodeUrlLink("https://e.com/a b")).toBe("antgrid-url:https://e.com/a%20b");
    expect(encodeUrlLink("https://e.com/a\u007fb")).toBe("antgrid-url:https://e.com/a%7Fb");
  });

  it("returns undefined for a url above the byte cap", () => {
    expect(encodeUrlLink(`https://e.com/${"a".repeat(1990)}`)).toBeUndefined();
    expect(encodeUrlLink(`https://e.com/${"é".repeat(1000)}`)).toBeUndefined();
    expect(encodeUrlLink(`https://e.com/${"a".repeat(1900)}`)).toBeDefined();
  });

  it("recognises only the bridge's own scheme family", () => {
    expect(isAntgridLinkUri("antgrid-path:?p=a")).toBe(true);
    expect(isAntgridLinkUri("ANTGRID-URL:https://e.com")).toBe(true);
    expect(isAntgridLinkUri("https://antgrid-x.com")).toBe(false);
    expect(isAntgridLinkUri("")).toBe(false);
  });
});

describe("parseOsc7", () => {
  it("accepts a local drive path on win32", () => {
    expect(parseOsc7("file:///C:/x/y", "box", "win32")).toBe("C:/x/y");
  });

  it("accepts an empty, localhost or own-hostname authority", () => {
    expect(parseOsc7("file:///home/x", "box", "linux")).toBe("/home/x");
    expect(parseOsc7("file://localhost/home/x", "box", "linux")).toBe("/home/x");
    expect(parseOsc7("file://localhost/home/x", "box", "linux")).toBe("/home/x");
    expect(parseOsc7("file://BOX/home/x", "box", "linux")).toBe("/home/x");
    expect(parseOsc7("file://box/home/x", "Box", "linux")).toBe("/home/x");
  });

  it("decodes escapes", () => {
    expect(parseOsc7("file:///home/a%20b", "box", "linux")).toBe("/home/a b");
  });

  it("rejects another host, a UNC root and escaped separators", () => {
    expect(parseOsc7("file://other/home/x", "box", "linux")).toBeUndefined();
    expect(parseOsc7("file:////host/share/x", "box", "win32")).toBeUndefined();
    expect(parseOsc7("file:////host/share/x", "box", "linux")).toBeUndefined();
    expect(parseOsc7("file:///%5C%5Chost%5Cshare", "box", "win32")).toBeUndefined();
    expect(parseOsc7("file:///%5C%5Chost%5Cshare", "box", "linux")).toBeUndefined();
  });

  it("rejects a relative path, a bad escape and other schemes", () => {
    expect(parseOsc7("x/y", "box", "linux")).toBeUndefined();
    expect(parseOsc7("file:///%E0%A4%A", "box", "linux")).toBeUndefined();
    expect(parseOsc7("https://e.com/x", "box", "linux")).toBeUndefined();
    expect(parseOsc7("file://localhost", "box", "linux")).toBeUndefined();
  });

  it("rejects a path with a control character and one that is too long", () => {
    expect(parseOsc7("file:///home/a%07b", "box", "linux")).toBeUndefined();
    expect(parseOsc7(`file:///${"a".repeat(4096)}`, "box", "linux")).toBeUndefined();
  });

  it("rejects a drive-relative or ADS path on win32", () => {
    expect(parseOsc7("file:///C:x", "box", "win32")).toBeUndefined();
    expect(parseOsc7("file:///C:/x:ads", "box", "win32")).toBeUndefined();
  });
});

describe("pathological lines stay fast", () => {
  const SIZE = 64 * 1024;
  const repeated = (unit: string) => unit.repeat(Math.ceil(SIZE / unit.length)).slice(0, SIZE);

  const lines: Array<[string, string]> = [
    ["http prefixes", repeated("http://")],
    ["https paren cuts", repeated("https://a)")],
    ["https open parens", repeated("https://a(")],
    ["file url prefixes", repeated("file:///")],
    ["double quotes", repeated('"')],
    ["quote then text", repeated('"a ')],
    ["apostrophes", repeated("'a")],
    ["typographic openers", repeated("‘")],
    ["typographic pairs", repeated("“a”")],
    ["backticks", repeated("`x")],
    ["dots", repeated(".")],
    ["dots then letter", `${".".repeat(SIZE)}a`],
    ["parens", repeated("(")],
    ["closers", repeated("a)")],
    ["position tails", repeated("a(1)")],
    ["colon digits", repeated("a:1")],
    ["colon runs", repeated(":1")],
    ["hash anchors", repeated("a#L1")],
    ["assignments", repeated("a=")],
    ["one long assignment token", `a=${"b".repeat(SIZE)}`],
    ["separators", repeated("/")],
    ["segments", repeated("a/")],
    ["words", repeated("a ")],
    ["at signs", repeated("a@")],
    ["unicode spaces in a url", `https://a${"\u3000".repeat(SIZE / 2)}`],
    ["one huge token", "a".repeat(SIZE)],
    ["mixed quote kinds", repeated(`"x'`)],
    ["quote pairs around long inner text", repeated(`"${"a/b ".repeat(200)}"`)],
    ["unterminated long quote", `"${"a/b ".repeat(SIZE / 4)}`],
    ["colons inside a quote", repeated(`"a:1:`)],
    ["punctuation tail", `${"a/b".repeat(1000)}${".".repeat(SIZE / 2)}`],
  ];

  for (const [name, line] of lines) {
    it(`scans ${name} in linear time`, () => {
      const started = performance.now();
      scanLine(line, "linux");
      scanLine(line, "win32");
      expect(performance.now() - started).toBeLessThan(1500);
    });
  }

  it("trims a long run of closers in linear time", () => {
    const started = performance.now();
    trimTrailingPunct(`a${")".repeat(SIZE)}`);
    trimUrl(`https://a${")".repeat(SIZE)}`);
    expect(performance.now() - started).toBeLessThan(500);
  });
});

describe("scanner hand-overs", () => {
  it("lets an empty quote hand its closing mark over as the next opener", () => {
    expect(pathsOf('""a.ts"').filter((p) => p.quoted).map((p) => p.text.variants[0])).toEqual(["a.ts"]);
    expect(pathsOf("‘‘a.ts’").filter((p) => p.quoted).map((p) => p.text.variants[0])).toEqual(["a.ts"]);
  });

  it("lets an apostrophe that fails as a closer open the next quote", () => {
    expect(pathsOf("'x'y 'src/a.ts'").filter((p) => p.quoted).map((p) => p.text.variants[0])).toEqual(["src/a.ts"]);
  });

  it("strips a NAME= prefix only behind at most two dashes", () => {
    expect(findPath("--out=dist/a.js", "dist/a.js")?.start).toBe(6);
    expect(findPath("---out=dist/a.js", "---out=dist/a.js")?.start).toBe(0);
  });

  it("drops an unbalanced closer before a malformed position but keeps a real one", () => {
    expect(trimTrailingPunct("x)(,5)")).toBe("x)(,5");
    expect(trimTrailingPunct("x)(1,5)")).toBe("x)(1,5)");
  });

  it("takes a second number as the column only when it ends the token or meets a colon", () => {
    expect(splitPathToken("src/a.ts:12:3a", { platform: "linux" })).toEqual({ variants: ["src/a.ts"], line: 12 });
    expect(splitPathToken("src/a.ts:12:3:msg", { platform: "linux" })).toEqual({ variants: ["src/a.ts"], line: 12, col: 3 });
  });

  it("reads a #L position from the last hash only", () => {
    expect(splitPathToken("docs/a#b.md#L4C2-L9", { platform: "linux" })).toEqual({ variants: ["docs/a#b.md"], line: 4, col: 2 });
  });
});

describe("terminal-links source", () => {
  // Detection reads every line a program prints; the scanners are explicit
  // walks so their cost is linear by construction, and a pattern added later
  // would reopen the backtracking audit this module was written to avoid.
  it("uses no regular expressions", () => {
    const dir = join(import.meta.dir, "../src/terminal-links");
    const offenders: string[] = [];
    for (const name of readdirSync(dir).filter((f) => f.endsWith(".ts"))) {
      const source = readFileSync(join(dir, name), "utf8");
      source.split("\n").forEach((line, i) => {
        if (/\bRegExp\b|\.(?:test|exec|match|matchAll|search)\(|\.(?:replace|replaceAll|split)\(\s*\//.test(line)) {
          offenders.push(`${name}:${i + 1}: ${line.trim()}`);
        }
      });
    }
    expect(offenders).toEqual([]);
  });
});
