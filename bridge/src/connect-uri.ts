/**
 * v1 connect URI. Carries the agent's stable Ed25519 pubkey (`e`) so the app
 * can pin the machine end-to-end. The session X25519 key is negotiated via
 * the `agent-hello` message after connecting; it is not embedded in the QR.
 *
 * Coordinates only — admission is account trust, so there is no pair code.
 */
export function buildConnectUri(args: {
  relayUrl: string;
  agentDeviceId: string;
  agentEd25519PublicKey: Uint8Array | Buffer;
  agentName: string;
  hostMachineName?: string;
}): string {
  const r = Buffer.from(args.relayUrl, "utf8").toString("base64url");
  const e = Buffer.from(args.agentEd25519PublicKey).toString("base64url");
  const n = Buffer.from(args.agentName, "utf8").toString("base64url");
  const h = args.hostMachineName
    ? `&h=${Buffer.from(args.hostMachineName, "utf8").toString("base64url")}`
    : "";
  return `antgrid://pair?v=1&r=${r}&d=${args.agentDeviceId}&e=${e}&n=${n}${h}`;
}
