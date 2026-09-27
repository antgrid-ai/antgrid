// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { tryGetContext } from "hono/context-storage";
import { getCookie } from "hono/cookie";

/** The reader's stored colour-scheme override; absent means follow the OS. */
export type Theme = "light" | "dark";

/** Written by the marketing site's footer toggle on the antgrid.ai apex, so a
 *  reader who crosses into this service mid sign-in keeps their choice. The
 *  name and scope are the whole contract with site/src/scripts/theme.ts. */
export const THEME_COOKIE = "antgrid-theme";

/** The override for the request being rendered, read through Hono's context
 *  storage so `Layout` needs no request prop. Outside a request (unit tests
 *  rendering `Layout` directly) there is no context and no override. */
export function currentTheme(): Theme | undefined {
  const c = tryGetContext();
  if (!c) return undefined;
  const v = getCookie(c, THEME_COOKIE);
  return v === "light" || v === "dark" ? v : undefined;
}

export const THEME_CHOICES = [
  ["system", "System"],
  ["light", "Light"],
  ["dark", "Dark"],
] as const;

/** Chrome takes the first theme-color meta whose `media` matches, so the
 *  override is expressed by flipping `media`, never by reordering the metas. */
export function themeColorMedia(scheme: Theme, theme: Theme | undefined): string {
  if (!theme) return `(prefers-color-scheme: ${scheme})`;
  return scheme === theme ? "all" : "not all";
}

/**
 * The client half: the same logic as the marketing site's
 * site/src/scripts/theme.ts, carried here as an inline string across the
 * licence boundary for the same reason the font faces are copied verbatim —
 * this service has no bundle the site's module could be shared into. Keep the
 * two in step by hand: same cookie name, same scope, same meta flip.
 */
export const THEME_TOGGLE_SCRIPT = `
(function () {
  var COOKIE = "antgrid-theme";
  var QUERY = { light: "(prefers-color-scheme: light)", dark: "(prefers-color-scheme: dark)" };
  // One scope for set and clear: a cookie is only deleted by a Set-Cookie
  // whose Domain and Path match the one that stored it. On the apex so the
  // marketing site reads it too; host-only on localhost and previews.
  function scope() {
    var host = location.hostname;
    var apex = host === "antgrid.ai" || host.endsWith(".antgrid.ai");
    return "; Path=/; SameSite=Lax" + (apex ? "; Domain=antgrid.ai" : "") +
      (location.protocol === "https:" ? "; Secure" : "");
  }
  function reflect(choice) {
    document.querySelectorAll("[data-theme-choice]").forEach(function (btn) {
      btn.setAttribute("aria-pressed", String(btn.dataset.themeChoice === choice));
    });
  }
  function apply(choice) {
    var root = document.documentElement;
    if (choice === "system") {
      delete root.dataset.theme;
      document.cookie = COOKIE + "=; Max-Age=0" + scope();
    } else {
      root.dataset.theme = choice;
      document.cookie = COOKIE + "=" + choice + "; Max-Age=31536000" + scope();
    }
    document.querySelectorAll('meta[name="theme-color"][data-scheme]').forEach(function (meta) {
      var scheme = meta.dataset.scheme;
      meta.media = choice === "system" ? QUERY[scheme] : scheme === choice ? "all" : "not all";
    });
    reflect(choice);
  }
  document.querySelectorAll("[data-theme-choice]").forEach(function (btn) {
    btn.addEventListener("click", function () { apply(btn.dataset.themeChoice); });
  });
})();
`;
