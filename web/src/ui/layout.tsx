import type { Child } from "hono/jsx";
import { asset } from "./asset.js";
import { BETA } from "../billing/plans.js";

/** Which nav entry the current page IS, so it can be marked. Pages without an
 *  entry of their own (account, sign-in, checkout) pass nothing. */
export type NavSection = "dashboard" | "devices" | "team" | "pricing";

export type LayoutProps = {
  title: string;
  user?: { email?: string | null } | null;
  section?: NavSection;
  children: Child;
};

function initials(email: string | null | undefined): string {
  if (!email) return "?";
  const local = email.split("@")[0] ?? email;
  return local.slice(0, 2).toUpperCase();
}

const NAV: { section: NavSection; href: string; label: string }[] = [
  { section: "dashboard", href: "/dashboard", label: "Dashboard" },
  { section: "devices", href: "/devices", label: "Devices" },
  // Shown to everyone: /team is a real page for a member too — it is where they
  // find out whose account they bill against.
  { section: "team", href: "/team", label: "Team" },
  { section: "pricing", href: "/pricing", label: "Pricing" },
];

export function Layout({ title, user, section, children }: LayoutProps) {
  return (
    <html lang="en" data-theme="dark">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        {/* --color-page. The browser paints this around and behind the document
            before any CSS lands, so a value that is not the page's own is a
            visible band on mobile. */}
        <meta name="theme-color" content="#101015" />
        <title>{title} · Antgrid</title>
        <link rel="icon" href="/logo/favicon.ico" sizes="any" />
        <link rel="icon" type="image/svg+xml" href="/logo/antgrid-favicon.svg" />
        <link rel="apple-touch-icon" href="/logo/apple-touch-icon-180.png" />
        {/* Both are in the first viewport on every page (Archivo in the page
            title, Inter in the nav and body), and without a preload neither is
            even requested until the render-blocking CSS has parsed — HTML, then
            CSS, then woff2, three serial round trips. Mono is deliberately not
            preloaded: it carries values further down the page, and a third
            preload competes with these two for the same connection. */}
        <link rel="preload" as="font" type="font/woff2" href={asset("fontDisplay")} crossorigin="anonymous" />
        <link rel="preload" as="font" type="font/woff2" href={asset("fontSans")} crossorigin="anonymous" />
        <link href={asset("styles")} rel="stylesheet" />
        <script src={asset("htmx")} defer></script>
      </head>
      <body class="min-h-screen bg-page font-sans text-ink">
        <header class="border-b border-edge bg-group">
          <div class="max-w-5xl mx-auto px-4 sm:px-6 h-14 flex items-center gap-3 sm:gap-6">
            {/* Badge sits INSIDE the home link so it reads as part of the
                lockup rather than a second announcement — and stays a span:
                an anchor here would nest, which is invalid, and a status
                marker is not a navigation target. */}
            <a href="/" class="flex shrink-0 items-center gap-2">
              <img
                src="/logo/antgrid-wordmark.svg"
                alt="antgrid"
                class="h-7 w-auto"
              />
              {BETA && (
                <span class="rounded-full bg-indigobtn px-1.5 py-px text-[0.59375rem] font-medium text-white">
                  beta
                </span>
              )}
            </a>
            {user && (
              // `min-w-0` + `overflow-x-auto`: four labels plus the wordmark and
              // the avatar do not fit a phone, and without this the nav pushes
              // the whole document wider than the viewport rather than scrolling
              // inside itself.
              <nav class="flex min-w-0 items-center gap-1 overflow-x-auto text-sm [scrollbar-width:none]">
                {NAV.map((item) => {
                  const here = item.section === section;
                  return (
                    <a
                      key={item.section}
                      href={item.href}
                      aria-current={here ? "page" : undefined}
                      class={
                        here
                          ? "shrink-0 rounded px-3 py-1.5 bg-chrome text-ink"
                          : "shrink-0 rounded px-3 py-1.5 text-muted hover:bg-chrome hover:text-ink"
                      }
                    >
                      {item.label}
                    </a>
                  );
                })}
              </nav>
            )}
            <div class="flex-1" />
            {user ? (
              <div class="dropdown dropdown-end">
                <div
                  tabindex={0}
                  role="button"
                  class="flex items-center gap-2 px-2 py-1 rounded hover:bg-chrome"
                >
                  <div class="avatar avatar-placeholder">
                    <div class="w-7 h-7 rounded-full bg-indigodeep text-indigo2 text-xs font-mono flex items-center justify-center">
                      <span>{initials(user.email)}</span>
                    </div>
                  </div>
                  <span class="font-mono text-sm text-muted hidden sm:inline">
                    {user.email}
                  </span>
                </div>
                <ul
                  tabindex={0}
                  class="dropdown-content menu menu-sm bg-panel border border-edge rounded-box shadow-lg mt-2 w-52 p-1 z-10"
                >
                  <li class="menu-title font-mono text-xs px-3 py-2 text-muted2 break-all">
                    {user.email}
                  </li>
                  <li>
                    <a href="/account">Account</a>
                  </li>
                  <li>
                    <form method="post" action="/logout" class="contents">
                      <button type="submit" class="text-danger">Sign out</button>
                    </form>
                  </li>
                </ul>
              </div>
            ) : user === null ? (
              // `null` = a product page being read signed out, where this is the
              // way in. `undefined` = an auth page, which IS the way in — there
              // it was a primary-styled button competing with the form's own
              // primary action and, on /login, pointing at the current page.
              <a href="/login" class="btn btn-primary btn-sm">
                Sign in
              </a>
            ) : null}
          </div>
        </header>
        <main class="max-w-5xl mx-auto p-6">{children}</main>
      </body>
    </html>
  );
}

/**
 * Page title plus its one-line answer to "what is this page for".
 *
 * Archivo is the display face and has none of Inter's small-size tuning, so it
 * appears here and in nothing smaller.
 */
export function PageHead({ title, children }: { title: string; children?: Child }) {
  return (
    <div class="mb-8">
      <h1 class="font-display text-3xl font-semibold tracking-[-0.026em]">{title}</h1>
      {children && <p class="mt-1.5 text-sm text-muted">{children}</p>}
    </div>
  );
}
