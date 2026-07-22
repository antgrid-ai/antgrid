export type AppTarget = "windows" | "macos" | "android" | "ios";

export function licenseApiHostForTarget(
  target: AppTarget,
  lanHost: string,
): string {
  return target === "android" || target === "ios" ? lanHost : "localhost";
}
