export function requireOpencodeV2(version: string | undefined): void {
  if (!version || !Bun.semver.satisfies(version, ">=2.0.0")) {
    throw new Error(`OpenCode 2.0.0 or later is required${version ? ` (found ${version})` : ""}. Run opencode upgrade and retry.`);
  }
}
