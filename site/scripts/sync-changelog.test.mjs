import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

const firstUrl = "https://api.github.com/repos/antgrid-ai/antgrid/releases?per_page=100";
const secondUrl = `${firstUrl}&page=2`;
const thirdUrl = `${firstUrl}&page=3`;
const release = (n, extra = {}) => ({
  tag_name: `v${n}`,
  published_at: "2026-09-01T12:00:00Z",
  html_url: `https://github.com/antgrid-ai/antgrid/releases/tag/v${n}`,
  ...extra,
});

async function runSync(t, pages) {
  const dir = await mkdtemp(join(tmpdir(), "antgrid-changelog-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  await mkdir(join(dir, "scripts"));
  await mkdir(join(dir, "src", "data"), { recursive: true });
  await copyFile(new URL("./sync-changelog.mjs", import.meta.url), join(dir, "scripts", "sync-changelog.mjs"));
  const output = join(dir, "src", "data", "changelog-releases.ts");
  const notes = join(dir, "src", "data", "changelog.ts");
  await writeFile(output, "existing history");
  await writeFile(notes, "handwritten notes for v1");
  await writeFile(join(dir, "mock.mjs"), `
    import assert from "node:assert/strict";
    const pages = ${JSON.stringify(pages)};
    globalThis.fetch = async (url, { headers }) => {
      const page = pages.shift();
      assert.equal(url, page.url);
      assert.equal(headers.authorization, "Bearer test-token");
      return new Response(JSON.stringify(page.body), {
        status: page.status ?? 200,
        headers: page.link ? { link: page.link } : {},
      });
    };
    process.on("exit", () => assert.equal(pages.length, 0));
  `);
  const result = spawnSync(process.execPath, ["--import", "./mock.mjs", "scripts/sync-changelog.mjs"], {
    cwd: dir,
    encoding: "utf8",
    env: { ...process.env, GITHUB_TOKEN: "test-token" },
  });
  assert.ifError(result.error);
  assert.equal(await readFile(notes, "utf8"), "handwritten notes for v1");
  return { ...result, output: await readFile(output, "utf8") };
}

test("keeps older releases across all pages, including pages containing only excluded releases", async (t) => {
  const result = await runSync(t, [
    { url: firstUrl, body: Array.from({ length: 100 }, (_, i) => release(i + 2)), link: `<${thirdUrl}>; rel="last", <${secondUrl}>; rel="next"` },
    { url: secondUrl, body: [release(102, { draft: true }), release(103, { prerelease: true })], link: `<${firstUrl}>; rel="prev", <${thirdUrl}>; rel="next"` },
    { url: thirdUrl, body: [release(1, { body: "No user-facing changes" })], link: `<${secondUrl}>; rel="prev"` },
  ]);
  assert.equal(result.status, 0, result.stderr);
  const releases = JSON.parse(result.output.match(/= (\[[\s\S]*\]);/)[1]);
  assert.equal(releases.length, 101);
  assert.deepEqual(releases.find((r) => r.version === "v1"), {
    version: "v1", date: "2026-09-01", url: release(1).html_url, maintenance: true,
  });
  assert.ok(!releases.some((r) => ["v102", "v103"].includes(r.version)));
});

test("preserves existing history when a later page fails", async (t) => {
  const result = await runSync(t, [
    { url: firstUrl, body: [release(2)], link: `<${secondUrl}>; rel="next"` },
    { url: secondUrl, status: 503, body: { message: "Unavailable" } },
  ]);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /GitHub returned 503/);
  assert.equal(result.output, "existing history");
});
