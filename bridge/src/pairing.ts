/**
 * v1 pairing URI. Carries the agent's stable Ed25519 pubkey (`e`) and a
 * single-use pair code (`p`) so the phone can verify pair-approval signatures
 * end-to-end. The session X25519 key is negotiated via the `agent-hello`
 * message after pairing; it is not embedded in the QR.
 */
export function buildPairingUri(args: {
  relayUrl: string;
  agentDeviceId: string;
  agentEd25519PublicKey: Uint8Array | Buffer;
  pairCode: string;
  agentName: string;
  hostMachineName?: string;
}): string {
  const r = Buffer.from(args.relayUrl, "utf8").toString("base64url");
  const e = Buffer.from(args.agentEd25519PublicKey).toString("base64url");
  const n = Buffer.from(args.agentName, "utf8").toString("base64url");
  const h = args.hostMachineName
    ? `&h=${Buffer.from(args.hostMachineName, "utf8").toString("base64url")}`
    : "";
  return `antgrid://pair?v=1&r=${r}&d=${args.agentDeviceId}&e=${e}&p=${encodeURIComponent(args.pairCode)}&n=${n}${h}`;
}

export function generateShortCode(pubkey: Buffer): string {
  const chars = pubkey.toString("hex").slice(0, 4).toUpperCase();
  return `ANTGRID-${chars}`;
}
