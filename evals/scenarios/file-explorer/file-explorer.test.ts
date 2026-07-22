import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { setupTestEnv, type TestEnv } from "../../helpers/harness";
import { createMessage, type AbMessage } from "../../../bridge/src/protocol";
import { bindFirstProject } from "../../support/stream";

describe("file-explorer", () => {
  let env: TestEnv;
  let streamId: string;
  let snapshot: AbMessage[];

  beforeAll(async () => {
    env = await setupTestEnv({ fixtureName: "basic" });
    // v3: project state + verbs run on the firstProject stream, not the control
    // plane. bindFirstProject resolves the streamId and pulls the per-project
    // snapshot (agent:status / tree:full / git:status) the app caches on bind.
    ({ streamId, frames: snapshot } = await bindFirstProject(env.app, env.projectId, 10_000));
  }, 60_000);

  afterAll(async () => {
    await env?.teardown();
  });

  test("receives full tree on bind", async () => {
    const tree = snapshot.find((f) => f.type === "tree:full") as Extract<AbMessage, { type: "tree:full" }> | undefined;
    expect(tree).toBeDefined();
    expect(tree!.projectId).toBe(env.projectId);
    expect(tree!.root).toBeDefined();
    expect(tree!.root.type).toBe("directory");

    const flatNames = flattenTree(tree!.root);
    expect(flatNames).toContain("README.md");
    expect(flatNames).toContain("index.ts");
    expect(flatNames).toContain("utils.ts");
  });

  test("can read file content over the stream", async () => {
    env.app.sendOnStream(streamId, createMessage("file:read", {
      projectId: env.projectId,
      path: "README.md",
    }));

    const content = await env.app.waitForStreamAbType(streamId, "file:content", 5_000);
    expect(content.path).toBe("README.md");
    expect(content.content).toContain("Eval Test Project");
  });
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
