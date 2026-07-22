// bridge/src/e2e/transport.ts
// Spec: docs/protocol/e2e-handshake.md §"Transport".
// Framing: nonce(12) || ciphertext || tag(16). Random nonces in production;
// the optional `nonce` arg on seal() exists ONLY for golden-vector tests.
import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";

const ALGORITHM = "aes-256-gcm";
const NONCE_LENGTH = 12;
const TAG_LENGTH = 16;

export class E2eTransport {
  private sendKey: Buffer;
  private recvKey: Buffer;

  constructor(keys: { sendKey: Buffer; recvKey: Buffer }) {
    this.sendKey = keys.sendKey;
    this.recvKey = keys.recvKey;
  }

  seal(plaintext: string, nonce?: Buffer): Buffer {
    const n = nonce ?? randomBytes(NONCE_LENGTH);
    const cipher = createCipheriv(ALGORITHM, this.sendKey, n);
    const encrypted = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
    return Buffer.concat([n, encrypted, cipher.getAuthTag()]);
  }

  open(data: Buffer): string | null {
    try {
      if (data.length < NONCE_LENGTH + TAG_LENGTH) return null;
      const n = data.subarray(0, NONCE_LENGTH);
      const ciphertext = data.subarray(NONCE_LENGTH, data.length - TAG_LENGTH);
      const tag = data.subarray(data.length - TAG_LENGTH);
      const decipher = createDecipheriv(ALGORITHM, this.recvKey, n);
      decipher.setAuthTag(tag);
      return Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString("utf8");
    } catch {
      return null;
    }
  }

  /** Spec §"Key lifetime": call on disconnect / handshake supersession. */
  zeroize(): void {
    this.sendKey.fill(0);
    this.recvKey.fill(0);
  }
}
