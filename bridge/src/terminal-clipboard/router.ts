import { CLIPBOARD_LIFETIME_MS } from "./limits";
import type { ClipboardContext } from "./protocol";

export interface ClipboardOwner extends ClipboardContext {
  client: string; generation: number; claimId: string; epoch: number; expiresAt: number;
}
const key = (context: Pick<ClipboardContext, "checkoutId" | "terminalId" | "runId">) =>
  JSON.stringify([context.checkoutId, context.terminalId, context.runId]);

export class TerminalClipboardRouter {
  private owners = new Map<string, ClipboardOwner>();
  private activity = new Map<string, Map<string, number>>();
  private epoch = 0;

  constructor(
    private readonly valid: (owner: ClipboardOwner) => boolean,
    private readonly revoked: (owner: ClipboardOwner, reason: "conflict" | "stale" | "denied") => void,
    private readonly now: () => number = () => performance.now(),
    private readonly uuid: () => string = () => crypto.randomUUID(),
  ) {}

  interact(context: ClipboardContext, client: string): boolean {
    const address = key(context);
    const recent = this.activity.get(address) ?? new Map<string, number>();
    const now = this.now();
    for (const [peer, at] of recent) if (now - at >= CLIPBOARD_LIFETIME_MS) recent.delete(peer);
    recent.set(client, now);
    this.activity.set(address, recent);
    if (recent.size > 1) {
      const owner = this.owners.get(address);
      if (owner) this.revoke(owner, "conflict");
      return false;
    }
    return true;
  }

  claim(context: ClipboardContext, client: string, generation: number): ClipboardOwner | undefined {
    if (!this.interact(context, client)) return;
    const prior = this.capture(context);
    if (prior) {
      if (prior.client === client && prior.generation === generation && prior.attachmentId === context.attachmentId) {
        // Scanner duplicate suppression shares this identity for the entire epoch.
        prior.expiresAt = this.now() + CLIPBOARD_LIFETIME_MS;
        return prior;
      }
      this.revoke(prior, "stale");
    }
    const owner: ClipboardOwner = {
      ...context, client, generation, claimId: this.uuid(),
      epoch: ++this.epoch,
      expiresAt: this.now() + CLIPBOARD_LIFETIME_MS,
    };
    if (!this.valid(owner)) return;
    this.owners.set(key(context), owner);
    return owner;
  }

  capture(context: Pick<ClipboardContext, "checkoutId" | "terminalId" | "runId">): ClipboardOwner | undefined {
    const owner = this.owners.get(key(context));
    if (owner && !this.current(owner)) { this.revoke(owner, "stale"); return; }
    return owner;
  }

  current(owner: ClipboardOwner): boolean {
    const live = this.owners.get(key(owner));
    return !!live && live.claimId === owner.claimId && live.epoch === owner.epoch &&
      live.generation === owner.generation && live.expiresAt > this.now() && this.valid(live);
  }

  release(context: ClipboardContext, client: string, claimId: string, epoch: number): void {
    const owner = this.owners.get(key(context));
    if (owner?.client === client && owner.attachmentId === context.attachmentId && owner.claimId === claimId && owner.epoch === epoch) this.revoke(owner, "stale");
  }

  dropClient(client: string, attachmentId?: string, disconnected = true): void {
    for (const owner of this.owners.values()) if (owner.client === client && (!attachmentId || owner.attachmentId === attachmentId)) this.revoke(owner, "stale");
    if (!attachmentId && disconnected) for (const recent of this.activity.values()) recent.delete(client);
  }

  dropRun(runId: string): void {
    for (const owner of this.owners.values()) if (owner.runId === runId) this.revoke(owner, "stale");
    for (const address of this.activity.keys()) if ((JSON.parse(address) as string[])[2] === runId) this.activity.delete(address);
  }

  recheck(): void {
    for (const owner of this.owners.values()) if (!this.current(owner)) this.revoke(owner, "denied");
  }

  private revoke(owner: ClipboardOwner, reason: "conflict" | "stale" | "denied"): void {
    this.owners.delete(key(owner));
    this.revoked(owner, reason);
  }
}
