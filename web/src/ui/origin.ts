/**
 * The service's own public origin, for the few tags that must carry an absolute
 * URL. A link-preview scraper fetches `og:image` out of band, with no page to
 * resolve a relative path against, so a root-relative URL there is a card with
 * a broken image on some clients and no image at all on others.
 *
 * Pushed in from `buildApp` rather than read out of `process.env` here: `env.ts`
 * is what resolves `BETTER_AUTH_URL`, including its dev default and the `.env`
 * overlay, and a second reader of the same variable would drift from it.
 */
let origin = "";

export function setPublicOrigin(value: string | undefined): void {
  // `.origin`, not a trailing-slash trim: `BETTER_AUTH_URL` is only validated as
  // a URL, so any path it carries would be prefixed onto a root-relative asset
  // path and point the scraper at a 404. Same reading as `routes/ui.tsx`.
  try {
    origin = value ? new URL(value).origin : "";
  } catch {
    origin = "";
  }
}

/**
 * Absolute when the origin is known, root-relative otherwise.
 *
 * The fallback is for unit tests, which render components without building an
 * app. It is deliberately still a usable URL rather than a throw: a missing
 * social image should never be able to take a page down.
 */
export function absoluteUrl(path: string): string {
  return origin ? origin + path : path;
}
