import { describe, it, expect } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { diagnoseCodexStderr, spawnCodex } from "../src/codex/spawn-codex";

const LOCK_LINE =
  "Error: failed to initialize sqlite state runtime under C:\\Users\\u\\.codex: " +
  "failed to initialize state runtime at C:\\Users\\u\\.codex";

describe("diagnoseCodexStderr", () => {
  it("maps the sqlite state-runtime lock error to user-facing guidance", () => {
    const msg = diagnoseCodexStderr(LOCK_LINE);
    expect(msg).not.toBeNull();
    expect(msg).toContain("already in use");
    expect(msg).toContain("Codex");
  });

  it("detects the error inside surrounding log noise", () => {
    const text = `some warning\n${LOCK_LINE}\ntrailing line`;
    expect(diagnoseCodexStderr(text)).not.toBeNull();
  });

  it("returns null for unrelated stderr", () => {
    expect(diagnoseCodexStderr("warning: something else\nall good")).toBeNull();
  });
});

describe("spawnCodex failure diagnosis", () => {
  function fakeCodex(body: string): { cwd: string; script: string } {
    const cwd = mkdtempSync(join(tmpdir(), "spawn-codex-test-"));
    const script = join(cwd, "fake-codex.ts");
    writeFileSync(script, body);
    return { cwd, script };
  }

  it("resolves failureDiagnosis with guidance when codex dies with the lock error", async () => {
    const { cwd, script } = fakeCodex(
      `console.error(${JSON.stringify(LOCK_LINE)});\nprocess.exit(1);\n`,
    );
    const spawned = spawnCodex({ cwd, command: process.execPath, args: ["run", script] });
    try {
      const diag = await spawned.failureDiagnosis;
      expect(diag).not.toBeNull();
      expect(diag).toContain("already in use");
    } finally {
      await spawned.kill();
    }
  });

  it("resolves failureDiagnosis null when codex exits without a known error", async () => {
    const { cwd, script } = fakeCodex(
      `console.error("bye");\nprocess.exit(0);\n`,
    );
    const spawned = spawnCodex({ cwd, command: process.execPath, args: ["run", script] });
    try {
      expect(await spawned.failureDiagnosis).toBeNull();
    } finally {
      await spawned.kill();
    }
  });
});
