import { describe, it, expect } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  generateKeyPairSync,
  sign,
  createPrivateKey,
  createPublicKey,
  type KeyObject,
} from "node:crypto";
import { handleInboundPairRequest } from "../src/relay-client";
import { loadPairedPhones } from "../src/paired-phones";
import { createPairingWindow } from "../src/pairing-window";
import { buildPairRequestSigBody } from "../src/pair-request-verify";
import { buildMembershipSigBody } from "../src/account-membership-verify";
import { rawSeedToPkcs8 } from "../src/pair-approval";

const ED25519_PKCS8_PREFIX = Buffer.from(
  "302e020100300506032b657004220420",
  "hex",
);

function freshSetup() {
  const dir = mkdtempSync(join(tmpdir(), "antgrid-pair-"));
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

describe("handleInboundPairRequest", () => {
  it("approves a fresh pair-request matching the pair-window code; persists trust; window single-used", async () => {
    const { dir, cleanup } = freshSetup();
    try {
      const phones = loadPairedPhones(dir);
      const win = createPairingWindow();
      const { code } = win.open();
      const sent: any[] = [];
      const { kp, phonePubkey } = makePhoneKp();
      const nonce = Buffer.alloc(16, 0).toString("base64");
      const sig = signRequest({
        kp,
        phonePubkey,
        agentDeviceId: "a1",
        phoneDeviceId: "phone-1",
        nonce,
      });

      await handleInboundPairRequest({
        msg: {
          type: "pair-request",
          pairId: "pair-1",
          agentDeviceId: "a1",
          phonePubkey,
          phoneDeviceId: "phone-1",
          nonce,
          requestedAt: sig.requestedAt,
          phoneSignature: sig.phoneSignature,
          pairCode: code,
          label: "iPhone",
        },
        pairedPhones: phones,
        pairingWindow: win,
        agentDeviceId: "a1",
        agentEd25519Priv: Buffer.alloc(32, 1),
        send: (m) => sent.push(m),
      });

      expect(sent.length).toBe(1);
      expect(sent[0].type).toBe("pair-approval");
      expect(sent[0].phonePubkey).toBe(phonePubkey);
      expect(typeof sent[0].signature).toBe("string");
      expect(typeof sent[0].expiresAt).toBe("string");
      expect(phones.has(phonePubkey)).toBe(true);
      expect(phones.get(phonePubkey)?.label).toBe("iPhone");
      expect(phones.get(phonePubkey)?.admission).toBe("pair-code");
      expect(phones.get(phonePubkey)?.allowedProjects).toEqual([]);
      expect(win.isOpen()).toBe(false);
    } finally {
      cleanup();
    }
  });

  it("approves a fresh account-member pair-request with same-account default projects", async () => {
    const { dir, cleanup } = freshSetup();
    try {
      const phones = loadPairedPhones(dir);
      const win = createPairingWindow();
      const sent: any[] = [];
      const { kp, phonePubkey } = makePhoneKp();
      const nonce = Buffer.alloc(16, 7).toString("base64");
      const sig = signRequest({
        kp,
        phonePubkey,
        agentDeviceId: "a1",
        phoneDeviceId: "phone-same",
        nonce,
      });
      const proof = makeMembership({
        agentDeviceId: "a1",
        phoneDeviceId: "phone-same",
        phonePubkey,
        nonce,
      });

      await handleInboundPairRequest({
        msg: {
          type: "pair-request",
          pairId: "pair-1",
          agentDeviceId: "a1",
          phonePubkey,
          phoneDeviceId: "phone-same",
          nonce,
          requestedAt: sig.requestedAt,
          phoneSignature: sig.phoneSignature,
          accountDevicePubkey: proof.accountDevicePubkey,
          accountMembershipSig: proof.accountMembershipSig,
        },
        pairedPhones: phones,
        pairingWindow: win,
        agentDeviceId: "a1",
        agentEd25519Priv: Buffer.alloc(32, 1),
        getAccountPeerKeys: async () => new Set([proof.accountDevicePubkey]),
        sameAccountDefaultProjects: () => ["projA"],
        send: (m) => sent.push(m),
      });

      expect(sent[0].type).toBe("pair-approval");
      expect(phones.get(phonePubkey)?.admission).toBe("same-account");
      expect(phones.get(phonePubkey)?.allowedProjects).toEqual(["projA"]);
    } finally {
      cleanup();
    }
  });

  it("approves trusted phone on reconnect (no pairCode) and bumps lastSeenAt", async () => {
    const { dir, cleanup } = freshSetup();
    try {
      const phones = loadPairedPhones(dir);
      const { kp, phonePubkey } = makePhoneKp();
      phones.upsert({
        phonePubkey,
        phoneDeviceId: "phone-1",
        pairedAt: "2026-01-01T00:00:00.000Z",
        lastSeenAt: "2026-01-01T00:00:00.000Z",
        admission: "pair-code",
      });
      const win = createPairingWindow();
      const sent: any[] = [];
      const nonce = Buffer.alloc(16, 0).toString("base64");
      const sig = signRequest({
        kp,
        phonePubkey,
        agentDeviceId: "a1",
        phoneDeviceId: "phone-1",
        nonce,
      });

      await handleInboundPairRequest({
        msg: {
          type: "pair-request",
          pairId: "pair-1",
          agentDeviceId: "a1",
          phonePubkey,
          phoneDeviceId: "phone-1",
          nonce,
          requestedAt: sig.requestedAt,
          phoneSignature: sig.phoneSignature,
        },
        pairedPhones: phones,
        pairingWindow: win,
        agentDeviceId: "a1",
        agentEd25519Priv: Buffer.alloc(32, 1),
        send: (m) => sent.push(m),
      });

      expect(sent[0].type).toBe("pair-approval");
      const updated = phones.get(phonePubkey)!;
      expect(updated.pairedAt).toBe("2026-01-01T00:00:00.000Z");
      expect(updated.lastSeenAt).not.toBe("2026-01-01T00:00:00.000Z");
    } finally {
      cleanup();
    }
  });

  it("rejects an attacker impersonating a trusted phone's pubkey with BAD_SIGNATURE", async () => {
    const { dir, cleanup } = freshSetup();
    try {
      const phones = loadPairedPhones(dir);
      // Trusted phone: kpTrusted produced phonePubkey already in the list.
      const { phonePubkey: trustedPk } = makePhoneKp();
      phones.upsert({
        phonePubkey: trustedPk,
        phoneDeviceId: "phone-trusted",
        pairedAt: "2026-01-01T00:00:00.000Z",
        lastSeenAt: "2026-01-01T00:00:00.000Z",
        admission: "pair-code",
      });
      // Attacker uses their own keypair to sign over the TRUSTED pubkey.
      const attackerKp = generateKeyPairSync("ed25519");
      const win = createPairingWindow();
      const sent: any[] = [];
      const nonce = Buffer.alloc(16, 2).toString("base64");
      const sig = signRequest({
        kp: attackerKp,
        phonePubkey: trustedPk, // attacker claims to be the trusted phone
        agentDeviceId: "a1",
        phoneDeviceId: "attacker-device",
        nonce,
      });

      await handleInboundPairRequest({
        msg: {
          type: "pair-request",
          pairId: "pair-1",
          agentDeviceId: "a1",
          phonePubkey: trustedPk,
          phoneDeviceId: "attacker-device",
          nonce,
          requestedAt: sig.requestedAt,
          phoneSignature: sig.phoneSignature,
        },
        pairedPhones: phones,
        pairingWindow: win,
        agentDeviceId: "a1",
        agentEd25519Priv: Buffer.alloc(32, 1),
        send: (m) => sent.push(m),
      });

      expect(sent.length).toBe(1);
      expect(sent[0]).toEqual({
        type: "pair-rejected",
        pairId: "pair-1",
        phonePubkey: trustedPk,
        reason: "BAD_SIGNATURE",
      });
    } finally {
      cleanup();
    }
  });

  it("rejects a stale request (>30 s old) with STALE_REQUEST", async () => {
    const { dir, cleanup } = freshSetup();
    try {
      const phones = loadPairedPhones(dir);
      const { kp, phonePubkey } = makePhoneKp();
      phones.upsert({
        phonePubkey,
        phoneDeviceId: "phone-1",
        pairedAt: "2026-01-01T00:00:00.000Z",
        lastSeenAt: "2026-01-01T00:00:00.000Z",
        admission: "pair-code",
      });
      const win = createPairingWindow();
      const sent: any[] = [];
      const nonce = Buffer.alloc(16, 0).toString("base64");
      const baseNow = Date.parse("2030-06-01T12:00:00.000Z");
      const sig = signRequest({
        kp,
        phonePubkey,
        agentDeviceId: "a1",
        phoneDeviceId: "phone-1",
        nonce,
        requestedAt: new Date(baseNow - 60_000).toISOString(),
      });

      await handleInboundPairRequest({
        msg: {
          type: "pair-request",
          pairId: "pair-1",
          agentDeviceId: "a1",
          phonePubkey,
          phoneDeviceId: "phone-1",
          nonce,
          requestedAt: sig.requestedAt,
          phoneSignature: sig.phoneSignature,
        },
        pairedPhones: phones,
        pairingWindow: win,
        agentDeviceId: "a1",
        agentEd25519Priv: Buffer.alloc(32, 1),
        send: (m) => sent.push(m),
        now: () => baseNow,
      });

      expect(sent[0]).toEqual({
        type: "pair-rejected",
        pairId: "pair-1",
        phonePubkey,
        reason: "STALE_REQUEST",
      });
    } finally {
      cleanup();
    }
  });

  it("rejects unknown phone (no pairCode, not trusted, valid sig) with UNKNOWN_PHONE", async () => {
    const { dir, cleanup } = freshSetup();
    try {
      const phones = loadPairedPhones(dir);
      const win = createPairingWindow();
      const sent: any[] = [];
      const { kp, phonePubkey } = makePhoneKp();
      const nonce = Buffer.alloc(16, 0).toString("base64");
      const sig = signRequest({
        kp,
        phonePubkey,
        agentDeviceId: "a1",
        phoneDeviceId: "phone-x",
        nonce,
      });

      await handleInboundPairRequest({
        msg: {
          type: "pair-request",
          pairId: "pair-1",
          agentDeviceId: "a1",
          phonePubkey,
          phoneDeviceId: "phone-x",
          nonce,
          requestedAt: sig.requestedAt,
          phoneSignature: sig.phoneSignature,
        },
        pairedPhones: phones,
        pairingWindow: win,
        agentDeviceId: "a1",
        agentEd25519Priv: Buffer.alloc(32, 1),
        send: (m) => sent.push(m),
      });

      expect(sent[0]).toEqual({
        type: "pair-rejected",
        pairId: "pair-1",
        phonePubkey,
        reason: "UNKNOWN_PHONE",
      });
      expect(phones.list().length).toBe(0);
    } finally {
      cleanup();
    }
  });

  it("rejects mismatched pairCode (valid sig) with PAIRING_WINDOW_CLOSED", async () => {
    const { dir, cleanup } = freshSetup();
    try {
      const phones = loadPairedPhones(dir);
      const win = createPairingWindow();
      win.open();
      const sent: any[] = [];
      const { kp, phonePubkey } = makePhoneKp();
      const nonce = Buffer.alloc(16, 0).toString("base64");
      const sig = signRequest({
        kp,
        phonePubkey,
        agentDeviceId: "a1",
        phoneDeviceId: "phone-x",
        nonce,
      });

      await handleInboundPairRequest({
        msg: {
          type: "pair-request",
          pairId: "pair-1",
          agentDeviceId: "a1",
          phonePubkey,
          phoneDeviceId: "phone-x",
          nonce,
          requestedAt: sig.requestedAt,
          phoneSignature: sig.phoneSignature,
          pairCode: "wrong-code",
        },
        pairedPhones: phones,
        pairingWindow: win,
        agentDeviceId: "a1",
        agentEd25519Priv: Buffer.alloc(32, 1),
        send: (m) => sent.push(m),
      });

      expect(sent[0].type).toBe("pair-rejected");
      expect(sent[0].reason).toBe("PAIRING_WINDOW_CLOSED");
    } finally {
      cleanup();
    }
  });
});
