import { describe, it, expect } from "bun:test";
import { createPairingWindow } from "../src/pairing-window";

describe("pairing window", () => {
  it("open returns code + expiresAt; isOpen=true", () => {
    const w = createPairingWindow();
    const { code, expiresAt } = w.open();
    expect(code.length).toBeGreaterThan(20);
    expect(new Date(expiresAt).getTime()).toBeGreaterThan(Date.now());
    expect(w.isOpen()).toBe(true);
  });

  it("consume succeeds once, then fails (single-use)", () => {
    const w = createPairingWindow();
    const { code } = w.open();
    expect(w.consume(code)).toBe(true);
    expect(w.consume(code)).toBe(false);
    expect(w.isOpen()).toBe(false);
  });

  it("consume rejects wrong code", () => {
    const w = createPairingWindow();
    w.open();
    expect(w.consume("wrong-code")).toBe(false);
  });

  it("re-open replaces previous window", () => {
    const w = createPairingWindow();
    const a = w.open();
    const b = w.open();
    expect(a.code).not.toBe(b.code);
    expect(w.consume(a.code)).toBe(false);
    expect(w.consume(b.code)).toBe(true);
  });

  it("close() discards unconsumed code so isOpen=false and consume fails", () => {
    // Regression: stopRelay() must clear the window or the next enableRelay
    // hits the onAuthenticated `!isOpen()` guard and skips re-emitting
    // agent:pairingReady — wizard stuck at "connecting relay".
    const w = createPairingWindow();
    const { code } = w.open();
    expect(w.isOpen()).toBe(true);
    w.close();
    expect(w.isOpen()).toBe(false);
    expect(w.consume(code)).toBe(false);
  });

  it("close() is safe when no window is open", () => {
    const w = createPairingWindow();
    expect(() => w.close()).not.toThrow();
    expect(w.isOpen()).toBe(false);
  });

  it("can open a fresh window after close()", () => {
    const w = createPairingWindow();
    const a = w.open();
    w.close();
    const b = w.open();
    expect(a.code).not.toBe(b.code);
    expect(w.consume(a.code)).toBe(false);
    expect(w.consume(b.code)).toBe(true);
  });

  it("isOpen=false after expiry", () => {
    const w = createPairingWindow({ ttlMs: 5 });
    w.open();
    return new Promise<void>((r) => setTimeout(() => {
      expect(w.isOpen()).toBe(false);
      r();
    }, 20));
  });
});
