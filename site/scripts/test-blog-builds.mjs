import { spawnSync } from "node:child_process";
import assert from "node:assert/strict";

for (const [scenario, message] of [["invalid", "updatedAt cannot precede publishedAt"], ["conflicting", "Only one published blog post may be featured: one, two"]]) {
  const result = spawnSync(process.execPath, ["node_modules/astro/bin/astro.mjs", "build", "--config", "astro.blog-test.config.mjs"], {
    encoding: "utf8", timeout: 120_000,
    env: { ...process.env, ANTGRID_BLOG_SCENARIO: scenario },
  });
  if (result.error) throw result.error;
  assert.notEqual(result.status, 0, `${scenario} should fail the build`);
  assert.ok(`${result.stdout}\n${result.stderr}`.includes(message), `${scenario} failed for an unexpected reason:\n${result.stdout}\n${result.stderr}`);
  console.log(`PASS: ${scenario} rejected during the Astro build`);
}
