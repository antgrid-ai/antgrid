// bridge/src/e2e/transcript.ts
// Spec: docs/protocol/e2e-handshake.md §"Canonical transcript".
// Byte-for-byte mirror of packages/antgrid_relay_client/lib/src/e2e/transcript.dart.

export const DOMAIN_V2 = "antgrid.e2e-handshake.v2";
export const VERSION_BYTE = 0x02;
const NUL = Buffer.from([0x00]);

export interface TranscriptFields {
  registrationId: string;
  role: "agent" | "phone";
  agentDeviceId: string;
  phoneDeviceId: string;
  /** Raw 32 bytes, or ZERO-LENGTH for the phone's client-hello signature
   *  (the phone signs before it knows the agent ephemeral). */
  agentX25519Pub: Buffer;
  phoneX25519Pub: Buffer;
  nonce: Buffer;
}

/** Fields joined with 0x00 separators, no trailing separator. */
export function buildTranscript(f: TranscriptFields): Buffer {
  return Buffer.concat([
    Buffer.from(DOMAIN_V2, "utf8"), NUL,
    Buffer.from([VERSION_BYTE]), NUL,
    Buffer.from(f.registrationId, "utf8"), NUL,
    Buffer.from(f.role, "utf8"), NUL,
    Buffer.from(f.agentDeviceId, "utf8"), NUL,
    Buffer.from(f.phoneDeviceId, "utf8"), NUL,
    f.agentX25519Pub, NUL,
    f.phoneX25519Pub, NUL,
    f.nonce,
  ]);
}
