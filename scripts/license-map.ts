export const brandPatterns = [
  /^app\/assets\/(icon|logo)\//,
  /^app\/android\/app\/src\/main\/res\/drawable[^/]*\/(android12splash|background|ic_launcher_foreground|splash)\.png$/,
  /^app\/android\/app\/src\/main\/res\/drawable[^/]*\/launch_background\.xml$/,
  /^app\/android\/app\/src\/main\/res\/mipmap-[^/]+\/ic_launcher\.png$/,
  /^app\/android\/app\/src\/main\/res\/mipmap-anydpi-v26\/ic_launcher\.xml$/,
  /^app\/(ios|macos)\/Runner\/Assets\.xcassets\/AppIcon\.appiconset\//,
  /^app\/ios\/Runner\/Assets\.xcassets\/(LaunchBackground|LaunchImage)\.imageset\//,
  /^app\/linux\/packaging\/antgrid\.png$/,
  /^app\/web\/(favicon\.png|icons\/)/,
  /^app\/windows\/runner\/resources\/app_icon\.ico$/,
  /^site\/public\/favicon\.ico$/,
  /^site\/public\/logo\/[^/]+\.(ico|png|svg)$/,
  /^web\/public\/logo\/[^/]+\.(ico|png|svg)$/,
  /^web\/public\/og\/antgrid-card\.png$/,
];

export const thirdPartyPatterns = [
  /^app\/assets\/fonts\//,
  /^app\/\.prebuilt\//,
  /^app\/android\/gradle\/wrapper\//,
  /^app\/android\/gradlew(?:\.bat)?$/,
  /^site\/src\/icons\//,
];

export function licenseForPath(path: string): string {
  if (brandPatterns.some((pattern) => pattern.test(path))) {
    return "LicenseRef-Antgrid-Brand";
  }
  if (path.startsWith("app/assets/fonts/")) return "OFL-1.1";
  if (path.startsWith("app/.prebuilt/")) return "MIT";
  if (/^app\/android\/(gradle\/wrapper\/|gradlew)/.test(path)) return "Apache-2.0";
  if (path.startsWith("site/src/icons/")) return "LicenseRef-Third-Party-Trademark";
  if (path.startsWith("relay/") || path.startsWith("web/")) {
    return "LicenseRef-Elastic-2.0";
  }
  return "MPL-2.0";
}

/**
 * Directories whose files carry an in-file SPDX header. MPL-2.0 does not
 * require one (§3.1 is satisfied by LICENSE.md plus the LICENSING.md map), so
 * the rest of the tree is declared by REUSE.toml alone. These two are the
 * exception because they are the ELv2 side of the licence boundary, and a
 * header is the only declaration that survives a file being copied OUT of the
 * repo into MPL territory. `packages/` needs none: every package is unpublished
 * (`private: true` / `publish_to: none`) and carries its own root LICENSE.
 */
export const headerRequiredPrefixes = ["relay/", "web/"];

export function requiresHeader(path: string): boolean {
  return headerRequiredPrefixes.some((prefix) => path.startsWith(prefix));
}
