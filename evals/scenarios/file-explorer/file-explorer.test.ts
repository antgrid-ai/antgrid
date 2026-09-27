import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { setupTestEnv, type TestEnv } from "../../helpers/harness";
import { createMessage } from "../../../bridge/src/protocol";
import { bindFirstProject } from "../../support/stream";

describe("file-explorer", () => {
  let env: TestEnv;
  let streamId: string;

  beforeAll(async () => {
    env = await setupTestEnv({ fixtureName: "basic" });
    // v3: project state + verbs run on the firstProject stream, not the control
    // plane. bindFirstProject resolves the streamId and pulls the per-project
    // snapshot (agent:status / git:status / …) the app caches on bind; the file
    // tree is no longer part of it — it is fetched lazily below.
    ({ streamId } = await bindFirstProject(env.app, env.projectId, 10_000));
  }, 60_000);

  afterAll(async () => {
    await env?.teardown();
  });

  test("lists the root on request, then lazily expands a subdirectory", async () => {
    env.app.sendOnStream(streamId, createMessage("file:tree:root:request", {}));
    const root = await env.app.waitForStreamAbType(streamId, "file:tree:children", 5_000);
    const rootListing = root.listings.find((l) => l.path === "");
    expect(rootListing).toBeDefined();
    expect(rootListing!.missing).toBeUndefined();
    const rootNames = rootListing!.children.map((n) => n.name);
    expect(rootNames).toContain("README.md");
    expect(rootNames).toContain("src");

    env.app.sendOnStream(streamId, createMessage("file:tree:children:request", { paths: ["src"] }));
    const children = await env.app.waitForStreamAbType(streamId, "file:tree:children", 5_000);
    const srcListing = children.listings.find((l) => l.path === "src");
    expect(srcListing).toBeDefined();
    const srcNames = srcListing!.children.map((n) => n.name);
    expect(srcNames).toContain("index.ts");
    expect(srcNames).toContain("utils.ts");
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
