import { describe, it, expect } from "bun:test";
import { writeFileSync, mkdtempSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { loadConfig } from "../src/config";

function writeTemp(yaml: string): string {
  const dir = mkdtempSync(join(tmpdir(), "antgrid-cfg-"));
  const path = join(dir, "antgrid.yaml");
  writeFileSync(path, yaml, "utf8");
  return path;
}

describe("config schema", () => {
  it("accepts a fully-specified new-schema config", () => {
    const path = writeTemp(`
name: demo
relayUrl: wss://relay.example.com
agent:
  tool: claude-code
  flags: [--dangerously-skip-permissions]
  workingDir: packages/app
services:
  - name: dev
    command: npm run dev
  - name: docker
    command: docker compose up
    autoStart: false
commands:
  - name: Test
    command: bun test
  - name: Deploy
    command: npm run deploy
    confirm: true
    description: Deploys to production
    icon: rocket
ports:
  - 3000
  - port: 8080
    name: api
    onDetect: silent
  - port: 5432
    onDetect: ignore
`);
    const cfg = loadConfig(path);
    expect(cfg.name).toBe("demo");
    expect(cfg.relayUrl).toBe("wss://relay.example.com");
    expect(cfg.agent?.tool).toBe("claude-code");
    expect(cfg.agent?.flags).toEqual(["--dangerously-skip-permissions"]);
    expect(cfg.services?.[0].name).toBe("dev");
    expect(cfg.services?.[1].autoStart).toBe(false);
    expect(cfg.commands?.[1].confirm).toBe(true);
    // shorthand port normalizes to object
    expect(cfg.ports?.[0]).toEqual({ port: 3000, onDetect: "notify" });
    expect(cfg.ports?.[1]).toEqual({ port: 8080, name: "api", onDetect: "silent" });
    expect(cfg.ports?.[2]).toEqual({ port: 5432, onDetect: "ignore" });
  });

  it("treats every field as optional (empty file loads)", () => {
    const path = writeTemp("");
    const cfg = loadConfig(path);
    expect(cfg).toEqual({});
  });

  it("rejects unknown top-level fields from the old schema", () => {
    const path = writeTemp("terminals:\n  - name: x\n    command: echo\n");
    expect(() => loadConfig(path)).toThrow(/terminals|Unrecognized/);
  });

  it("defaults port onDetect to notify", () => {
    const path = writeTemp("ports:\n  - port: 3000\n");
    const cfg = loadConfig(path);
    expect(cfg.ports?.[0].onDetect).toBe("notify");
  });
});
