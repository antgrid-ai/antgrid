// The reader's colour-scheme choice. "system" means no override: the attribute
// is absent, the cookie is gone, and `color-scheme: light dark` follows the OS.
// The first frame is handled by the pre-paint script in layouts/Base.astro,
// which reads the same cookie; this module only handles the change.
//
// Hand-mirrored as THEME_TOGGLE_SCRIPT in the web service (web/src/ui/theme.ts):
// a reader crosses from antgrid.ai into that service mid sign-in and the
// cookie below is what carries the choice across. Same name, same scope, or
// the crossing flips the page.
export type ThemeChoice = "system" | "light" | "dark";

const COOKIE = "antgrid-theme";
const QUERY = {
  light: "(prefers-color-scheme: light)",
  dark: "(prefers-color-scheme: dark)",
} as const;

// One scope for set and clear. A cookie is only deleted by a Set-Cookie whose
// Domain and Path match the one that stored it, so "System" has to repeat
// exactly what "Light"/"Dark" wrote — on the apex so the web service (a
// subdomain) reads it, host-only on localhost and previews where a Domain
// attribute would be refused.
function scope(): string {
  const host = location.hostname;
  const apex = host === "antgrid.ai" || host.endsWith(".antgrid.ai");
  return (
    "; Path=/; SameSite=Lax" +
    (apex ? "; Domain=antgrid.ai" : "") +
    (location.protocol === "https:" ? "; Secure" : "")
  );
}

export function currentChoice(): ThemeChoice {
  const t = document.documentElement.dataset.theme;
  return t === "light" || t === "dark" ? t : "system";
}

export function applyTheme(choice: ThemeChoice): void {
  const root = document.documentElement;
  if (choice === "system") {
    delete root.dataset.theme;
    document.cookie = `${COOKIE}=; Max-Age=0${scope()}`;
  } else {
    root.dataset.theme = choice;
    document.cookie = `${COOKIE}=${choice}; Max-Age=31536000${scope()}`;
  }
  // Chrome takes the first theme-color whose `media` matches, so the override
  // is expressed by flipping `media` and never by reordering or rewriting.
  for (const meta of document.querySelectorAll<HTMLMetaElement>(
    'meta[name="theme-color"][data-scheme]',
  )) {
    const scheme = meta.dataset.scheme as keyof typeof QUERY;
    meta.media = choice === "system" ? QUERY[scheme] : scheme === choice ? "all" : "not all";
  }
  reflect(choice);
}

function reflect(choice: ThemeChoice): void {
  for (const btn of document.querySelectorAll<HTMLButtonElement>("[data-theme-choice]")) {
    btn.setAttribute("aria-pressed", String(btn.dataset.themeChoice === choice));
  }
}

/** Wires every `[data-theme-choice]` button on the page. */
export function mountThemeToggle(): void {
  reflect(currentChoice());
  for (const btn of document.querySelectorAll<HTMLButtonElement>("[data-theme-choice]")) {
    btn.addEventListener("click", () => applyTheme(btn.dataset.themeChoice as ThemeChoice));
  }
}
