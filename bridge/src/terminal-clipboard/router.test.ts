import { describe, expect, test } from "bun:test";
import { TerminalClipboardRouter, type ClipboardOwner } from "./router";
import { TerminalClipboardScanner } from "./scanner";

const context = { checkoutId: "checkout", terminalId: "terminal", runId: "run", attachmentId: "attachment" };
function fixture() {
  let now = 0, id = 0, allowed = true;
  const revocations: { owner: ClipboardOwner; reason: string }[] = [];
  const router = new TerminalClipboardRouter(() => allowed, (owner, reason) => revocations.push({ owner, reason }), () => now, () => String(++id));
  return { router, revocations, time: (value: number) => { now = value; }, deny: () => { allowed = false; } };
}

describe("terminal clipboard ownership", () => {
  test("renewals retain identity so scanner deduplication spans repeated input", () => {
    const f = fixture();
    const owner = f.router.claim(context, "a", 1)!;
    const scanner = new TerminalClipboardScanner(() => f.router.capture(context), () => 0);
    expect(scanner.feed("\x1b]52;c;YQ==\x07").writes).toHaveLength(1);
    f.time(100);
    expect(f.router.claim(context, "a", 1)).toBe(owner);
    expect(scanner.feed("\x1b]52;c;YQ==\x07").writes).toHaveLength(0);
  });
  test("connection replacement changes the epoch and invalidates captured events", () => {
    const f = fixture();
    const old = f.router.claim(context, "a", 1)!;
    const next = f.router.claim(context, "a", 2)!;
    expect(next.epoch).not.toBe(old.epoch);
    expect(next.claimId).not.toBe(old.claimId);
    expect(f.router.current(old)).toBe(false);
  });
  test("release retains the ambiguity window and elapsed time alone restores nothing", () => {
    const f = fixture();
    const old = f.router.claim(context, "a", 1)!;
    f.router.release(context, "a", old.claimId, old.epoch);
    expect(f.router.claim(context, "b", 1)).toBeUndefined();
    f.time(5000);
    expect(f.router.capture(context)).toBeUndefined();
    expect(f.router.claim(context, "b", 1)).toBeDefined();
    expect(f.router.current(old)).toBe(false);
  });
  test("old clients conflict, disconnected clients cease contributing activity", () => {
    const f = fixture();
    const owner = f.router.claim(context, "a", 1)!;
    expect(f.router.interact(context, "legacy")).toBe(false);
    expect(f.router.current(owner)).toBe(false);
    expect(f.router.claim(context, "a", 1)).toBeUndefined();
    f.router.dropClient("legacy");
    expect(f.router.claim(context, "a", 1)).toBeDefined();
  });
  test("backgrounding revokes ownership without erasing recent interaction", () => {
    const f = fixture();
    const owner = f.router.claim(context, "a", 1)!;
    f.router.dropClient("a", undefined, false);
    expect(f.router.current(owner)).toBe(false);
    expect(f.router.claim(context, "b", 1)).toBeUndefined();
    f.time(5000);
    expect(f.router.claim(context, "b", 1)).toBeDefined();
  });
  test("attachment, checkout, run, and release credentials remain isolated", () => {
    const f = fixture();
    const owner = f.router.claim(context, "a", 1)!;
    for (const field of ["attachmentId", "checkoutId", "runId", "terminalId"] as const) {
      f.router.release({ ...context, [field]: "forged" }, "a", owner.claimId, owner.epoch);
      expect(f.router.current(owner)).toBe(true);
    }
    f.router.release(context, "b", owner.claimId, owner.epoch);
    expect(f.router.current(owner)).toBe(true);
    f.router.dropRun(context.runId);
    expect(f.router.current(owner)).toBe(false);
  });
  test("expiry and access revocation invalidate captured owners immediately", () => {
    const f = fixture();
    const owner = f.router.claim(context, "a", 1)!;
    f.time(5000);
    expect(f.router.capture(context)).toBeUndefined();
    const next = f.router.claim(context, "a", 1)!;
    f.deny();
    expect(f.router.current(next)).toBe(false);
    f.router.recheck();
    expect(f.revocations.map((v) => v.reason)).toEqual(["stale", "denied"]);
    expect(f.router.current(owner)).toBe(false);
  });
});
