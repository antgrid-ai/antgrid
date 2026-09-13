import { isAntigravityBinary, primeAntigravityCertCache } from "./antigravity/startup";

// Kept independent of the registry: provider drivers import the PTY helpers
// while the registry is still initializing.
const integrations = [{
  matches: isAntigravityBinary,
  windowsShell: true,
  prepare: primeAntigravityCertCache,
}];

export function needsShellForAgentBinary(command: string): boolean {
  return integrations.some((integration) => integration.matches(command) && integration.windowsShell);
}

export function prepareAgentBinary(command: string, env: Record<string, string>): void {
  integrations.find((integration) => integration.matches(command))?.prepare(env);
}
