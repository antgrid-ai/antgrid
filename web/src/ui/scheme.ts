// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

// Browser-side. The scheme the page is actually showing, for third-party
// overlays (Paddle) that draw outside our stylesheet and have to be told.
// The override attribute wins over the OS, exactly as `color-scheme` resolves
// it in styles.css; reading a `--color-*` token instead would hand back the
// unresolved `light-dark()` string.
export function resolvedScheme(): "light" | "dark" {
  const pinned = document.documentElement.dataset.theme;
  if (pinned === "light" || pinned === "dark") return pinned;
  return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}
