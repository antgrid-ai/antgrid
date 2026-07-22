export const SITE_URL = import.meta.env.PUBLIC_SITE_URL ?? "https://antgrid.ai";
export const APP_URL = import.meta.env.PUBLIC_APP_URL ?? "https://app.antgrid.ai";

// Public releases repo. `releases/latest/download/<asset>` redirects to the
// newest stable release's asset of that exact filename, so these URLs never
// change across versions — cutting a release never requires a site deploy.
export const RELEASES_URL = "https://github.com/Radha-AI-Products/antgrid-releases";

export const links = {
  signIn: `${APP_URL}/login`,
  startFree: `${APP_URL}/login`,
  pricing: "/pricing",
  features: "/#fleet",
  download: "/#download",
  downloadMacos: `${RELEASES_URL}/releases/latest/download/antgrid-macos.dmg`,
  downloadWindows: `${RELEASES_URL}/releases/latest/download/antgrid-windows-setup.exe`,
  downloadLinux: `${RELEASES_URL}/releases/latest/download/antgrid-linux.AppImage`,
  support: "/support",
  privacy: "/privacy",
  terms: "/terms",
  refunds: "/refunds",
  company: "https://radhaai.com",
  checkout: (planId: string) => `${APP_URL}/checkout?planId=${planId}`,
};
