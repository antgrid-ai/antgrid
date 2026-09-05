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
  // Start free lands on the download page, not app sign-in — the desktop app is
  // the product entry point; billing sign-in stays on links.signIn.
  startFree: "/download",
  pricing: "/pricing",
  // #handler, not #fleet. Phases.astro sits ABOVE Fleet.astro on the home page,
  // so a "Features" link aimed at the fleet view opened one section PAST the only
  // feature anyone pays for. Anchor hrefs are excluded from the dead-link sweep in
  // home.spec.ts, so the id this depends on is pinned in contracts.spec.ts instead.
  features: "/#handler",
  // A path, not the home page's #download band. A fragment is absent from the
  // HTTP request-target grammar (RFC 9112 §3.2.1) — it never reaches a server,
  // so no log, CDN or analytics tool can record one, and Google's URL-structure
  // guidance is explicit that fragments are not indexed. The band stays as the
  // home page's closing CTA; this is the address every other surface points at,
  // and it carries ?platform= (see downloadUrlFor) to fire a specific build.
  download: "/download",
  getStarted: "/get-started",
  downloadMacos: `${RELEASES_URL}/releases/latest/download/antgrid-macos.dmg`,
  // The Store's stub installer (product 9N0P7ZRL4D9W). Version-stable like the
  // GitHub URLs above, so a new build never needs a site deploy — but it answers
  // `Content-Disposition: attachment` to EVERY user agent, with no sniffing and
  // no redirect. A Mac, a phone or a Linux box asking for it gets an 815KB
  // Windows .exe it cannot run, so it is only ever offered to a reader already
  // on Windows. Everyone else is offered storeListing.
  downloadWindows: "https://get.microsoft.com/installer/download/9N0P7ZRL4D9W?referrer=appbadge&cid=site",
  // The Store's web listing: an ordinary page on every OS, and still a Store-app
  // launch on Windows. This is what a reader who is NOT on Windows is offered
  // for the Windows build — they are almost always fetching it for a machine
  // they are not sitting at, and a listing survives being emailed to themselves
  // where a stub installer does not.
  storeListing: "https://apps.microsoft.com/detail/9N0P7ZRL4D9W",
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

// The three desktop builds as one list, because three separate things have to
// agree on the same ids: the hero's OS-matched button, the confirmation page's
// per-platform panels, and that page's script, which maps ?platform= back to a
// URL. An id that agrees in two of the three is the worst case — the reader is
// thanked for a download that never started. contracts.spec.ts pins all three
// together for that reason.
//
// `os` is the OTHER axis and is deliberately not the id: it is the value
// Base.astro writes to data-os from the reader's machine, and the two answer
// different questions — which build this is, versus which build this reader can
// run. The confirmation page needs them apart, because what it fires is what
// the URL ASKED for, not what the visitor happens to be sitting at.
export type Platform = {
  id: string;
  os: string;
  name: string;
  icon: string;
  url: string;
  /** Where to send a reader who is NOT on this OS, when it cannot be the same
   *  place. Only Windows needs one: a .dmg or an AppImage fetched from another
   *  machine is still the real artifact, but the Windows URL is a stub installer
   *  that hands every caller a .exe regardless of what asked for it. */
  awayUrl?: string;
};

export const PLATFORMS: Platform[] = [
  { id: "windows", os: "win", name: "Windows", icon: "tabler:brand-windows", url: links.downloadWindows, awayUrl: links.storeListing },
  { id: "macos", os: "mac", name: "macOS", icon: "tabler:brand-apple", url: links.downloadMacos },
  { id: "linux", os: "linux", name: "Linux", icon: "tabler:brand-open-source", url: links.downloadLinux },
];

// One link that both downloads and orients: the query is what the confirmation
// page fires on, and the page it lands on is the answer to "it downloaded, now
// what". Split across two clicks — download here, instructions there — one of
// them is always the one that gets skipped.
export const downloadUrlFor = (id: string) => `${links.download}?platform=${id}`;
