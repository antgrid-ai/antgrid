import { describe, it, expect } from "bun:test";
import { win32 } from "node:path";
import { candidatesFor, classifyPath, isInsideRoot, normalizeBases } from "../src/terminal-links/resolver";
import { detectLinks } from "../src/terminal-links/detector";
import { PathStatCache } from "../src/terminal-links/stat-cache";
import { AsyncFs, Clock, mkRows, settle } from "./support/terminal-links-fixtures";

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

  it("is not fooled by a shared prefix or a dot-dot", () => {
    expect(normalizeBases({ checkoutRoot: "/r", spawnCwd: "/repo" }, "linux")).toEqual({ checkoutRoot: "/r" });
    expect(normalizeBases({ checkoutRoot: "/r/a", spawnCwd: "/r/a/../b" }, "linux")).toEqual({
      checkoutRoot: "/r/a",
    });
  });

  it("drops refused bases: UNC roots and cwds, drive-relative and device forms", () => {
    expect(normalizeBases({ checkoutRoot: "\\\\host\\share\\r" }, "win32")).toEqual({});
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
    expect(got).toEqual([{ text: "/r/src/a.ts", base: "a", abs: "/r/src/a.ts" }]);
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
    expect(classifyPath("/r/a.ts", "file", "/r", "linux")).toBe("f");
    expect(classifyPath("/r/src", "dir", "/r", "linux")).toBe("d");
    expect(classifyPath("/r", "dir", "/r", "linux")).toBe("d");
  });

  it("calls an outside image file i and everything else outside nothing", () => {
    expect(classifyPath("/o/a.png", "file", "/r", "linux")).toBe("i");
    expect(classifyPath("/o/a.PNG", "file", "/r", "linux")).toBe("i");
    expect(classifyPath("/o/a.ts", "file", "/r", "linux")).toBeUndefined();
    expect(classifyPath("/o/a.png", "dir", "/r", "linux")).toBeUndefined();
    expect(classifyPath("/o/a.pdf", "file", "/r", "linux")).toBeUndefined();
    expect(classifyPath("/rx/a.png", "file", "/r", "linux")).toBe("i");
    expect(classifyPath("/rx/a.ts", "file", "/r", "linux")).toBeUndefined();
  });

  it("treats everything as outside when there is no root", () => {
    expect(classifyPath("/r/a.ts", "file", undefined, "linux")).toBeUndefined();
    expect(classifyPath("/r/a.png", "file", undefined, "linux")).toBe("i");
  });

  it("folds case on win32 only", () => {
    expect(classifyPath("c:\\repo\\a.ts", "file", "C:\\Repo", "win32")).toBe("f");
    expect(classifyPath("/repo/a.ts", "file", "/Repo", "linux")).toBeUndefined();
    expect(isInsideRoot("C:\\REPO\\x", "c:\\repo", "win32")).toBe(true);
    expect(isInsideRoot("C:\\repository", "C:\\repo", "win32")).toBe(false);
  });
});
