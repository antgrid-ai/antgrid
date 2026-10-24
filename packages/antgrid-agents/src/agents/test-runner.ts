/**
 * True inside `bun test`, where Bun.main is the test file. Agents whose
 * integration lives in a machine-global file (`~/.cursor`, `~/.kimi-code`,
 * `~/.gemini/config`) check this before resolving that file from the home
 * directory: a test run bakes its own temp paths and test-file entrypoint into
 * the hook command, so a default-resolved write leaves the developer's real
 * agent running a hook that is gone once the run cleans up. Tests that exercise
 * a write path inject an isolated directory instead, which skips this check.
 */
export function runningUnderTest(): boolean {
  return /\.(test|spec)\.[cm]?[jt]sx?$/.test(Bun.main);
}
