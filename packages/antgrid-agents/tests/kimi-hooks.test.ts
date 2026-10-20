import { afterEach, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { inject, toPosts } from "../src/agents/kimi/hooks";

const dirs: string[] = [];
const parse = (text: string) => Bun.TOML.parse(text) as Record<string, unknown>;
afterEach(() => { for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true }); });
function fixture(content: string) {
  const kimiHome = mkdtempSync(join(tmpdir(), "antgrid-kimi-hooks-"));
  dirs.push(kimiHome);
  const path = join(kimiHome, "config.toml");
  writeFileSync(path, content);
  return { path, ctx: { abDir: kimiHome, kimiHome, hookCommand: { binary: "C:/Program Files/antgrid.exe", preargs: ["hook"] } } };
}

test("Kimi hook injection preserves user TOML and replaces its own command on relocation", () => {
  const original = '# user comment\ndefault_model = "test"\n[providers.test]\napi_key = "fixture"\n[[hooks]]\nevent = "Stop"\ncommand = "user-hook"\n';
  const { path, ctx } = fixture(original);
  expect(inject(ctx).observation?.titles).toBe(true);
  const first = readFileSync(path, "utf8");
  expect(first.startsWith(original)).toBe(true);
  expect((parse(first).hooks as any[])).toHaveLength(2);
  inject(ctx);
  expect(readFileSync(path, "utf8")).toBe(first);
  inject({ ...ctx, hookCommand: { binary: "new-bridge", preargs: ["hook"] } });
  const updated = parse(readFileSync(path, "utf8"));
  expect((updated.hooks as any[])).toHaveLength(2);
  expect((updated.hooks as any[])[0].command).toBe("user-hook");
  expect((updated.hooks as any[])[1].command).toContain("new-bridge");
  expect(updated.providers).toEqual({ test: { api_key: "fixture" } });
});

test("Kimi hook injection refuses invalid config without replacing it", () => {
  const { path, ctx } = fixture("not valid toml !!!");
  expect(inject(ctx).notificationsInjected).toBe(false);
  expect(readFileSync(path, "utf8")).toBe("not valid toml !!!");
});

test("Kimi hook injection extends an empty inline hooks array and keeps following tables", () => {
  const { path, ctx } = fixture('hooks = [] # user setting\n[identity]\nname = "Example"\n');
  expect(inject(ctx).observation?.titles).toBe(true);
  const parsed = parse(readFileSync(path, "utf8"));
  expect(parsed.identity).toEqual({ name: "Example" });
  expect((parsed.hooks as any[])).toHaveLength(1);
  inject(ctx);
  expect((parse(readFileSync(path, "utf8")).hooks as any[])).toHaveLength(1);
});

test("Kimi hook injection does not mistake marker text inside a user string for its own block", () => {
  const original = 'description = """\n# BEGIN ANTGRID KIMI IDENTITY\n[[hooks]]\nevent = "Stop"\n# END ANTGRID KIMI IDENTITY\n"""\n';
  const { path, ctx } = fixture(original);
  expect(inject(ctx).observation?.titles).toBe(true);
  inject(ctx);
  expect(parse(readFileSync(path, "utf8")).description).toBe(parse(original).description);
});

test("Kimi hook injection leaves a non-empty inline hooks array untouched, since Kimi rejects one beside a hook table", () => {
  const original = 'default_model = "x"\nhooks = [{ event = "Stop", command = "echo done" }]\n[providers.a]\nkey = "v"\n';
  const { path, ctx } = fixture(original);
  expect(inject(ctx).notificationsInjected).toBe(false);
  expect(readFileSync(path, "utf8")).toBe(original);
});

test("Kimi hook injection recognises its own hooks by command, with or without markers, wherever they sit", () => {
  const stale = (binary: string) => `[[hooks]]\nevent = "SessionStart"\ncommand = ${JSON.stringify(`"${binary}" "hook" "kimi" "session-start"`)}\ntimeout = 5\n`;
  const original = `default_model = "x"\n\n${stale("C:/Program Files/WindowsApps/Antgrid_1.0.0.0_x64/antgrid.exe")}\n`
    + `[[hooks]]\nevent = "Stop"\ncommand = "user-hook"\n\n${stale("C:/old/antgrid.exe")}\n[providers.a]\nkey = "v"\n`;
  const { path, ctx } = fixture(original);
  expect(inject(ctx).observation?.titles).toBe(true);
  const settled = readFileSync(path, "utf8");
  const parsed = parse(settled);
  expect((parsed.hooks as any[]).map((hook) => hook.command)).toEqual(["user-hook", expect.stringContaining("C:/Program Files/antgrid.exe")]);
  expect(parsed.providers).toEqual({ a: { key: "v" } });
  inject(ctx);
  expect(readFileSync(path, "utf8")).toBe(settled);
});

test("Kimi's hook starts the bridge binary only inside an Antgrid terminal", () => {
  const { path, ctx } = fixture("");
  const dir = mkdtempSync(join(tmpdir(), "antgrid-kimi-hook-run-"));
  dirs.push(dir);
  const marker = join(dir, "ran.txt");
  const binary = join(dir, process.platform === "win32" ? "fake bridge.cmd" : "fake bridge");
  writeFileSync(binary, process.platform === "win32" ? `@echo %*> "${marker}"\r\n` : `#!/bin/sh\necho "$@" > '${marker}'\n`);
  if (process.platform !== "win32") chmodSync(binary, 0o755);
  inject({ ...ctx, hookCommand: { binary, preargs: ["hook"] } });
  const [hook] = parse(readFileSync(path, "utf8")).hooks as any[];
  // How Node's `shell: true`, which Kimi's hook runner uses, hands a command to the shell.
  const run = (env: Record<string, string>) => Bun.spawnSync(process.platform === "win32"
    ? [process.env.ComSpec ?? "cmd.exe", "/d", "/s", "/c", `"${hook.command}"`]
    : ["/bin/sh", "-c", hook.command], { env: { PATH: process.env.PATH ?? "", SystemRoot: process.env.SystemRoot ?? "", ...env }, windowsVerbatimArguments: true, stdin: "ignore" });
  expect(run({}).exitCode).toBe(0);
  expect(existsSync(marker)).toBe(false);
  expect(run({ ANTGRID_TERMINAL_ID: "slot" }).exitCode).toBe(0);
  expect(readFileSync(marker, "utf8").trim()).toBe(process.platform === "win32" ? '"hook" "kimi" "session-start"' : "hook kimi session-start");
});

test("Kimi session-start reports the native identity only for an owned terminal", async () => {
  const input = JSON.stringify({ session_id: "session_test", session_title: "Test", client_type: "kimi_code_cli" });
  const invocation = { agent: "kimi", event: "session-start" };
  const ctx = { port: 1234, terminalId: "terminal", readStdin: async () => input };
  expect(await toPosts(invocation, ctx)).toEqual([{ port: 1234, path: "/session-title", body: { terminalId: "terminal", sessionId: "session_test", agent: "kimi", title: "Test" } }]);
  expect(await toPosts(invocation, { ...ctx, terminalId: undefined })).toEqual([]);
  expect(await toPosts(invocation, { ...ctx, readStdin: async () => '{"session_id":123}' })).toEqual([]);
});
