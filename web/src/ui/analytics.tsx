/**
 * Self-hosted Umami, on our own infrastructure. Cookieless and first-party, so
 * nothing here needs a consent banner — see the site's /privacy §4, which has to
 * keep saying that for as long as this points where it does.
 *
 * `data-domains` is the only thing keeping staging and localhost out of the
 * numbers, and it is worth knowing it is the TRACKER that enforces it, not the
 * server: s.js disables itself outright unless `location.hostname` matches one
 * of these. That is why the tag can be identical in every deploy — `bun run dev`
 * on localhost, a unit test rendering the layout, and the whole
 * app.staging.antgrid.ai environment are all silent, with no NODE_ENV branch
 * anywhere and no way for a staging deploy to file itself as real traffic.
 *
 * Written out rather than derived from `BETTER_AUTH_URL` the way `origin.ts`
 * does it: that variable IS the staging origin on staging, so deriving the gate
 * from it would hand staging a gate that admits staging.
 *
 * The website id is shared with the Flutter app (`app/lib/config/environment.dart`),
 * deliberately — one Umami site for the whole app.antgrid.ai surface. The two
 * stay legible apart because this sends PAGEVIEWS at real paths while the app
 * sends named custom events; a top-level split would need a second website id.
 */
const UMAMI_SRC = "https://wa.radhaai.com/s.js";
const UMAMI_WEBSITE_ID = "bfb955b0-5839-4106-8856-b17106233619";
const UMAMI_DOMAINS = "app.antgrid.ai";

/** Last thing in the document, and the head would be the wrong place for it:
 *  everything up there is chosen for what it does to the first frame, and this
 *  does nothing to it. `defer` keeps that true — a deferred script is fetched at
 *  Low priority, under the font preloads and the stylesheet that DO paint. */
export function Analytics() {
  return (
    <script
      defer
      src={UMAMI_SRC}
      data-website-id={UMAMI_WEBSITE_ID}
      data-domains={UMAMI_DOMAINS}
    ></script>
  );
}
