export const SITE_URL = import.meta.env.PUBLIC_SITE_URL ?? "https://antgrid.ai";
export const APP_URL = import.meta.env.PUBLIC_APP_URL ?? "https://app.antgrid.ai";

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
  features: "/#fleet",
  download: "/#download",
  getStarted: "/get-started",
  downloadMacos: `${RELEASES_URL}/releases/latest/download/antgrid-macos.dmg`,
  // Microsoft Store deep link (product 9N0P7ZRL4D9W); version-stable like the
  // GitHub release URLs above, so a new build never needs a site deploy.
  downloadWindows: "https://get.microsoft.com/installer/download/9N0P7ZRL4D9W?referrer=appbadge&cid=site",
  downloadLinux: `${RELEASES_URL}/releases/latest/download/antgrid-linux.AppImage`,
  support: "/support",
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
  checkout: (planId: string) => `${APP_URL}/checkout?planId=${planId}`,
};
