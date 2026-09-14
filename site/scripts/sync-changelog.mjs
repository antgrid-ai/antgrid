// Pulls the release SPINE — tag, date, URL — from the public repo into
// src/data/changelog-releases.ts. It never touches prose: the notes live in
// src/data/changelog.ts, hand-written and keyed by version. Two files rather
// than one is the whole design. This script rewrites its file wholesale on
// every run, so if the notes shared it they would have to be parsed back out of
// a generated artefact and merged, and the first malformed entry would eat
// someone's writing. Split, the machine half is disposable and the human half
// is never opened by a machine at all.
//
// Run after cutting a release:  bun run sync:changelog
//
// The BUILD stays offline. The generated module is committed, for the same
// reason astro.config.mjs reads fonts out of node_modules instead of fetching
// them: a cold CI build must not need network, and api.github.com being slow or
// rate limited must never be able to fail a site deploy that has nothing to do
// with the changelog.
import { writeFile } from "node:fs/promises";

const REPO = "antgrid-ai/antgrid";

// A .ts module rather than a .json file. Astro imports either happily, but the
// Playwright suite imports src/data/changelog.ts directly to count rows against
// the data, and a transitive JSON import under that runtime needs an
// `with { type: "json" }` attribute the TS side does not want. A module
// sidesteps the question, types the array where it is defined instead of at a
// cast, and can carry the do-not-edit header a JSON file has nowhere to put.
const OUT = new URL("../src/data/changelog-releases.ts", import.meta.url);

// Authenticate on shared runners to avoid the unauthenticated rate-limit pool.
const token = process.env.GITHUB_TOKEN ?? process.env.GH_TOKEN;

const headers = {
  accept: "application/vnd.github+json",
  "x-github-api-version": "2022-11-28",
  "user-agent": "antgrid-site-changelog-sync",
  ...(token ? { authorization: `Bearer ${token}` } : {}),
};

const raw = [];
let nextUrl = `https://api.github.com/repos/${REPO}/releases?per_page=100`;
// Fetch the complete history before writing anything: later-page failures must
// not replace the committed spine with a truncated one.
while (nextUrl) {
  const res = await fetch(nextUrl, { headers });
  if (!res.ok) {
    // Loud and non-zero. A sync that quietly wrote nothing would leave the page
    // silently a release behind, which is the one failure mode a changelog cannot
    // have: nobody checks a page for something that is missing.
    console.error(`GitHub returned ${res.status} ${res.statusText} for ${REPO} releases`);
    console.error(await res.text());
    process.exit(1);
  }

  raw.push(...await res.json());
  nextUrl = res.headers.get("link")?.split(",")
    .map((link) => link.match(/<([^>]+)>;\s*rel="next"/))
    .find(Boolean)?.[1];
}

const releases = raw
  // A draft is not public and a prerelease is not what /download serves, so
  // neither belongs on a page whose only job is to say what shipped.
  .filter((r) => !r.draft && !r.prerelease)
  .map((r) => ({
    version: r.tag_name,
    // The DATE only, in UTC. Storing the full instant would render differently
    // depending on where the build ran, so two CI runs of an unchanged file
    // could disagree about which day a release landed.
    date: r.published_at.slice(0, 10),
    url: r.html_url,
    // Set by the release tooling when a build carried nothing a user would
    // notice. Keyed off the generated sentence rather than off the PR list,
    // because "which of these seventeen PRs is user-facing" is a judgement and
    // this is a label the release already applied to itself. If that wording
    // changes this quietly stops finding them and those builds render as
    // ordinary un-noted entries, which is the safe direction to fail: a
    // maintenance build shown as "full notes on GitHub" is merely dull, where an
    // ordinary build mislabelled "nothing to see here" is a lie.
    maintenance: /no user-facing changes/i.test(r.body ?? ""),
  }))
  // Newest first, and by DATE rather than by tag: the version scheme is
  // build-numbered, so two tags can share a day (v1.20698.1007 and .1008 did)
  // and a string sort on them is only accidentally chronological.
  .sort((a, b) => (a.date < b.date ? 1 : a.date > b.date ? -1 : a.version < b.version ? 1 : -1));

if (releases.length === 0) {
  console.error("No published releases came back. Refusing to write an empty changelog.");
  process.exit(1);
}

// The header is the only defence a generated file has against being hand-edited.
const file = [
  "// GENERATED FILE - do not edit by hand.",
  "// Rewritten wholesale by scripts/sync-changelog.mjs (`bun run sync:changelog`).",
  "// Release notes are hand-written and live in ./changelog.ts; nothing you write",
  "// here survives the next sync.",
  'import type { Release } from "./changelog";',
  "",
  `export const RELEASES: Release[] = ${JSON.stringify(releases, null, 2)};`,
  "",
].join("\n");

await writeFile(OUT, file);
console.log(`wrote src/data/changelog-releases.ts (${releases.length} releases, latest ${releases[0].version})`);
