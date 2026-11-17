import { describe, it, expect } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { TOOL_UPDATE_SPECS, updateSpecFor, fetchNpmLatest, execToolUpdate, type ToolUpdateSpec } from "../src/update/specs";

// The per-tool table is the whole point of this module: a wrong subcommand
// (opencode `upgrade` vs `update`) or npm package silently breaks that tool's
// update path. Pin the load-bearing values.
describe("TOOL_UPDATE_SPECS", () => {
  it("maps each supported tool to its updater subcommand + npm package", () => {
    expect(TOOL_UPDATE_SPECS.codex).toMatchObject({
      npmPackage: "@openai/codex", command: "codex", updateArgs: ["update"],
    });
    // OpenCode 2 is published as @opencode/cli; `opencode-ai` stays on 1.x.
    expect(TOOL_UPDATE_SPECS.opencode).toMatchObject({ npmPackage: "@opencode/cli", command: "opencode" });
    const opencode = TOOL_UPDATE_SPECS.opencode!;
    const opencodeArgs = "updateArgs" in opencode ? opencode.updateArgs : null;
    if (typeof opencodeArgs !== "function") throw new Error("Expected version-aware opencode updater args");
    expect(opencodeArgs("1.19.0")).toEqual(["upgrade", "--major"]);
    expect(opencodeArgs("2.2.6")).toEqual(["upgrade"]);
    expect(TOOL_UPDATE_SPECS["claude-code"]).toMatchObject({
      npmPackage: "@anthropic-ai/claude-code", command: "claude", updateArgs: ["update"],
    });
  });

  it("keys every spec by its own canonical tool id", () => {
    for (const [key, spec] of Object.entries(TOOL_UPDATE_SPECS)) {
      expect(spec.tool).toBe(key);
    }
  });
});

describe("updateSpecFor", () => {
  it("returns the spec for a supported tool", () => {
    expect(updateSpecFor("opencode")).toMatchObject({ npmPackage: "@opencode/cli" });
    expect(updateSpecFor("claude-code")).toMatchObject({ command: "claude" });
  });

  it("returns null for a tool with no self-updater (fail-soft upstream)", () => {
    expect(updateSpecFor("github-copilot")).toBeNull();
    expect(updateSpecFor("nonsense")).toBeNull();
  });
});

describe("execToolUpdate", () => {
  it("picks version-aware updater args from the installed binary's --version", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-update-args-"));
    try {
      const echo = join(dir, "echo-argv.ts");
      writeFileSync(echo, "console.log(process.argv.slice(2).join(' '));");
      const seen: Array<string | null> = [];
      // The bun binary stands in for the agent CLI: its `--version` is a plain
      // semver, and `bun <script> ...` echoes the args the updater was given.
      const spec: ToolUpdateSpec = {
        tool: "fixture", npmPackage: "fixture", command: process.execPath,
        updateArgs: (installed) => { seen.push(installed); return [echo, "upgrade", installed ? "--from-known" : "--from-unknown"]; },
      };
      const result = await execToolUpdate(spec);
      expect(result).toEqual({ exitCode: 0, output: "upgrade --from-known" });
      expect(seen).toEqual([Bun.version]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("fetchNpmLatest (per-package registry probe)", () => {
  it("requests <registry>/<package>/latest and returns .version", async () => {
    let url = "";
    const spy = (async (u: string) => {
      url = String(u);
      return new Response(JSON.stringify({ version: "1.2.3" }), { status: 200 });
    }) as unknown as typeof fetch;
    expect(await fetchNpmLatest("opencode-ai", spy)).toBe("1.2.3");
    expect(url).toBe("https://registry.npmjs.org/opencode-ai/latest");
  });

  it("keeps a scoped package's slash unencoded in the path", async () => {
    let url = "";
    const spy = (async (u: string) => {
      url = String(u);
      return new Response(JSON.stringify({ version: "2.0.0" }), { status: 200 });
    }) as unknown as typeof fetch;
    await fetchNpmLatest("@anthropic-ai/claude-code", spy);
    expect(url).toBe("https://registry.npmjs.org/@anthropic-ai/claude-code/latest");
  });

  it("is fail-soft: null on non-ok, throw, and malformed json", async () => {
    const notFound = (async () => new Response("nope", { status: 404 })) as unknown as typeof fetch;
    const boom = (async () => { throw new Error("ENOTFOUND"); }) as unknown as typeof fetch;
    const bad = (async () => new Response("<html>", { status: 200 })) as unknown as typeof fetch;
    expect(await fetchNpmLatest("opencode-ai", notFound)).toBeNull();
    expect(await fetchNpmLatest("opencode-ai", boom)).toBeNull();
    expect(await fetchNpmLatest("opencode-ai", bad)).toBeNull();
  });
});
