import { hostname } from "node:os";
import { buildConnectUri } from "./connect-uri";
import { type DeviceIdentity } from "./device";

function emulatorRelayUrl(relayUrl: string): string | null {
  const match = relayUrl.match(/^(wss?:\/\/)([^:/?#]+)(.*)$/);
  if (!match) return null;
  const [, scheme, host, rest] = match;
  const isLoopback =
    host === "localhost" || host === "127.0.0.1" || host === "::1" || host === "[::1]";
  return isLoopback ? `${scheme}10.0.2.2${rest}` : null;
}

export interface BannerOptions {
  version: string;
  /** Null when the caller has no relay coordinate. The banner then prints no
   *  connect URI at all — a URI whose `r=` is not a URL is worse than none:
   *  the app takes `r=` verbatim whenever it is present, so a placeholder is
   *  adopted as the relay URL instead of falling back to the default. */
  relayUrl: string | null;
  identity: DeviceIdentity;
  mode: "agent" | "pair";
  terminalCount?: number;
  commandCount?: number;
  proxyCount?: number;
  projectPath?: string;
  projectId?: string;
  /** Base64-encoded Ed25519 public key (from device identity). */
  ed25519PublicKey?: string;
}

export async function displayStartupBanner(opts: BannerOptions): Promise<void> {
  const { version, relayUrl, identity, mode, terminalCount, commandCount, proxyCount, projectPath, ed25519PublicKey } = opts;

  const ed25519Buf = Buffer.from(ed25519PublicKey ?? "", "base64");
  const url = relayUrl
    ? buildConnectUri({
        relayUrl,
        agentDeviceId: identity.deviceId,
        agentEd25519PublicKey: ed25519Buf,
        agentName: identity.deviceName,
        hostMachineName: process.env.ANTGRID_HOST_NAME ?? hostname(),
      })
    : null;

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

  if (mode === "agent" && terminalCount !== undefined) {
    lines.push(`│  Terminals: ${String(terminalCount).padEnd(28)}│`);
  }
  if (mode === "agent" && commandCount !== undefined && commandCount > 0) {
    lines.push(`│  Commands:  ${String(commandCount).padEnd(28)}│`);
  }
  if (mode === "agent" && proxyCount !== undefined && proxyCount > 0) {
    lines.push(`│  Proxies:   ${String(proxyCount).padEnd(28)}│`);
  }

  lines.push("└──────────────────────────────────────────┘");

  console.log("\n" + lines.join("\n"));

  if (url && relayUrl) {
    console.log(`\nConnect URI: ${url}`);

    const emulatorRelay = emulatorRelayUrl(relayUrl);
    if (emulatorRelay) {
      const emulatorUrl = buildConnectUri({
        relayUrl: emulatorRelay,
        agentDeviceId: identity.deviceId,
        agentEd25519PublicKey: ed25519Buf,
        agentName: identity.deviceName,
        hostMachineName: process.env.ANTGRID_HOST_NAME ?? hostname(),
      });
      console.log(`Connect URI (Android emulator): ${emulatorUrl}`);
    }
    console.log("");
    console.log("Open the URI above in the Antgrid app to connect this machine.");
  } else {
    console.log("");
    console.log("No relay URL configured — connect this machine from the app's machine list.");
  }
  console.log("Waiting for Antgrid app...");
  console.log("");
}
