// A plain `opencode upgrade` keeps a 1.x install on the 1.x line (it only
// mentions OpenCode 2); `--major` is what replaces it with OpenCode 2.
// OpenCode 2 is the `@opencode/cli` package. 1.x's `upgrade --major` swaps
// `opencode-ai` for it; 2.x's `upgrade` has no `--major` and rejects unknown
// flags, so the argument depends on the installed line.
export function opencodeUpgradeArgs(installed: string | null): string[] {
  return installed && Bun.semver.satisfies(installed, "<2.0.0") ? ["upgrade", "--major"] : ["upgrade"];
}

export function requireOpencodeV2(version: string | undefined): void {
  if (!version || !Bun.semver.satisfies(version, ">=2.0.0")) {
    throw new Error(`OpenCode 2.0.0 or later is required${version ? ` (found ${version})` : ""}. Run opencode upgrade --major and retry.`);
  }
}
