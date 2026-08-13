import { type DeviceIdentity } from "./device";

export interface BannerOptions {
  version: string;
  /** Null when the caller has no relay coordinate. */
  relayUrl: string | null;
  identity: DeviceIdentity;
  terminalCount?: number;
  commandCount?: number;
  proxyCount?: number;
  projectPath?: string;
  projectId?: string;
}

export async function displayStartupBanner(opts: BannerOptions): Promise<void> {
  const { version, relayUrl, identity, terminalCount, commandCount, proxyCount, projectPath } = opts;

  const lines: string[] = [];
  lines.push("┌──────────────────────────────────────────┐");
  lines.push(`│  Antgrid Agent v${version.padEnd(27)}│`);
  lines.push("│  by Radha AI                             │");
  lines.push("├──────────────────────────────────────────┤");

  if (projectPath) {
    const display = projectPath.length > 36 ? "..." + projectPath.slice(-33) : projectPath;
    lines.push(`│  Project: ${display.padEnd(30)}│`);
  }

  lines.push(`│  Relay:   ${(relayUrl ?? "(not configured)").slice(0, 30).padEnd(30)}│`);
  lines.push(`│  Device:  ${identity.deviceName.slice(0, 30).padEnd(30)}│`);

  if (terminalCount !== undefined) {
    lines.push(`│  Terminals: ${String(terminalCount).padEnd(28)}│`);
  }
  if (commandCount !== undefined && commandCount > 0) {
    lines.push(`│  Commands:  ${String(commandCount).padEnd(28)}│`);
  }
  if (proxyCount !== undefined && proxyCount > 0) {
    lines.push(`│  Proxies:   ${String(proxyCount).padEnd(28)}│`);
  }

  lines.push("└──────────────────────────────────────────┘");

  console.log("\n" + lines.join("\n"));
  console.log("");
  console.log("Connect this machine from the app's machine list.");
  console.log("Waiting for Antgrid app...");
  console.log("");
}
