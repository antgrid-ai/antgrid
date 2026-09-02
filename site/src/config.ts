export const SITE_URL = import.meta.env.PUBLIC_SITE_URL ?? "https://antgrid.ai";
export const APP_URL = import.meta.env.PUBLIC_APP_URL ?? "https://app.antgrid.ai";
// The web service's API origin. Same deployment as APP_URL today, but declared
// separately because it is overridden for a different reason: pointing a preview
// build's waitlist POST at a local web server must not also move sign-in and
// checkout off production. The site is a static build on another origin, so
// anything under here is a cross-origin request the web service must allow.
export const WEB_URL = import.meta.env.PUBLIC_WEB_URL ?? "https://app.antgrid.ai";

// Public releases repo. `releases/latest/download/<asset>` redirects to the
// newest stable release's asset of that exact filename, so these URLs never
// change across versions — cutting a release never requires a site deploy.
export const RELEASES_URL = "https://github.com/antgrid-ai/antgrid";

export const links = {
  signIn: `${APP_URL}/login`,
  // Start free lands on the download band, not app sign-in — the desktop app is
  // the product entry point; billing sign-in stays on links.signIn.
  startFree: "/#download",
  pricing: "/pricing",
  // #handler, not #fleet. Phases.astro sits ABOVE Fleet.astro on the home page,
  // so a "Features" link aimed at the fleet view opened one section PAST the only
  // feature anyone pays for. Anchor hrefs are excluded from the dead-link sweep in
  // home.spec.ts, so the id this depends on is pinned in contracts.spec.ts instead.
  features: "/#handler",
  download: "/#download",
  getStarted: "/get-started",
  downloadMacos: `${RELEASES_URL}/releases/latest/download/antgrid-macos.dmg`,
  // Microsoft Store deep link (product 9N0P7ZRL4D9W); version-stable like the
  // GitHub release URLs above, so a new build never needs a site deploy.
  downloadWindows: "https://get.microsoft.com/installer/download/9N0P7ZRL4D9W?referrer=appbadge&cid=site",
  downloadLinux: `${RELEASES_URL}/releases/latest/download/antgrid-linux.AppImage`,
  support: "/support",
  security: "/security",
  // Verification surfaces for /security. `HEAD` rather than a branch name:
  // GitHub resolves it to whatever the repo's default branch is, so renaming
  // that branch never turns these into 404s under a page whose whole argument
  // is that the reader can go and check.
  repo: RELEASES_URL,
  securityPolicyFile: `${RELEASES_URL}/blob/HEAD/SECURITY.md`,
  securityAdvisory: `${RELEASES_URL}/security/advisories/new`,
  handshakeSpec: `${RELEASES_URL}/blob/HEAD/docs/protocol/e2e-handshake.md`,
  handshakeVectors: `${RELEASES_URL}/blob/HEAD/evals/fixtures/e2e-handshake-vectors.json`,
  relayClient: `${RELEASES_URL}/tree/HEAD/packages/antgrid_relay_client`,
  wirePackage: `${RELEASES_URL}/tree/HEAD/packages/antgrid-wire`,
  securityEmail: "mailto:contact@radhaai.com?subject=Security",
  // Enterprise leads go straight to a human. Pointing them at /support put a
  // budget holder on the troubleshooting page; the subject line sorts them out
  // of general support mail on arrival.
  enterprise: "mailto:contact@radhaai.com?subject=Antgrid%20for%20teams",
  // The mobile apps ship through TestFlight and Play internal testing today, so
  // the hero has to route the ask somewhere. "Coming to the App Store" read as
  // "you can't have it yet" while invites were in fact open — see get-started.
  mobileInvite: "mailto:contact@radhaai.com?subject=Antgrid%20mobile%20invite",
  privacy: "/privacy",
  terms: "/terms",
  refunds: "/refunds",
  company: "https://radhaai.com",
  // Interest capture for founding pricing. Posted to by the inline script in
  // WaitlistCta.astro — never rendered as an href, since a GET on it does nothing.
  waitlist: `${WEB_URL}/api/waitlist`,
  checkout: (planId: string) => `${APP_URL}/checkout?planId=${planId}`,
};
