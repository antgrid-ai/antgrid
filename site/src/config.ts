export const SITE_URL = import.meta.env.PUBLIC_SITE_URL ?? "https://antgrid.ai";
export const APP_URL = import.meta.env.PUBLIC_APP_URL ?? "https://app.antgrid.ai";

// Public releases repo. `releases/latest/download/<asset>` redirects to the
// newest stable release's asset of that exact filename, so these URLs never
// change across versions — cutting a release never requires a site deploy.
export const RELEASES_URL = "https://github.com/antgrid-ai/antgrid-releases";

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
  privacy: "/privacy",
  terms: "/terms",
  refunds: "/refunds",
  company: "https://radhaai.com",
  checkout: (planId: string) => `${APP_URL}/checkout?planId=${planId}`,
};
