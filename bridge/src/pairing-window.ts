import { randomBytes, timingSafeEqual } from "node:crypto";

const DEFAULT_TTL_MS = 60_000;

export interface PairingWindow {
  open(opts?: { ttlMs?: number }): { code: string; expiresAt: string };
  consume(code: string): boolean;
  isOpen(): boolean;
  /**
   * Discard the current code (if any). Called when the user intentionally
   * tears the relay down (e.g. closing the wizard before pairing). Without
   * this, a subsequent `enableRelay` would find `isOpen()` still true and
   * the `onAuthenticated` re-emit guard would skip publishing a fresh
   * `agent:pairingReady`, leaving the wizard stuck at "connecting".
   */
  close(): void;
}

export function createPairingWindow(opts: { ttlMs?: number } = {}): PairingWindow {
  const defaultTtlMs = opts.ttlMs ?? DEFAULT_TTL_MS;
  let current: { code: string; expiresMs: number } | null = null;

  return {
    open(callOpts) {
      const ttlMs = callOpts?.ttlMs ?? defaultTtlMs;
      const code = randomBytes(16).toString("base64url");
      const expiresMs = Date.now() + ttlMs;
      current = { code, expiresMs };
      return { code, expiresAt: new Date(expiresMs).toISOString() };
    },
    consume(code) {
      if (!current) return false;
      if (current.expiresMs < Date.now()) { current = null; return false; }
      const a = Buffer.from(current.code);
      const b = Buffer.from(code);
      if (a.length !== b.length) return false;
      if (!timingSafeEqual(a, b)) return false;
      current = null;
      return true;
    },
    isOpen() {
      if (!current) return false;
      if (current.expiresMs < Date.now()) { current = null; return false; }
      return true;
    },
    close() {
      current = null;
    },
  };
}
