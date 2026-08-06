import { describe, it, expect } from "bun:test";
import { TOOL_UPDATE_SPECS, updateSpecFor, fetchNpmLatest } from "../src/update/specs";

// The per-tool table is the whole point of this module: a wrong subcommand
// (opencode `upgrade` vs `update`) or npm package silently breaks that tool's
// update path. Pin the load-bearing values.
describe("TOOL_UPDATE_SPECS", () => {
  it("maps each supported tool to its updater subcommand + npm package", () => {
    expect(TOOL_UPDATE_SPECS.codex).toMatchObject({
      npmPackage: "@openai/codex", command: "codex", updateArgs: ["update"],
    });
    expect(TOOL_UPDATE_SPECS.opencode).toMatchObject({
      npmPackage: "opencode-ai", command: "opencode", updateArgs: ["upgrade"],
    });
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
    expect(updateSpecFor("opencode")?.updateArgs).toEqual(["upgrade"]);
    expect(updateSpecFor("claude-code")?.command).toBe("claude");
  });

  it("returns null for a tool with no self-updater (fail-soft upstream)", () => {
    expect(updateSpecFor("github-copilot")).toBeNull();
    expect(updateSpecFor("nonsense")).toBeNull();
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
