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
              <AccountMenu email={user.email} />
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
        {user && (
          <script dangerouslySetInnerHTML={{ __html: ACCOUNT_MENU_SCRIPT }} />
        )}
      </body>
    </html>
  );
}

/**
 * The account menu, a native `<details>` rather than daisyUI's `.dropdown`.
 *
 * daisyUI's variant opens on `:focus-within`, so clicking the trigger while the
 * menu is open re-focuses it instead of closing, and its `.menu` list styling
 * centres a `<button>` child while left-aligning an `<a>` — the sign-out row and
 * the account row did not line up. A disclosure has neither problem and
 * announces its own expanded state without an `aria-expanded` we would have to
 * maintain in script.
 *
 * The address appears here and NOT in the trigger: it is one string, and the
 * header showing it beside a menu that repeats it verbatim was the same fact
 * twice. Here it is also on phones, where the trigger has always been the
 * avatar alone.
 */
function AccountMenu({ email }: { email?: string | null }) {
  return (
    <details class="group relative shrink-0" data-account-menu>
      <summary
        class="flex cursor-pointer list-none items-center gap-1 rounded-field p-1 hover:bg-chrome group-open:bg-chrome [&::-webkit-details-marker]:hidden"
        aria-label="Account menu"
      >
        <span class="flex h-7 w-7 items-center justify-center rounded-full bg-indigodeep font-mono text-xs text-indigo2 ring-1 ring-indigo/25">
          {initials(email)}
        </span>
        <ChevronIcon />
      </summary>
      <div class="absolute right-0 top-full z-20 mt-2 w-64 overflow-hidden rounded-box border border-edge bg-panel shadow-lg shadow-black/40">
        <div class="border-b border-edge-inner px-3.5 py-2.5">
          <div class="text-[0.6875rem] font-medium uppercase tracking-[0.12em] text-muted2">
            Signed in as
          </div>
          {/* `break-all`, not `truncate`: the address is what tells you WHICH
              account you are about to sign out of, so a long one wraps rather
              than losing its domain to an ellipsis. */}
          <div class="mt-0.5 break-all font-mono text-[0.8125rem] leading-snug text-ink2">
            {email}
          </div>
        </div>
        <div class="p-1">
          <a
            href="/account"
            class="flex items-center gap-2.5 rounded-field px-2.5 py-2 text-sm text-ink2 hover:bg-chrome hover:text-ink"
          >
            <PersonIcon />
            Account
          </a>
        </div>
        <form method="post" action="/logout" class="border-t border-edge-inner p-1">
          {/* Not permanently red. Signing out is routine and reversible; danger
              on hover marks it as the row that ends the session without the
              menu shouting one of its two items at every open. */}
          <button
            type="submit"
            class="flex w-full items-center gap-2.5 rounded-field px-2.5 py-2 text-sm text-muted hover:bg-danger/10 hover:text-danger"
          >
            <SignOutIcon />
            Sign out
          </button>
        </form>
      </div>
    </details>
  );
}

/** 16-unit box, 1.5 stroke, round caps — the icon metrics pricing.tsx set. */
function ChevronIcon() {
  return (
    <svg
      class="h-3.5 w-3.5 shrink-0 text-muted2 transition-transform duration-150 group-open:rotate-180"
      viewBox="0 0 16 16"
      fill="none"
      aria-hidden="true"
    >
      <path
        d="M4 6.5l4 4 4-4"
        stroke="currentColor"
        stroke-width="1.5"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
    </svg>
  );
}

function PersonIcon() {
  return (
    <svg class="h-4 w-4 shrink-0 text-muted2" viewBox="0 0 16 16" fill="none" aria-hidden="true">
      <circle cx="8" cy="5.25" r="2.5" stroke="currentColor" stroke-width="1.5" />
      <path
        d="M2.75 13.5a5.25 5.25 0 0110.5 0"
        stroke="currentColor"
        stroke-width="1.5"
        stroke-linecap="round"
      />
    </svg>
  );
}

function SignOutIcon() {
  return (
    <svg class="h-4 w-4 shrink-0" viewBox="0 0 16 16" fill="none" aria-hidden="true">
      <path
        d="M6 14H3.25A1.25 1.25 0 012 12.75V3.25A1.25 1.25 0 013.25 2H6M10.5 11L14 8l-3.5-3M14 8H6"
        stroke="currentColor"
        stroke-width="1.5"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
    </svg>
  );
}

/**
 * A `<details>` closes on its own summary but not on a click elsewhere or on
 * Escape, which is what makes the difference between a disclosure and a menu.
 * Rendered only for signed-in pages, where the menu exists.
 */
const ACCOUNT_MENU_SCRIPT = `
document.addEventListener("click", function (e) {
  document.querySelectorAll("details[data-account-menu][open]").forEach(function (d) {
    if (!d.contains(e.target)) d.open = false;
  });
});
document.addEventListener("keydown", function (e) {
  if (e.key !== "Escape") return;
  document.querySelectorAll("details[data-account-menu][open]").forEach(function (d) {
    d.open = false;
    var s = d.querySelector("summary");
    if (s) s.focus();
  });
});
`;

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
