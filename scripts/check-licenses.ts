import { $ } from "bun";
import { existsSync, statSync } from "node:fs";
import { extname } from "node:path";
import { brandPatterns, licenseForPath, requiresHeader, thirdPartyPatterns } from "./license-map";

const errors: string[] = [];
const tracked = (await $`git ls-files --cached --others --exclude-standard`.text()).split(/\r?\n/).filter(Boolean);
const sourceExtensions = new Set([
  ".c", ".cc", ".cpp", ".css", ".dart", ".h", ".hpp", ".js", ".jsx",
  ".astro", ".kt", ".kts", ".mjs", ".ps1", ".sh", ".swift", ".ts", ".tsx",
]);
const generated = [
  "app/linux/flutter/generated_",
  "app/macos/Flutter/Generated",
  "app/windows/flutter/generated_",
];
// In-file headers are required only on the licence boundary (see
// requiresHeader). Everywhere else REUSE.toml is the declaration and a header is
// optional — adding one is the standard reflex and `reuse lint` prefers it. Only
// a header that contradicts the map is an error, because that is the copy a
// reader believes.
for (const path of tracked) {
  const license = licenseForPath(path);
  const isSource = sourceExtensions.has(extname(path).toLowerCase())
    && !generated.some((prefix) => path.startsWith(prefix))
    && !thirdPartyPatterns.some((pattern) => pattern.test(path))
    && !brandPatterns.some((pattern) => pattern.test(path));
  if (!isSource) continue;
  const text = await Bun.file(path).text();
  const header = text.split(/\r?\n/).slice(0, 6).join("\n");
  if (requiresHeader(path)) {
    if (!header.includes(`SPDX-License-Identifier: ${license}`)) {
      errors.push(`${path}: missing SPDX-License-Identifier: ${license}`);
    }
    if (!header.includes("SPDX-FileCopyrightText:")) {
      errors.push(`${path}: SPDX header has no SPDX-FileCopyrightText line`);
    }
  } else if (
    header.includes("SPDX-License-Identifier:") &&
    !header.includes(`SPDX-License-Identifier: ${license}`)
  ) {
    errors.push(`${path}: SPDX header contradicts the map; this path is ${license}`);
  }
}

const canonicalMpl = await Bun.file("LICENSE.md").text();
// LICENSE.md is the MPL text de-indented so GitHub renders it as prose rather
// than a code block; LICENSES/MPL-2.0.txt is Mozilla's verbatim copy and the one
// `reuse lint` reads. The package copies below are byte-compared against
// LICENSE.md, so without this nothing would notice LICENSE.md itself drifting.
const collapse = (text: string) => text.replace(/\s+/g, " ").trim();
if (collapse(canonicalMpl) !== collapse(await Bun.file("LICENSES/MPL-2.0.txt").text())) {
  errors.push("LICENSE.md: differs from LICENSES/MPL-2.0.txt beyond whitespace");
}
for (const path of [
  "bridge/LICENSE",
  "packages/antgrid-agents/LICENSE",
  "packages/antgrid-wire/LICENSE",
  "packages/antgrid_relay_client/LICENSE",
  "packages/antgrid_eval_client/LICENSE",
]) {
  if (await Bun.file(path).text() !== canonicalMpl) {
    errors.push(`${path}: not an exact copy of the canonical MPL-2.0 text`);
  }
}
const canonicalElastic = await Bun.file("relay/LICENSE.md").text();
// Four copies of the ELv2 text exist; they drifted on the copyright line once,
// which is how an SBOM ends up naming a different licensor than the licence.
for (const path of ["web/LICENSE.md", "LICENSES/LicenseRef-Elastic-2.0.txt"]) {
  if (await Bun.file(path).text() !== canonicalElastic) {
    errors.push(`${path}: ELv2 text differs from relay/LICENSE.md`);
  }
}

for (const [source, bundled] of Object.entries({
  "LICENSE.md": "app/assets/legal/LICENSE.md",
  "LICENSING.md": "app/assets/legal/LICENSING.md",
  "THIRD-PARTY.md": "app/assets/legal/THIRD-PARTY.md",
  "BRAND-ASSETS-LICENSE.md": "app/assets/legal/BRAND-ASSETS-LICENSE.md",
  "SOURCE_OFFER.md": "app/assets/legal/SOURCE_OFFER.md",
  "relay/LICENSE.md": "app/assets/legal/ELASTIC-2.0.md",
})) {
  if (await Bun.file(source).text() !== await Bun.file(bundled).text()) {
    errors.push(`${bundled}: stale; run bun run sync:legal`);
  }
}

const packageLicenses: Record<string, string> = {
  "package.json": "MPL-2.0",
  "aspire/package.json": "MPL-2.0",
  "bridge/package.json": "MPL-2.0",
  "bridge/integrations/package.json": "MPL-2.0",
  "evals/package.json": "MPL-2.0",
  "packages/antgrid-agents/package.json": "MPL-2.0",
  "packages/antgrid-wire/package.json": "MPL-2.0",
  "relay/package.json": "LicenseRef-Elastic-2.0",
  "site/package.json": "MPL-2.0",
  "web/package.json": "LicenseRef-Elastic-2.0",
};
for (const [path, license] of Object.entries(packageLicenses)) {
  const json = await Bun.file(path).json() as { license?: string };
  if (json.license !== license) errors.push(`${path}: expected package licence ${license}`);
}

const reuse = await Bun.file("REUSE.toml").text();
const declaredIds = ["MPL-2.0", "LicenseRef-Elastic-2.0", "LicenseRef-Antgrid-Brand", "LicenseRef-Third-Party-Trademark", "OFL-1.1", "Apache-2.0", "MIT"];
for (const id of declaredIds) {
  if (!reuse.includes(`SPDX-License-Identifier = "${id}"`)) {
    errors.push(`REUSE.toml: missing annotation for ${id}`);
  }
  // REUSE requires the full text of every identifier used, under LICENSES/.
  // Without this, `reuse lint` fails on a tree that check:licenses calls clean.
  if (!(await Bun.file(`LICENSES/${id}.txt`).exists())) {
    errors.push(`LICENSES/${id}.txt: missing licence text for an identifier in use`);
  }
}
// Every SPDX identifier written anywhere in the tree must be one this map
// actually declares. That is what rejects a near-miss variant of MPL-2.0 —
// naming the bad variants explicitly would make this file trip its own check.
const knownIdentifiers = new Set(declaredIds);
const binaryPath = /\.(png|jpe?g|ico|svg|ttf|otf|woff2?|zip|gz|jar|dll|so|dylib|exe|lock|pdf|mp4|webp)$/i;
for (const path of tracked) {
  if (binaryPath.test(path) || !existsSync(path)) continue;
  const declarations = (await Bun.file(path).text())
    .matchAll(/SPDX-License-Identifier(?::\s*|\s*=\s*")([A-Za-z0-9.+-]+)/g);
  for (const declaration of declarations) {
    if (!knownIdentifiers.has(declaration[1]!)) {
      errors.push(`${path}: unrecognised SPDX identifier "${declaration[1]}"`);
    }
  }
}
// One copyright holder across the whole map: relay/ and web/ asserting a
// different one from everything else is how an SBOM ends up contradicting the
// files it describes.
for (const match of reuse.matchAll(/SPDX-FileCopyrightText = "([^"]+)"/g)) {
  const holder = match[1]!;
  const thirdParty = /JetBrains|Ghostty|Gradle|trademark/i.test(holder);
  if (!thirdParty && holder !== "2026 Radha AI Products") {
    errors.push(`REUSE.toml: first-party copyright holder is "${holder}"; expected "2026 Radha AI Products"`);
  }
}
const annotations = reuse
  .split("[[annotations]]")
  .slice(1)
  .map((block) => {
    const paths = block.match(/path = (\[[^\n]+\])/);
    const identifier = block.match(/SPDX-License-Identifier = "([^"]+)"/);
    if (paths == null || identifier == null) {
      throw new Error("REUSE.toml contains an incomplete annotation");
    }
    return {
      paths: JSON.parse(paths[1]!) as string[],
      identifier: identifier[1]!,
      override: block.includes('precedence = "override"'),
    };
  });
// Every tracked path, not only the header-less ones: REUSE.toml is now the
// primary declaration for most of the tree, so a gap in it is a gap outright.
for (const path of tracked) {
  {
    const license = licenseForPath(path);
    let identifiers: string[] = [];
    for (const annotation of annotations) {
      if (!annotation.paths.some((pattern) => new Bun.Glob(pattern).match(path))) continue;
      identifiers = annotation.override
        ? [annotation.identifier]
        : [...identifiers, annotation.identifier];
    }
    if (!identifiers.includes(license)) {
      errors.push(`${path}: REUSE maps ${identifiers.join(" AND ") || "nothing"}; expected ${license}`);
    }
  }
}

// Loose on the names, bounded to one sentence on the claim. What slipped past
// the first version of these read "only the wire and relay-client packages are
// Apache" — neither package spelled in full, no version on the licence — so
// matching the exact package name against the exact identifier caught nothing.
// `[^.\n]` is what stops the widened window reaching across a full stop into an
// unrelated sentence about an Apache-licensed dependency.
const staleClaims: Array<[RegExp, string]> = [
  [/antgrid[-_ ]?wire[^.\n]{0,80}Apache/i, "antgrid-wire is MPL-2.0"],
  [/relay[-_ ]?client[^.\n]{0,80}Apache/i, "antgrid_relay_client is MPL-2.0"],
  [/antgrid[-_ ]?agents[^.\n]{0,80}(ELv2|Elastic)/i, "antgrid-agents is MPL-2.0"],
];
for (const path of tracked.filter((file) => /\.(md|ts|tsx|dart|astro)$/.test(file))) {
  if (
    path === "THIRD-PARTY.md" ||
    path === "scripts/check-licenses.ts" ||
    path.startsWith("app/assets/legal/")
  ) continue;
  const text = await Bun.file(path).text();
  for (const [pattern, correction] of staleClaims) {
    if (pattern.test(text)) errors.push(`${path}: stale licence claim; ${correction}`);
  }
}

// The rebranding table in TRADEMARK.md pins exact current values against exact
// files, in a legal document no suite touches. Verify the doc rather than
// restate it here: every value in the "Current value" column must still appear
// in one of the files its "Defined in" column names. A rename that leaves the
// table behind tells a fork to change a string that no longer exists.
for (const line of (await Bun.file("TRADEMARK.md").text()).split(/\r?\n/)) {
  if (!line.startsWith("|")) continue;
  const cells = line.split("|").slice(1, -1).map((cell) => cell.trim());
  if (cells.length < 3) continue;
  const values = [...cells[1]!.matchAll(/`([^`]+)`/g)].map((match) => match[1]!);
  if (values.length === 0) continue;
  const named = [...cells[2]!.matchAll(/`([^`]+)`/g)].map((match) => match[1]!);
  // The same column names symbols as well as paths; keep the ones that are files.
  const files = named.filter((token) => existsSync(token) && statSync(token).isFile());
  if (files.length === 0) {
    errors.push(`TRADEMARK.md: row "${cells[0]}" names no file that exists`);
    continue;
  }
  const texts = await Promise.all(files.map((file) => Bun.file(file).text()));
  for (const value of values) {
    // Prose writes a URL scheme as `antgrid://`; the manifests hold it bare.
    const needle = value.endsWith("://") ? value.slice(0, -3) : value;
    if (!texts.some((text) => text.includes(needle))) {
      errors.push(`TRADEMARK.md: "${value}" no longer appears in ${files.join(", ")}`);
    }
  }
}

if (errors.length > 0) {
  console.error(errors.join("\n"));
  process.exit(1);
}
console.log(`Licence map OK (${tracked.length} tracked files)`);
