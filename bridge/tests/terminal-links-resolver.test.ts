import { describe, it, expect, spyOn } from "bun:test";
import { posix, win32 } from "node:path";
import {
  candidatesFor,
  classifyPath,
  isInsideResolved,
  isInsideRoot,
  normalizeBases,
  resolveAgainstBase,
  type ClassifyHints,
} from "../src/terminal-links/resolver";
import { foldPathCase } from "../src/terminal-links/chars";
import { detectLinks } from "../src/terminal-links/detector";
import { PathStatCache } from "../src/terminal-links/stat-cache";
import { AsyncFs, Clock, mkRows, settle } from "./support/terminal-links-fixtures";

/** `classifyPath` with the lexical containment a caller holding no candidate
 *  would have to compute itself. */
function classify(
  abs: string,
  status: "file" | "dir",
  root: string | undefined,
  platform: NodeJS.Platform,
  hints: Partial<ClassifyHints> = {},
) {
  const inside = root !== undefined && isInsideRoot(abs, root, platform);
  return classifyPath(abs, status, platform, { inside, ...hints });
}

describe("resolveAgainstBase", () => {
  it("joins relative text onto the base with the platform's own rules", () => {
    expect(resolveAgainstBase("src\\a.ts", "r", { checkoutRoot: "C:\\r" }, "win32")).toBe("C:\\r\\src\\a.ts");
    expect(resolveAgainstBase("src/a.ts", "r", { checkoutRoot: "/r" }, "linux")).toBe("/r/src/a.ts");
  });

  it("does not resolve current-drive or drive-relative text against the process drive", () => {
    const bases = { checkoutRoot: "C:\\r", liveCwd: "C:\\r\\sub", spawnCwd: "C:\\r" };
    for (const base of ["l", "s", "r"] as const) {
      for (const text of ["\\a.ts", "/a.ts", "C:a.ts", "d:sub\\a.ts"]) {
        expect(resolveAgainstBase(text, base, bases, "win32")).toBeUndefined();
      }
    }
  });
});

describe("normalizeBases", () => {
  it("keeps a root and cwds contained in it", () => {
    expect(
      normalizeBases({ checkoutRoot: "/r", spawnCwd: "/r/app", liveCwd: "/r/app/lib" }, "linux"),
    ).toEqual({ checkoutRoot: "/r", spawnCwd: "/r/app", liveCwd: "/r/app/lib" });
  });

  it("drops a spawn or live cwd outside the root", () => {
    expect(normalizeBases({ checkoutRoot: "/r", spawnCwd: "/elsewhere", liveCwd: "/rx" }, "linux")).toEqual({
      checkoutRoot: "/r",
    });
  });

  it("drops both cwds when there is no root to contain them", () => {
    expect(normalizeBases({ spawnCwd: "/r", liveCwd: "/r/a" }, "linux")).toEqual({});
  });

  it("drops relative bases", () => {
    expect(normalizeBases({ checkoutRoot: "r", spawnCwd: "r/app" }, "linux")).toEqual({});
    expect(normalizeBases({ checkoutRoot: "/r", spawnCwd: "app" }, "linux")).toEqual({ checkoutRoot: "/r" });
  });

  it("folds case on win32 when testing containment", () => {
    expect(normalizeBases({ checkoutRoot: "C:\\Repo", spawnCwd: "c:\\repo\\App" }, "win32")).toEqual({
      checkoutRoot: "C:\\Repo",
      spawnCwd: "c:\\repo\\App",
    });
    expect(normalizeBases({ checkoutRoot: "/Repo", spawnCwd: "/repo/App" }, "linux")).toEqual({
      checkoutRoot: "/Repo",
    });
  });

  it("keeps a drive cwd that repeats a separator just after the root", () => {
    expect(normalizeBases({ checkoutRoot: "C:\\r", liveCwd: "C:\\r\\\\x", spawnCwd: "C:\\r\\/y" }, "win32")).toEqual({
      checkoutRoot: "C:\\r",
      liveCwd: "C:\\r\\x",
      spawnCwd: "C:\\r\\y",
    });
    expect(normalizeBases({ checkoutRoot: "C:\\r", liveCwd: "C:\\r\\a:b\\.." }, "win32")).toEqual({
      checkoutRoot: "C:\\r",
    });
  });

  it("is not fooled by a shared prefix or a dot-dot", () => {
    expect(normalizeBases({ checkoutRoot: "/r", spawnCwd: "/repo" }, "linux")).toEqual({ checkoutRoot: "/r" });
    expect(normalizeBases({ checkoutRoot: "/r/a", spawnCwd: "/r/a/../b" }, "linux")).toEqual({
      checkoutRoot: "/r/a",
    });
  });

  it("keeps a UNC checkout root and refuses a cwd on any other share", () => {
    expect(normalizeBases({ checkoutRoot: "\\\\host\\share\\r" }, "win32")).toEqual({
      checkoutRoot: "\\\\host\\share\\r",
    });
    expect(
      normalizeBases(
        { checkoutRoot: "\\\\host\\share\\r", liveCwd: "\\\\HOST\\Share\\r\\x", spawnCwd: "\\\\other\\share\\x" },
        "win32",
      ),
    ).toEqual({ checkoutRoot: "\\\\host\\share\\r", liveCwd: "\\\\HOST\\Share\\r\\x" });
    expect(normalizeBases({ checkoutRoot: "\\\\host\\share\\r\\a:b" }, "win32")).toEqual({});
    expect(normalizeBases({ checkoutRoot: "\\\\?\\C:\\r" }, "win32")).toEqual({});
  });

  it("drops refused bases: foreign-share cwds, drive-relative and device forms", () => {
    expect(normalizeBases({ checkoutRoot: "C:\\r", liveCwd: "\\\\host\\share\\x" }, "win32")).toEqual({
      checkoutRoot: "C:\\r",
    });
    expect(normalizeBases({ checkoutRoot: "C:\\r", spawnCwd: "C:\\r\\a:b" }, "win32")).toEqual({
      checkoutRoot: "C:\\r",
    });
    expect(normalizeBases({ checkoutRoot: "/r", spawnCwd: "/r/a\u0001b" }, "linux")).toEqual({
      checkoutRoot: "/r",
    });
  });

  it("drops a posix-rooted path on win32 and a drive path on linux", () => {
    expect(normalizeBases({ checkoutRoot: "/r" }, "win32")).toEqual({});
    expect(normalizeBases({ checkoutRoot: "C:\\r" }, "linux")).toEqual({});
  });

  it("makes no filesystem call for a refused live cwd", async () => {
    const fs = new AsyncFs(win32);
    fs.add("C:\\r\\src\\a.ts");
    const clock = new Clock();
    const cache = new PathStatCache({
      fs,
      now: clock.now,
      timer: clock.timer,
      platform: "win32",
      isLocalVolume: () => true,
    });
    const bases = normalizeBases(
      { checkoutRoot: "C:\\r", liveCwd: "\\\\host\\share\\x", spawnCwd: "C:\\r" },
      "win32",
    );
    const run = () =>
      detectLinks(mkRows(["see src/a.ts"], 20), 0, bases, cache, { lookups: 100, newStats: 10 }, undefined, "win32");
    run();
    await settle();
    expect(run().spans).toHaveLength(1);
    expect(fs.calls.some((c) => c.startsWith("\\\\") || c.includes("host"))).toBe(false);
  });
});

describe("candidatesFor", () => {
  const bases = { liveCwd: "/r/live", spawnCwd: "/r/spawn", checkoutRoot: "/r" };

  it("tries the live cwd, then the spawn cwd, then the root", () => {
    const got = candidatesFor(["a.ts"], bases, "linux");
    expect(got.map((c) => [c.base, c.abs])).toEqual([
      ["l", "/r/live/a.ts"],
      ["s", "/r/spawn/a.ts"],
      ["r", "/r/a.ts"],
    ]);
  });

  it("keeps the printed text on every candidate, never the resolved one", () => {
    for (const c of candidatesFor(["../x/a.ts"], { checkoutRoot: "/r", spawnCwd: "/r/s" }, "linux")) {
      expect(c.text).toBe("../x/a.ts");
    }
  });

  it("dedups candidates that resolve to the same file", () => {
    const got = candidatesFor(["a.ts"], { spawnCwd: "/r", checkoutRoot: "/r" }, "linux");
    expect(got.map((c) => c.base)).toEqual(["s"]);
  });

  it("gives an absolute path one candidate with base a", () => {
    const got = candidatesFor(["/r/src/a.ts"], bases, "linux");
    expect(got).toEqual([{ text: "/r/src/a.ts", base: "a", abs: "/r/src/a.ts", inside: true }]);
  });

  it("resolves a Windows absolute path and folds its separators", () => {
    const got = candidatesFor(["C:/r/src/a.ts"], { checkoutRoot: "C:\\r" }, "win32");
    expect(got.map((c) => c.abs)).toEqual(["C:\\r\\src\\a.ts"]);
    expect(got[0]!.base).toBe("a");
  });

  it("has no candidates for relative text when there is no root", () => {
    expect(candidatesFor(["src/a.ts"], {}, "linux")).toEqual([]);
    expect(candidatesFor(["src/a.ts"], { liveCwd: "/r/a", spawnCwd: "/r" }, "linux")).toEqual([]);
  });

  it("makes no candidate of an outside .ts path and one of an outside .png", () => {
    expect(candidatesFor(["/etc/passwd.ts"], bases, "linux")).toEqual([]);
    expect(candidatesFor(["/home/u/shot.png"], bases, "linux").map((c) => c.abs)).toEqual(["/home/u/shot.png"]);
    expect(candidatesFor(["/home/u/shot.png"], {}, "linux").map((c) => c.abs)).toEqual(["/home/u/shot.png"]);
  });

  it("drops a relative path that climbs out of the root unless it is an image", () => {
    expect(candidatesFor(["../out/a.ts"], { checkoutRoot: "/r" }, "linux")).toEqual([]);
    expect(candidatesFor(["../out/a.png"], { checkoutRoot: "/r" }, "linux").map((c) => c.abs)).toEqual([
      "/out/a.png",
    ]);
  });

  it("never offers a drive-relative or current-drive-rooted path on win32", () => {
    expect(candidatesFor(["\\x\\a.ts"], { checkoutRoot: "C:\\r" }, "win32")).toEqual([]);
    expect(candidatesFor(["D:a.png"], { checkoutRoot: "C:\\r" }, "win32")).toEqual([]);
  });

  it("drops a refused result without resolving it", () => {
    expect(candidatesFor(["a\u0001.ts"], { checkoutRoot: "/r" }, "linux")).toEqual([]);
    expect(candidatesFor(["a:b.ts"], { checkoutRoot: "C:\\r" }, "win32")).toEqual([]);
  });

  it("orders diff-prefix variants first-variant-first, each across the bases", () => {
    const got = candidatesFor(["bridge/x.ts", "b/bridge/x.ts"], { spawnCwd: "/r/s", checkoutRoot: "/r" }, "linux");
    expect(got.map((c) => [c.text, c.base])).toEqual([
      ["bridge/x.ts", "s"],
      ["bridge/x.ts", "r"],
      ["b/bridge/x.ts", "s"],
      ["b/bridge/x.ts", "r"],
    ]);
  });

  it("never uses the process working directory", () => {
    const got = candidatesFor(["a.ts"], { checkoutRoot: "/r" }, "linux");
    expect(got.map((c) => c.abs)).toEqual(["/r/a.ts"]);
  });
});

describe("classifyPath", () => {
  it("calls an inside file f and an inside directory d", () => {
    expect(classify("/r/a.ts", "file", "/r", "linux")).toBe("f");
    expect(classify("/r/src", "dir", "/r", "linux")).toBe("d");
    expect(classify("/r", "dir", "/r", "linux")).toBe("d");
  });

  it("calls an outside image file i and everything else outside nothing", () => {
    expect(classify("/o/a.png", "file", "/r", "linux")).toBe("i");
    expect(classify("/o/a.PNG", "file", "/r", "linux")).toBe("i");
    expect(classify("/o/a.ts", "file", "/r", "linux")).toBeUndefined();
    expect(classify("/o/a.png", "dir", "/r", "linux")).toBeUndefined();
    expect(classify("/o/a.pdf", "file", "/r", "linux")).toBeUndefined();
    expect(classify("/rx/a.png", "file", "/r", "linux")).toBe("i");
    expect(classify("/rx/a.ts", "file", "/r", "linux")).toBeUndefined();
  });

  it("treats everything as outside when there is no root", () => {
    expect(classify("/r/a.ts", "file", undefined, "linux")).toBeUndefined();
    expect(classify("/r/a.png", "file", undefined, "linux")).toBe("i");
  });

  it("folds case on win32 only", () => {
    expect(classify("c:\\repo\\a.ts", "file", "C:\\Repo", "win32")).toBe("f");
    expect(classify("/repo/a.ts", "file", "/Repo", "linux")).toBeUndefined();
    expect(isInsideRoot("C:\\REPO\\x", "c:\\repo", "win32")).toBe(true);
    expect(isInsideRoot("C:\\repository", "C:\\repo", "win32")).toBe(false);
  });
});

describe("Windows case folding", () => {
  const KELVIN = "\u212a";

  it("folds per UTF-16 unit the way NTFS orders names", () => {
    expect(foldPathCase("C:\\Repo\\src")).toBe("C:\\REPO\\SRC");
    expect(foldPathCase("C:\\repo\\\u00e9")).toBe("C:\\REPO\\\u00c9");
    // U+212A is already upper case, so it stays apart from k and K.
    expect(foldPathCase(KELVIN)).toBe(KELVIN);
    expect(foldPathCase("k")).toBe("K");
    // Upper-casing the sharp s would change the length of the name, so it is kept.
    expect(foldPathCase("stra\u00dfe")).toBe("STRA\u00dfE");
    expect(foldPathCase("\ud801\udc28")).toBe("\ud801\udc28");
  });

  it("does not let the Kelvin sign stand in for k when testing containment", () => {
    expect(isInsideRoot(`C:\\${KELVIN}\\a.ts`, "C:\\k", "win32")).toBe(false);
    expect(isInsideRoot("C:\\K\\a.ts", "C:\\k", "win32")).toBe(true);
    expect(isInsideResolved(`C:\\${KELVIN}\\a.ts`, "C:\\k", "win32")).toBe(false);
    expect(classify(`C:\\${KELVIN}\\a.ts`, "file", "C:\\k", "win32")).toBeUndefined();
  });

  it("keeps names apart that upper-case onto ASCII letters but are distinct on NTFS", () => {
    // Dotless i, long s, micro sign: toUpperCase maps each onto another letter.
    for (const unit of ["\u0131", "\u017f", "\u00b5", "\u0345"]) {
      expect(foldPathCase(unit)).toBe(unit);
    }
    expect(foldPathCase("\u00ff")).toBe("\u0178");
    expect(foldPathCase("\u0131")).not.toBe(foldPathCase("i"));
  });

  it("does not treat a confusably named sibling as inside the root", () => {
    expect(isInsideRoot("C:\\r\\f\u0131le\\a.ts", "C:\\r\\file", "win32")).toBe(false);
    expect(isInsideRoot("C:\\r\\\u017f\\a.ts", "C:\\r\\s", "win32")).toBe(false);
    expect(isInsideResolved("C:\\lf\\f\u0131le\\private\\secret.env", "C:\\lf\\file", "win32")).toBe(false);
    expect(
      classify("C:\\lf\\file\\lnk\\private\\secret.env", "file", "C:\\lf\\file", "win32", {
        inside: true,
        real: "C:\\lf\\f\u0131le\\private\\secret.env",
        realRoot: "C:\\lf\\file",
      }),
    ).toBeUndefined();
    const got = candidatesFor(["C:\\lf\\f\u0131le\\a.ts"], { checkoutRoot: "C:\\lf\\file" }, "win32");
    // Outside the checkout only an image is a candidate at all.
    expect(got).toEqual([]);
  });

  it("keeps a cwd that only the Kelvin sign puts under the root out of the bases", () => {
    expect(normalizeBases({ checkoutRoot: "C:\\k", spawnCwd: `C:\\${KELVIN}\\app` }, "win32")).toEqual({
      checkoutRoot: "C:\\k",
    });
  });

  it("does not merge candidates that differ only by the Kelvin sign", () => {
    const got = candidatesFor(["k/a.ts", `${KELVIN}/a.ts`], { checkoutRoot: "C:\\r" }, "win32");
    expect(got.map((c) => c.abs)).toEqual(["C:\\r\\k\\a.ts", `C:\\r\\${KELVIN}\\a.ts`]);
  });

  it("still merges candidates that differ only by ASCII case", () => {
    const got = candidatesFor(["k/a.ts", "K/A.TS"], { checkoutRoot: "C:\\r" }, "win32");
    expect(got.map((c) => c.abs)).toEqual(["C:\\r\\k\\a.ts"]);
  });
});

describe("candidate containment", () => {
  it("carries whether each candidate is inside the root", () => {
    const got = candidatesFor(["/o/a.png", "/r/b.ts", "../c.png"], { checkoutRoot: "/r/x" }, "linux");
    expect(got.map((c) => [c.abs, c.inside])).toEqual([
      ["/o/a.png", false],
      ["/r/c.png", false],
    ]);
    expect(candidatesFor(["/r/x/b.ts"], { checkoutRoot: "/r/x" }, "linux").map((c) => c.inside)).toEqual([true]);
    expect(candidatesFor(["b.ts"], { checkoutRoot: "/r/x" }, "linux").map((c) => c.inside)).toEqual([true]);
  });

  it("lets a hint stand in for the containment test", () => {
    expect(classify("/elsewhere/a.ts", "file", "/r", "linux", { inside: true })).toBe("f");
    expect(classify("/r/a.ts", "file", "/r", "linux", { inside: false })).toBeUndefined();
  });

  it("judges the printed text by shape and only a path that left the root again", () => {
    expect(candidatesFor(["a:b.ts", "dir/x:y.ts"], { checkoutRoot: "C:\\r" }, "win32")).toEqual([]);
    expect(candidatesFor(["..\\..\\x.png"], { checkoutRoot: "C:\\r" }, "win32").map((c) => c.abs)).toEqual([
      "C:\\x.png",
    ]);
  });
});

describe("classifyPath through links", () => {
  it("calls a path inside the root that really lives outside it nothing, unless it is an image", () => {
    const real = { realRoot: "/r" };
    expect(classify("/r/ln/a.ts", "file", "/r", "linux", { ...real, real: "/o/a.ts" })).toBeUndefined();
    expect(classify("/r/ln", "dir", "/r", "linux", { ...real, real: "/o" })).toBeUndefined();
    expect(classify("/r/ln/a.png", "file", "/r", "linux", { ...real, real: "/o/a.png" })).toBe("i");
  });

  it("does not let an image name hide a file that is not one", () => {
    expect(classify("/r/ln.png", "file", "/r", "linux", { realRoot: "/r", real: "/o/secret.txt" })).toBeUndefined();
  });

  it("keeps a path whose real location is inside the real root", () => {
    expect(classify("/r/a.ts", "file", "/r", "linux", { realRoot: "/real/r", real: "/real/r/a.ts" })).toBe("f");
    expect(classify("/r/ln", "dir", "/r", "linux", { realRoot: "/real/r", real: "/real/r/src" })).toBe("d");
  });

  it("falls back to the lexical answer when either real path is unknown", () => {
    expect(classify("/r/a.ts", "file", "/r", "linux", { real: "/o/a.ts" })).toBe("f");
    expect(classify("/r/a.ts", "file", "/r", "linux", { realRoot: "/r" })).toBe("f");
  });

  it("leaves a path outside the root to the image rule whatever its real location", () => {
    expect(classify("/o/a.png", "file", "/r", "linux", { realRoot: "/r", real: "/r/a.png" })).toBe("i");
    expect(classify("/o/a.ts", "file", "/r", "linux", { realRoot: "/r", real: "/r/a.ts" })).toBeUndefined();
  });

  it("compares real paths with the platform's case rule", () => {
    expect(classify("C:\\r\\a.ts", "file", "C:\\r", "win32", { realRoot: "C:\\Real", real: "c:\\real\\a.ts" })).toBe(
      "f",
    );
  });
});

describe("memoized normalization", () => {
  it("returns one frozen object for the same inputs", () => {
    const a = normalizeBases({ checkoutRoot: "/r", spawnCwd: "/r/a" }, "linux");
    const b = normalizeBases({ checkoutRoot: "/r", spawnCwd: "/r/a" }, "linux");
    expect(b).toBe(a);
    expect(Object.isFrozen(a)).toBe(true);
  });

  it("keys on every input, so different inputs never share an answer", () => {
    const a = normalizeBases({ checkoutRoot: "/r", spawnCwd: "/r/a" }, "linux");
    expect(normalizeBases({ checkoutRoot: "/r", spawnCwd: "/r/a|-" }, "linux").spawnCwd).toBe("/r/a|-");
    expect(normalizeBases({ checkoutRoot: "/r", liveCwd: "/r/a" }, "linux")).toEqual({
      checkoutRoot: "/r",
      liveCwd: "/r/a",
    });
    expect(normalizeBases({ checkoutRoot: "/r", spawnCwd: "/r/a" }, "win32")).toEqual({});
    expect(a).toEqual({ checkoutRoot: "/r", spawnCwd: "/r/a" });
  });

  it("copes with an over-long or non-string base", () => {
    const long = "/r/" + "a".repeat(5000);
    expect(normalizeBases({ checkoutRoot: "/r", spawnCwd: long }, "linux")).toEqual({ checkoutRoot: "/r" });
    expect(normalizeBases({ checkoutRoot: "/r", spawnCwd: 5 as unknown as string }, "linux")).toEqual({
      checkoutRoot: "/r",
    });
  });

  it("answers candidates for a frozen base set without resolving a path again", () => {
    const bases = normalizeBases({ checkoutRoot: "/r", spawnCwd: "/r/s" }, "linux");
    const first = candidatesFor(["a.ts"], bases, "linux");
    const resolve = spyOn(posix, "resolve");
    try {
      expect(candidatesFor(["a.ts"], bases, "linux")).toBe(first);
      expect(normalizeBases({ checkoutRoot: "/r", spawnCwd: "/r/s" }, "linux")).toBe(bases);
      expect(resolve).not.toHaveBeenCalled();
    } finally {
      resolve.mockRestore();
    }
  });

  it("keeps platforms and variant lists apart in that memory", () => {
    const bases = normalizeBases({ checkoutRoot: "/r" }, "linux");
    expect(candidatesFor(["a.ts"], bases, "linux").map((c) => c.abs)).toEqual(["/r/a.ts"]);
    expect(candidatesFor(["a.ts", "b.ts"], bases, "linux").map((c) => c.abs)).toEqual(["/r/a.ts", "/r/b.ts"]);
    expect(candidatesFor(["a.tsb.ts"], bases, "linux").map((c) => c.abs)).toEqual(["/r/a.tsb.ts"]);
  });

  it("does not memoize for a base set that can still change", () => {
    const bases: { checkoutRoot: string } = { checkoutRoot: "/r" };
    expect(candidatesFor(["a.ts"], bases, "linux").map((c) => c.abs)).toEqual(["/r/a.ts"]);
    bases.checkoutRoot = "/q";
    expect(candidatesFor(["a.ts"], bases, "linux").map((c) => c.abs)).toEqual(["/q/a.ts"]);
  });
});
