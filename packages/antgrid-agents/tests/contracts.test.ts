import { expect, test } from "bun:test";
import { join } from "node:path";

test("contracts have no eager provider or SDK dependencies", async () => {
  const result = await Bun.build({
    entrypoints: [join(import.meta.dir, "../src/contracts.ts")],
    target: "bun",
    plugins: [{
      name: "contracts-boundary",
      setup(build) {
        build.onResolve({ filter: /claude-agent-sdk|opencode-ai|agents[\\/](?:codex|claude-code|opencode)/ }, (args) => {
          throw new Error(`Contracts loaded a provider: ${args.path}`);
        });
      },
    }],
  });
  expect(result.success).toBe(true);
});
