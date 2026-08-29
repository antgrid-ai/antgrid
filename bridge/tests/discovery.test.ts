import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { atomicWriteFile } from "../src/discovery";

let dir: string;
beforeEach(() => { dir = mkdtempSync(join(tmpdir(), "antgrid-disc-")); });
afterEach(() => { rmSync(dir, { recursive: true, force: true }); });

describe("atomicWriteFile", () => {
  test("writes the content to the target path", () => {
    const path = join(dir, "out.json");
    atomicWriteFile(path, "hello");
    expect(readFileSync(path, "utf8")).toBe("hello");
  });

  test("creates missing parent directories", () => {
    const path = join(dir, "nested", "deep", "out.json");
    atomicWriteFile(path, "y");
    expect(readFileSync(path, "utf8")).toBe("y");
  });

  test("leaves no scratch file behind, whatever it is named", () => {
    const path = join(dir, "out.json");
    atomicWriteFile(path, "a", { dirMode: 0o700, fileMode: 0o600 });
    atomicWriteFile(path, "b");
    expect(existsSync(path)).toBe(true);
    expect(readdirSync(dir)).toEqual(["out.json"]);
  });

  test("a failed write clears its own scratch file", () => {
    // A non-empty directory at the target makes the rename fail. The scratch
    // file is never reclaimed by a write to a different target, so the failing
    // call has to clean up after itself.
    const path = join(dir, "occupied");
    mkdirSync(join(path, "child"), { recursive: true });
    expect(() => atomicWriteFile(path, "z")).toThrow();
    expect(readdirSync(dir)).toEqual(["occupied"]);
  });

  test("never writes through the shared <path>.tmp scratch name", () => {
    // The property the concurrent-writer test below can only sample. A scratch
    // path every writer picks is itself a contended file: two processes truncate
    // it and the rename publishes the blend. Standing a foreign scratch file at
    // that name pins it deterministically.
    const path = join(dir, "out.json");
    const shared = `${path}.tmp`;
    writeFileSync(shared, "another writer's scratch");
    atomicWriteFile(path, "a");
    expect(readFileSync(shared, "utf8")).toBe("another writer's scratch");
    expect(readFileSync(path, "utf8")).toBe("a");
  });

  test("reaps a scratch file whose writer was killed before it could rename", () => {
    // Force-kill is the routine teardown, and the scratch file cannot live off
    // the target's own directory — which for antgrid.yaml is the user's git
    // working tree, and for host.json is a full copy of the control-plane token.
    const path = join(dir, "out.json");
    const abandoned = `${path}.999999.tmp`;
    writeFileSync(abandoned, "half a document");
    atomicWriteFile(path, "a");
    expect(existsSync(abandoned)).toBe(false);
    expect(readFileSync(path, "utf8")).toBe("a");
  });

  test("keeps a scratch file a running writer still owns", async () => {
    const path = join(dir, "out.json");
    const kid = Bun.spawn([process.execPath, "-e", "await Bun.sleep(30_000)"], { stdout: "ignore", stderr: "ignore" });
    const live = `${path}.${kid.pid}.tmp`;
    try {
      writeFileSync(live, "a document being written right now");
      atomicWriteFile(path, "a");
      expect(readFileSync(live, "utf8")).toBe("a document being written right now");
    } finally {
      kid.kill();
      await kid.exited;
    }
  });

  test("reaps only its own target's scratch files", () => {
    // The prefix is the whole basename: two stores sharing a directory (the
    // phone stores both live in <abDir>/agents) must not reap each other.
    const path = join(dir, "out.json");
    const foreign = join(dir, "other.json.999999.tmp");
    writeFileSync(foreign, "not ours");
    atomicWriteFile(path, "a");
    expect(readFileSync(foreign, "utf8")).toBe("not ours");
  });

  test("concurrent writers all succeed and publish a whole document", async () => {
    // Real processes because the contention is a kernel-level one: on Windows a
    // rename is refused while any process holds the target, so a shared scratch
    // file surfaces here as a thrown write rather than as a blend. Both outcomes
    // are asserted — the exit codes catch the Windows shape, the content check
    // catches the POSIX one.
    const target = join(dir, "contended.json");
    const script = join(dir, "writer.ts");
    const fill = 512;
    writeFileSync(script, [
      "const [, , modUrl, target, mark, fill] = Bun.argv;",
      "const { atomicWriteFile } = await import(modUrl);",
      "const body = mark.repeat(Number(fill));",
      "for (let i = 0; i < 20; i++) atomicWriteFile(target, body);",
      "",
    ].join("\n"));

    const modUrl = pathToFileURL(join(import.meta.dir, "..", "src", "discovery.ts")).href;
    const marks = ["a", "b", "c"];
    // process.execPath, not a PATH lookup: the writers must run under the same
    // runtime as the test.
    const kids = marks.map((mark) =>
      Bun.spawn([process.execPath, "run", script, modUrl, target, mark, String(fill)],
        { stdout: "ignore", stderr: "inherit" }));
    try {
      const codes = await Promise.all(kids.map((k) => k.exited));
      expect(codes).toEqual([0, 0, 0]);
      expect(marks.map((m) => m.repeat(fill))).toContain(readFileSync(target, "utf8"));
    } finally {
      // A timed-out test abandons the awaits; without this the afterEach rmSync
      // races three live writers still creating files in `dir`.
      for (const k of kids) { try { k.kill(); } catch { /* already exited */ } }
    }
  }, 30_000);
});
