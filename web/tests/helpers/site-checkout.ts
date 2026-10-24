// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

// The antgrid.ai site lives in antgrid-ai/antgrid-site, and a few tests here are
// the only thing holding its copies of web's numbers and colours to the real
// ones. CI sparse-checks the site out and sets ANTGRID_SITE_REPO; locally a
// sibling `../antgrid-site` clone is found too. Without either those tests
// skip — except in CI, where skipping would turn the check into a quiet green.
const REPO_ROOT = resolve(import.meta.dir, "../../..");

export const SITE_REPO = [process.env.ANTGRID_SITE_REPO, resolve(REPO_ROOT, "../antgrid-site")]
  .filter((dir): dir is string => !!dir)
  .find((dir) => existsSync(resolve(dir, "src/styles/global.css")));

if (!SITE_REPO && process.env.CI) {
  throw new Error("No antgrid-site checkout found; set ANTGRID_SITE_REPO");
}

export function siteFile(path: string): string {
  if (!SITE_REPO) throw new Error(`No antgrid-site checkout to read ${path} from`);
  return readFileSync(resolve(SITE_REPO, path), "utf8");
}
