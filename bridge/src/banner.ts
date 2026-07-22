import { hostname } from "node:os";
import { buildPairingUri, generateShortCode } from "./pairing";
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
  relayUrl: string;
  identity: DeviceIdentity;
  pubkey: Buffer;
  mode: "agent" | "pair";
  terminalCount?: number;
  commandCount?: number;
  proxyCount?: number;
  projectPath?: string;
  projectId?: string;
  /** Base64-encoded Ed25519 public key (from device identity). */
  ed25519PublicKey?: string;
  /** Single-use pair code from the agent's pairing window. */
  pairCode?: string;
}

export async function displayStartupBanner(opts: BannerOptions): Promise<void> {
  const { version, relayUrl, identity, pubkey, mode, terminalCount, commandCount, proxyCount, projectPath, ed25519PublicKey, pairCode } = opts;

  // The v1 pairing URI carries an Ed25519 pubkey (`e=`) and a pair-code (`p=`).
  // Fall back to an empty pair code if the caller hasn't opened a window yet —
  // the App treats a missing `p=` as a request that won't pass the agent's
  // pair-window check.
  const ed25519Buf = Buffer.from(ed25519PublicKey ?? "", "base64");
  const url = buildPairingUri({
    relayUrl,
    agentDeviceId: identity.deviceId,
    agentEd25519PublicKey: ed25519Buf,
    pairCode: pairCode ?? "",
    agentName: identity.deviceName,
    hostMachineName: process.env.ANTGRID_HOST_NAME ?? hostname(),
  });
  const shortCode = generateShortCode(pubkey);

  const lines: string[] = [];
  lines.push("┌──────────────────────────────────────────┐");
  lines.push(`│  Antgrid Agent v${version.padEnd(27)}│`);
  lines.push("│  by Radha AI                             │");
  lines.push("├──────────────────────────────────────────┤");

  if (projectPath) {
    const display = projectPath.length > 36 ? "..." + projectPath.slice(-33) : projectPath;
    lines.push(`│  Project: ${display.padEnd(30)}│`);
  }

  lines.push(`│  Relay:   ${relayUrl.slice(0, 30).padEnd(30)}│`);
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

  lines.push("├──────────────────────────────────────────┤");
  lines.push(`│  Code: ${shortCode.padEnd(33)}│`);
  lines.push("└──────────────────────────────────────────┘");

  console.log("\n" + lines.join("\n"));

  console.log(`\nPair URI: ${url}`);

  const emulatorRelay = emulatorRelayUrl(relayUrl);
  if (emulatorRelay) {
    const emulatorUrl = buildPairingUri({
      relayUrl: emulatorRelay,
      agentDeviceId: identity.deviceId,
      agentEd25519PublicKey: ed25519Buf,
      pairCode: pairCode ?? "",
      agentName: identity.deviceName,
      hostMachineName: process.env.ANTGRID_HOST_NAME ?? hostname(),
    });
    console.log(`Pair URI (Android emulator): ${emulatorUrl}`);
  }
  console.log("");
  if (mode === "pair") {
    console.log("Open the Pair URI above in the Antgrid app to pair this device.");
  } else {
    console.log("Open the Pair URI above in the Antgrid app to connect.");
  }
  console.log("Waiting for Antgrid app...");
  console.log("");
}
