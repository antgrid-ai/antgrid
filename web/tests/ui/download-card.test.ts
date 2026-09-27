// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { describe, test, expect } from "bun:test";
import { DownloadCard } from "../../src/ui/download-card.js";

describe("DownloadCard", () => {
  test("links the site download page and the quickstart", () => {
    const html = DownloadCard().toString();
    expect(html).toContain('href="https://antgrid.ai/download"');
    expect(html).toContain('href="https://antgrid.ai/get-started"');
    expect(html).toContain("Download the desktop app");
  });
});
