import { afterEach, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { inject, toPosts } from "../src/agents/mistral-vibe/hooks";

const dirs: string[] = [];
const parse = (text: string) => Bun.TOML.parse(text) as Record<string, unknown>;
afterEach(() => { for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true }); });
function fixture(content?: string) {
  const vibeHome = mkdtempSync(join(tmpdir(), "antgrid-vibe-hooks-"));
  dirs.push(vibeHome);
  const path = join(vibeHome, "hooks.toml");
  if (content !== undefined) writeFileSync(path, content);
  return { path, ctx: { abDir: vibeHome, vibeHome, hookCommand: { binary: "C:/Program Files/antgrid.exe", preargs: ["hook"] } } };
}

test("Vibe injects a guarded post_agent hook without changing other config", () => {
  const original = '# user comment\n[[hooks]]\nname = "mine"\ntype = "post_agent"\ncommand = "user-hook"\n';
  const { path, ctx } = fixture(original);
  expect(inject(ctx).observation?.titles).toBe(true);
  const first = readFileSync(path, "utf8");
  expect(first.startsWith(original)).toBe(true);
  const hooks = parse(first).hooks as Array<Record<string, unknown>>;
  expect(hooks).toHaveLength(2);
  expect(hooks[1]).toMatchObject({ name: "antgrid-identity", type: "post_agent", timeout: 5 });
  expect(hooks[1]!.command).toContain("ANTGRID_TERMINAL_ID");
  expect(hooks[1]!.command).toContain("mistral-vibe");
  inject(ctx);
  expect(readFileSync(path, "utf8")).toBe(first);
});

test("Vibe replaces its own command when the bridge relocates", () => {
  const { path, ctx } = fixture();
  inject(ctx);
  inject({ ...ctx, hookCommand: { binary: "new-bridge", preargs: ["hook"] } });
  const hooks = parse(readFileSync(path, "utf8")).hooks as Array<Record<string, unknown>>;
  expect(hooks).toHaveLength(1);
  expect(hooks[0]!.command).toContain("new-bridge");
});

test("Vibe creates the hooks file when none exists", () => {
  const { path, ctx } = fixture();
  expect(existsSync(path)).toBe(false);
  inject(ctx);
  expect((parse(readFileSync(path, "utf8")).hooks as unknown[])).toHaveLength(1);
});

test("Vibe refuses invalid config without replacing it", () => {
  const { path, ctx } = fixture("not valid toml !!!");
  expect(inject(ctx).notificationsInjected).toBe(false);
  expect(readFileSync(path, "utf8")).toBe("not valid toml !!!");
});

test("Vibe refuses a non-empty inline hooks array", () => {
  const original = 'hooks = [{ name = "a", type = "post_agent", command = "x" }]\n';
  const { path, ctx } = fixture(original);
  expect(inject(ctx).notificationsInjected).toBe(false);
  expect(readFileSync(path, "utf8")).toBe(original);
});

const postCtx = (stdin: object) => ({ port: 1, terminalId: "t1", readStdin: async () => JSON.stringify(stdin) }) as never;
const invocation = (event: string) => ({ agent: "mistral-vibe", event });

test("Vibe toPosts reports the session id and transcript path", async () => {
  const posts = await toPosts(invocation("post-agent"), postCtx({ session_id: "s1", transcript_path: "/v/session_x/messages.jsonl", cwd: "/r", parent_session_id: null }));
  expect(posts).toEqual([{ port: 1, path: "/session-title", body: { terminalId: "t1", sessionId: "s1", agent: "mistral-vibe", transcriptPath: "/v/session_x/messages.jsonl" } }]);
});

test("Vibe toPosts keeps a session whose store sits under an agents directory", async () => {
  const posts = await toPosts(invocation("post-agent"), postCtx({ session_id: "s1", transcript_path: "C:\\Users\\u\\agents\\.vibe\\logs\\session\\session_x\\messages.jsonl" }));
  expect(posts).toHaveLength(1);
});

test("Vibe toPosts keeps a cleared session that names a parent", async () => {
  const posts = await toPosts(invocation("post-agent"), postCtx({ session_id: "s2", transcript_path: "/v/s/messages.jsonl", parent_session_id: "s1" }));
  expect(posts).toHaveLength(1);
});

test("Vibe toPosts drops subagent transcripts and an empty transcript path is not forwarded", async () => {
  expect(await toPosts(invocation("post-agent"), postCtx({ session_id: "s1", transcript_path: "/v/s/agents/task_1/messages.jsonl" }))).toEqual([]);
  expect(await toPosts(invocation("post-agent"), postCtx({ session_id: "s1", transcript_path: "C:\\v\\s\\agents\\task_1\\messages.jsonl" }))).toEqual([]);
  const [post] = await toPosts(invocation("post-agent"), postCtx({ session_id: "s1", transcript_path: "" }));
  expect(post!.body).not.toHaveProperty("transcriptPath");
});
