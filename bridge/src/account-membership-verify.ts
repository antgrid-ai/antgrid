import { verify } from "node:crypto";

import { ED25519_SPKI_PREFIX, NUL } from "./ed25519-der";

const DOMAIN = "antgrid.account-membership.v1";

export interface MembershipSigFields {
  agentDeviceId: string;
  phoneDeviceId: string;
  phonePubkey: string;          // pairing key, base64
  accountDevicePubkey: string;  // account device Ed25519, base64
  nonce: string;                // base64
}

export function buildMembershipSigBody(f: MembershipSigFields): Buffer {
  return Buffer.concat([
    Buffer.from(DOMAIN, "utf8"), NUL,
    Buffer.from(f.agentDeviceId, "utf8"), NUL,
    Buffer.from(f.phoneDeviceId, "utf8"), NUL,
    Buffer.from(f.phonePubkey, "base64"), NUL,
    Buffer.from(f.accountDevicePubkey, "base64"), NUL,
    Buffer.from(f.nonce, "base64"),
  ]);
}

export function verifyAccountMembershipSig(args: MembershipSigFields & { sigB64: string }): boolean {
  const pubRaw = Buffer.from(args.accountDevicePubkey, "base64");
  if (pubRaw.length !== 32) return false;
  const spki = Buffer.concat([ED25519_SPKI_PREFIX, pubRaw]);
  try {
    return verify(null, buildMembershipSigBody(args), { key: spki, format: "der", type: "spki" }, Buffer.from(args.sigB64, "base64"));
  } catch { return false; }
}
