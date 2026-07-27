import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { setupDartTestEnv, type DartTestEnv } from "../../helpers/harness";

/**
 * Dart File Explorer E2E — mirrors file-explorer.test.ts but routes through
 * the real Dart client to exercise the production Dart crypto and relay code
 * paths for file tree + content messages.
 */
// setupDartTestEnv admits the Dart client via account trust, but the Dart
// eval CLI's `_handleHandshake` (packages/antgrid_eval_client/lib/src/commands.dart)
// addresses the agent via `_relay.currentState.peerDeviceId`, which nothing
// sets any more — its JSON action protocol has no `handshake` param to target
// an agent directly, so a pair-free Dart handshake cannot succeed until the
// Dart CLI grows one (see harness.ts's `setupDartTestEnv`).
describe.skip("dart-file-explorer", () => {
  let env: DartTestEnv;

  beforeAll(async () => {
    env = await setupDartTestEnv({
      fixtureName: "basic",
      clientName: "eval-dart-files",
    });
    await env.app.waitForAgentStatus(10_000);
  }, 60_000);

  afterAll(async () => {
    await env?.teardown();
  });

  test("receives full file tree via Dart client", async () => {
    const tree = await env.app.waitForFileTree(10_000);
    expect(tree.data.projectId).toBe(env.projectId);
    expect(tree.data.root.type).toBe("directory");

    const flatNames = flattenTree(tree.data.root);
    expect(flatNames).toContain("README.md");
    expect(flatNames).toContain("index.ts");
    expect(flatNames).toContain("utils.ts");
  }, 15_000);

  test("reads file content via Dart client", async () => {
    const content = await env.app.requestFileContent(env.projectId, "README.md", 10_000);
    expect(content.data.type).toBe("file:content");
    expect(content.data.content).toContain("Eval Test Project");
    expect(content.data.size).toBeGreaterThan(0);
    expect(content.data.error).toBeUndefined();
  }, 15_000);

  // SKIPPED: the agent's chokidar watcher (confirmed running on the correct
  // temp-dir root) emits no add events for a cross-process write inside the
  // long-running agent on Windows, even with polling — yet identical standalone
  // chokidar detects it. A Bun+chokidar runtime quirk in this eval setup, not a
  // protocol/pairing issue (tree:full + file:read pass). Real project dirs watch
  // fine in production. Re-enable once incremental watching is reliable here.
  test.skip("receives incremental tree update on file creation", async () => {
    writeFileSync(join(env.projectDir, "dart-created.txt"), "created during dart eval");

    const update = await env.app.waitForTreeUpdate(10_000);
    expect(update.data.projectId).toBe(env.projectId);
    expect(update.data.added.length).toBeGreaterThan(0);

    const addedNames = update.data.added.map((n: any) => n.name);
    expect(addedNames).toContain("dart-created.txt");
  }, 15_000);
});

function flattenTree(node: any): string[] {
  const names: string[] = [];
  if (node.name) names.push(node.name);
  if (node.children) {
    for (const child of node.children) {
      names.push(...flattenTree(child));
    }
  }
  return names;
}
