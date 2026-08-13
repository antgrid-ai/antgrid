import type { Child } from "hono/jsx";
import { asset } from "./asset.js";

export type LayoutProps = {
  title: string;
  user?: { email?: string | null } | null;
  children: Child;
};

function initials(email: string | null | undefined): string {
  if (!email) return "?";
  const local = email.split("@")[0] ?? email;
  return local.slice(0, 2).toUpperCase();
}

export function Layout({ title, user, children }: LayoutProps) {
  return (
    <html lang="en" data-theme="dark">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="theme-color" content="#18181B" />
        <title>{title} · Antgrid</title>
        <link rel="icon" href="/logo/favicon.ico" sizes="any" />
        <link rel="icon" type="image/svg+xml" href="/logo/antgrid-favicon.svg" />
        <link rel="apple-touch-icon" href="/logo/apple-touch-icon-180.png" />
        <link href={asset("styles")} rel="stylesheet" />
        <script src={asset("htmx")} defer></script>
      </head>
      <body class="min-h-screen bg-base-200">
        <header class="border-b border-base-300 bg-base-100">
          <div class="max-w-5xl mx-auto px-6 h-14 flex items-center gap-6">
            <a href="/" class="flex items-center">
              <img
                src="/logo/antgrid-wordmark.svg"
                alt="antgrid"
                class="h-6 w-auto"
              />
            </a>
            {user && (
              <nav class="flex items-center gap-1 text-sm">
                <a
                  href="/dashboard"
                  class="px-3 py-1.5 rounded hover:bg-base-200 font-mono"
                >
                  Dashboard
                </a>
                <a href="/devices" class="px-3 py-1.5 rounded hover:bg-base-200 font-mono">
                  Devices
                </a>
                {/* Shown to everyone: /team is a real page for a member too —
                    it is where they find out whose account they bill against. */}
                <a href="/team" class="px-3 py-1.5 rounded hover:bg-base-200 font-mono">
                  Team
                </a>
                <a
                  href="/pricing"
                  class="px-3 py-1.5 rounded hover:bg-base-200 font-mono"
                >
                  Pricing
                </a>
              </nav>
            )}
            <div class="flex-1" />
            {user ? (
              <div class="dropdown dropdown-end">
                <div
                  tabindex={0}
                  role="button"
                  class="flex items-center gap-2 px-2 py-1 rounded hover:bg-base-200"
                >
                  <div class="avatar avatar-placeholder">
                    <div class="w-7 h-7 rounded-full bg-primary/20 text-primary text-xs font-mono flex items-center justify-center">
                      <span>{initials(user.email)}</span>
                    </div>
                  </div>
                  <span class="font-mono text-sm hidden sm:inline">
                    {user.email}
                  </span>
                </div>
                <ul
                  tabindex={0}
                  class="dropdown-content menu menu-sm bg-base-100 border border-base-300 rounded-box shadow-lg mt-2 w-52 p-1 z-10"
                >
                  <li class="menu-title font-mono text-xs px-3 py-2 text-base-content/60 break-all">
                    {user.email}
                  </li>
                  <li>
                    <a href="/account" class="font-mono">
                      Account
                    </a>
                  </li>
                  <li>
                    <form method="post" action="/logout" class="contents">
                      <button type="submit" class="font-mono text-error">
                        Sign out
                      </button>
                    </form>
                  </li>
                </ul>
              </div>
            ) : (
              <a href="/login" class="btn btn-primary btn-sm">
                Sign in
              </a>
            )}
          </div>
        </header>
        <main class="max-w-5xl mx-auto p-6">{children}</main>
      </body>
    </html>
  );
}
