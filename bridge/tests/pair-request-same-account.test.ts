import { describe, it, expect, mock } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  generateKeyPairSync,
  sign,
  type KeyObject,
} from "node:crypto";
import { createPublicKey } from "node:crypto";
import { handleInboundPairRequest } from "../src/relay-client";
import { loadPairedPhones } from "../src/paired-phones";
import { createPairingWindow } from "../src/pairing-window";
import { buildPairRequestSigBody } from "../src/pair-request-verify";
import { buildMembershipSigBody } from "../src/account-membership-verify";
import { rawSeedToPkcs8 } from "../src/pair-approval";

function freshSetup() {
  const dir = mkdtempSync(join(tmpdir(), "antgrid-same-acct-"));
  return {
    dir,
    cleanup: () => rmSync(dir, { recursive: true, force: true }),
  };
}

function makePhoneKp() {
  const kp = generateKeyPairSync("ed25519");
  const spki = kp.publicKey.export({ type: "spki", format: "der" }) as Buffer;
  const phonePubkey = spki.subarray(spki.length - 32).toString("base64");
  return { kp, phonePubkey };
}

function signRequest(opts: {
  kp: { publicKey: KeyObject; privateKey: KeyObject };
  phonePubkey: string;
  agentDeviceId: string;
  phoneDeviceId: string;
  nonce: string;
  requestedAt?: string;
}): { requestedAt: string; phoneSignature: string } {
  const requestedAt = opts.requestedAt ?? new Date().toISOString();
  const body = buildPairRequestSigBody({
    agentDeviceId: opts.agentDeviceId,
    phonePubkey: opts.phonePubkey,
    phoneDeviceId: opts.phoneDeviceId,
    nonce: opts.nonce,
    requestedAt,
  });
  const phoneSignature = sign(null, body, opts.kp.privateKey).toString("base64");
  return { requestedAt, phoneSignature };
}

// Build an account-membership proof: an Ed25519 signature over the pair-request
// transcript by an account-enrolled device key. This is the QR-less auto-pair
// proof that REPLACES trust in the relay's (forgeable) `sameAccount` stamp.
function makeMembership(opts: {
  agentDeviceId: string;
  phoneDeviceId: string;
  phonePubkey: string;
  nonce: string;
}): { accountDevicePubkey: string; accountMembershipSig: string } {
  const acct = generateKeyPairSync("ed25519");
  const seed = (acct.privateKey.export({ type: "pkcs8", format: "der" }) as Buffer).subarray(16);
  const accountDevicePubkey = (
    createPublicKey(acct.privateKey).export({ type: "spki", format: "der" }) as Buffer
  )
    .subarray(12)
    .toString("base64");
  const body = buildMembershipSigBody({
    agentDeviceId: opts.agentDeviceId,
    phoneDeviceId: opts.phoneDeviceId,
    phonePubkey: opts.phonePubkey,
    accountDevicePubkey,
    nonce: opts.nonce,
  });
  const accountMembershipSig = sign(null, body, {
    key: rawSeedToPkcs8(seed),
    format: "der",
    type: "pkcs8",
  }).toString("base64");
  return { accountDevicePubkey, accountMembershipSig };
}

describe("handleInboundPairRequest — account-membership auto-approve", () => {
  it("auto-approves a valid account-membership proof without consuming the pair-code window", async () => {
    const { dir, cleanup } = freshSetup();
    try {
      const phones = loadPairedPhones(dir);
      const win = createPairingWindow();
      // Open a window so we can assert it is NOT consumed
      const { code } = win.open();
      expect(win.isOpen()).toBe(true);

      const sent: any[] = [];
      const { kp, phonePubkey } = makePhoneKp();
      const nonce = Buffer.alloc(16, 7).toString("base64");
      const sig = signRequest({
        kp,
        phonePubkey,
        agentDeviceId: "agent-1",
        phoneDeviceId: "phone-same-acct",
        nonce,
      });
      const proof = makeMembership({
        agentDeviceId: "agent-1",
        phoneDeviceId: "phone-same-acct",
        phonePubkey,
        nonce,
      });

      await handleInboundPairRequest({
        msg: {
          type: "pair-request",
          agentDeviceId: "agent-1",
          pairId: "pair-test",
          phonePubkey,
          phoneDeviceId: "phone-same-acct",
          nonce,
          requestedAt: sig.requestedAt,
          phoneSignature: sig.phoneSignature,
          // No pairCode — membership-proof path should not need one
          accountDevicePubkey: proof.accountDevicePubkey,
          accountMembershipSig: proof.accountMembershipSig,
        },
        pairedPhones: phones,
        pairingWindow: win,
        agentDeviceId: "agent-1",
        agentEd25519Priv: Buffer.alloc(32, 1),
        getAccountPeerKeys: async () => new Set([proof.accountDevicePubkey]),
        send: (m) => sent.push(m),
      });

      // Approval sent
      expect(sent.length).toBe(1);
      expect(sent[0].type).toBe("pair-approval");
      expect(sent[0].phonePubkey).toBe(phonePubkey);
      expect(typeof sent[0].signature).toBe("string");

      // Phone persisted in trust list
      expect(phones.has(phonePubkey)).toBe(true);
      expect(phones.get(phonePubkey)?.phoneDeviceId).toBe("phone-same-acct");

      // Pair-code window NOT consumed — still open for a subsequent QR-scan pairing
      expect(win.isOpen()).toBe(true);
    } finally {
      cleanup();
    }
  });

  it("auto-approves a valid account-membership proof even when no pairing window is open", async () => {
    const { dir, cleanup } = freshSetup();
    try {
      const phones = loadPairedPhones(dir);
      const win = createPairingWindow(); // window is closed (never opened)
      expect(win.isOpen()).toBe(false);

      const sent: any[] = [];
      const { kp, phonePubkey } = makePhoneKp();
      const nonce = Buffer.alloc(16, 8).toString("base64");
      const sig = signRequest({
        kp,
        phonePubkey,
        agentDeviceId: "agent-1",
        phoneDeviceId: "phone-same-acct-2",
        nonce,
      });
      const proof = makeMembership({
        agentDeviceId: "agent-1",
        phoneDeviceId: "phone-same-acct-2",
        phonePubkey,
        nonce,
      });

      await handleInboundPairRequest({
        msg: {
          type: "pair-request",
          agentDeviceId: "agent-1",
          pairId: "pair-test",
          phonePubkey,
          phoneDeviceId: "phone-same-acct-2",
          nonce,
          requestedAt: sig.requestedAt,
          phoneSignature: sig.phoneSignature,
          accountDevicePubkey: proof.accountDevicePubkey,
          accountMembershipSig: proof.accountMembershipSig,
        },
        pairedPhones: phones,
        pairingWindow: win,
        agentDeviceId: "agent-1",
        agentEd25519Priv: Buffer.alloc(32, 1),
        getAccountPeerKeys: async () => new Set([proof.accountDevicePubkey]),
        send: (m) => sent.push(m),
      });

      expect(sent.length).toBe(1);
      expect(sent[0].type).toBe("pair-approval");
      expect(phones.has(phonePubkey)).toBe(true);
    } finally {
      cleanup();
    }
  });

  it("rejects an account-membership proof when the phone signature is invalid", async () => {
    const { dir, cleanup } = freshSetup();
    try {
      const phones = loadPairedPhones(dir);
      const win = createPairingWindow();

      const { phonePubkey } = makePhoneKp();
      // Use a different keypair to produce a bad signature
      const wrongKp = generateKeyPairSync("ed25519");
      const sent: any[] = [];
      const nonce = Buffer.alloc(16, 9).toString("base64");
      const sig = signRequest({
        kp: wrongKp,
        phonePubkey, // claims to be phonePubkey but signs with wrong key
        agentDeviceId: "agent-1",
        phoneDeviceId: "phone-bad-sig",
        nonce,
      });

      await handleInboundPairRequest({
        msg: {
          type: "pair-request",
          agentDeviceId: "agent-1",
          pairId: "pair-test",
          phonePubkey,
          phoneDeviceId: "phone-bad-sig",
          nonce,
          requestedAt: sig.requestedAt,
          phoneSignature: sig.phoneSignature,
        },
        pairedPhones: phones,
        pairingWindow: win,
        agentDeviceId: "agent-1",
        agentEd25519Priv: Buffer.alloc(32, 1),
        getAccountPeerKeys: async () => new Set<string>(),
        send: (m) => sent.push(m),
      });

      // Must reject — the membership path does not bypass phone-signature verification
      expect(sent.length).toBe(1);
      expect(sent[0].type).toBe("pair-rejected");
      expect(sent[0].reason).toBe("BAD_SIGNATURE");
      expect(phones.has(phonePubkey)).toBe(false);
    } finally {
      cleanup();
    }
  });

  it("falls back to pair-code window when sameAccount is absent", async () => {
    const { dir, cleanup } = freshSetup();
    try {
      const phones = loadPairedPhones(dir);
      const win = createPairingWindow();
      const { code } = win.open();

      const sent: any[] = [];
      const { kp, phonePubkey } = makePhoneKp();
      const nonce = Buffer.alloc(16, 10).toString("base64");
      const sig = signRequest({
        kp,
        phonePubkey,
        agentDeviceId: "agent-1",
        phoneDeviceId: "phone-legacy",
        nonce,
      });

      await handleInboundPairRequest({
        msg: {
          type: "pair-request",
          agentDeviceId: "agent-1",
          pairId: "pair-test",
          phonePubkey,
          phoneDeviceId: "phone-legacy",
          nonce,
          requestedAt: sig.requestedAt,
          phoneSignature: sig.phoneSignature,
          pairCode: code,
          // sameAccount absent — legacy path
        },
        pairedPhones: phones,
        pairingWindow: win,
        agentDeviceId: "agent-1",
        agentEd25519Priv: Buffer.alloc(32, 1),
        send: (m) => sent.push(m),
      });

      // Approved via legacy pair-code path
      expect(sent.length).toBe(1);
      expect(sent[0].type).toBe("pair-approval");
      expect(phones.has(phonePubkey)).toBe(true);

      // Window WAS consumed
      expect(win.isOpen()).toBe(false);
    } finally {
      cleanup();
    }
  });

  it("rejects legacy path (no sameAccount, no pairCode) as UNKNOWN_PHONE", async () => {
    const { dir, cleanup } = freshSetup();
    try {
      const phones = loadPairedPhones(dir);
      const win = createPairingWindow();

      const sent: any[] = [];
      const { kp, phonePubkey } = makePhoneKp();
      const nonce = Buffer.alloc(16, 11).toString("base64");
      const sig = signRequest({
        kp,
        phonePubkey,
        agentDeviceId: "agent-1",
        phoneDeviceId: "phone-unknown",
        nonce,
      });

      await handleInboundPairRequest({
        msg: {
          type: "pair-request",
          agentDeviceId: "agent-1",
          pairId: "pair-test",
          phonePubkey,
          phoneDeviceId: "phone-unknown",
          nonce,
          requestedAt: sig.requestedAt,
          phoneSignature: sig.phoneSignature,
          // No pairCode, no sameAccount
        },
        pairedPhones: phones,
        pairingWindow: win,
        agentDeviceId: "agent-1",
        agentEd25519Priv: Buffer.alloc(32, 1),
        send: (m) => sent.push(m),
      });

      expect(sent[0].type).toBe("pair-rejected");
      expect(sent[0].reason).toBe("UNKNOWN_PHONE");
      expect(phones.has(phonePubkey)).toBe(false);
    } finally {
      cleanup();
    }
  });
});
