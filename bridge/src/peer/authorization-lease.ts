import { PEER_LEASE_MS, type PeerAuthorizationSnapshot } from "antgrid-wire";
import { AcceptedAuthorizationSnapshotSchema } from "./dev-insecure-relay";

export interface EnrollmentIdentity {
  accountId: string;
  deviceId: string;
  enrollmentId: string;
}

export type LeaseFailure = "expired" | "denied" | "revoked" | "rotated" | "closed";

const SUPERSEDED = Symbol("superseded");

/** A response can consume the request's lifetime, but cannot extend it. */
export class AuthorizationLease {
  private snapshot: PeerAuthorizationSnapshot | null = null;
  private deadline = 0;
  private wallDeadline = 0;
  private generation = 0;
  private policyGeneration = -1n;
  private policyChanges = 0;
  private pending: Promise<boolean> | null = null;
  private cancelExpiry: (() => void) | null = null;
  private cancelRefresh: (() => void) | null = null;
  private stopped = false;
  private transientFailures = 0;

  constructor(
    private readonly identity: EnrollmentIdentity,
    private readonly request: () => Promise<unknown>,
    private readonly onInvalidated: (reason: LeaseFailure) => void,
    private readonly onSnapshot: (snapshot: PeerAuthorizationSnapshot) => void = () => {},
    private readonly now: () => number = () => performance.now(),
    private readonly random: () => number = Math.random,
    private readonly schedule: (callback: () => void, ms: number) => () => void = (callback, ms) => {
      const timer = setTimeout(callback, ms);
      timer.unref?.();
      return () => clearTimeout(timer);
    },
    // The monotonic clock stops across a system suspend on macOS and Linux, so
    // on its own it would carry a lease through a sleep of any length.
    private readonly wall: () => number = () => Date.now(),
  ) {}

  private leftMs(): number {
    return Math.min(this.deadline - this.now(), this.wallDeadline - this.wall());
  }

  get current(): PeerAuthorizationSnapshot | null {
    if (this.snapshot && this.leftMs() <= 0) this.invalidate("expired");
    return this.snapshot;
  }

  get remainingMs(): number {
    return this.snapshot ? Math.max(0, this.leftMs()) : 0;
  }

  allows(deviceId: string, endpointId?: string): boolean {
    return this.current?.peers.some((peer) => peer.deviceId === deviceId &&
      (endpointId === undefined || peer.endpoint?.endpointId === endpointId)) ?? false;
  }

  names(deviceId: string, ed25519Pub: string): boolean {
    return this.current?.peers.some((peer) => peer.deviceId === deviceId && peer.ed25519Pub === ed25519Pub) ?? false;
  }

  /**
   * Drops the current snapshot but lets a request already in flight finish:
   * its answer is judged by the policy generation the server read, and one
   * from before this change is asked again rather than refused. Fencing it by
   * request instead discarded the answer to this host's own endpoint
   * registration, whose policy change is pushed back while that answer is
   * still on the way, and startup failed on it.
   */
  observePolicyGeneration(generation: string): void {
    const next = BigInt(generation);
    if (this.stopped || next <= this.policyGeneration) return;
    this.policyGeneration = next;
    this.policyChanges++;
    this.drop("revoked");
  }

  refresh(): Promise<boolean> {
    if (this.stopped) return Promise.resolve(false);
    if (this.pending) return this.pending;
    this.cancelRefresh?.();
    this.cancelRefresh = null;
    const operation = (async () => {
      // Every caller joined to this request gets an answer from after the
      // last pushed policy change, not the one that change superseded.
      for (;;) {
        const outcome = await this.attempt();
        if (outcome !== SUPERSEDED) return outcome;
      }
    })();
    this.pending = operation.finally(() => { this.pending = null; });
    return this.pending;
  }

  private async attempt(): Promise<boolean | typeof SUPERSEDED> {
    const generation = this.generation;
    const policyChanges = this.policyChanges;
    const started = this.now();
    const startedWall = this.wall();
    // Must stay the schema `EndpointEnrollment` registers against. A host
    // that enrolls for an origin and then refuses every snapshot carrying it
    // kills its own transport at startup, and a rejected parse surfaces as a
    // Zod dump under PEER_TRANSPORT_UNAVAILABLE rather than a scheme refusal.
    const remaining = this.snapshot ? Math.max(0, this.leftMs()) : 10_000;
    const timeoutMs = Math.min(10_000, remaining);
    if (timeoutMs <= 0) {
      this.invalidate("expired");
      return false;
    }
    let cancelTimeout: () => void = () => {};
    let response: unknown;
    try {
      response = await Promise.race([
        this.request(),
        new Promise<never>((_, reject) => {
          cancelTimeout = this.schedule(() => reject(new Error("AUTHORIZATION_TIMEOUT")), timeoutMs);
        }),
      ]);
    } catch (error) {
      if (this.stopped || generation !== this.generation) return false;
      // An error carries no policy generation, so one that lands after a
      // policy change cannot show which side of it the server answered from.
      if (policyChanges !== this.policyChanges) return SUPERSEDED;
      const valid = this.snapshot !== null && this.leftMs() > 0;
      if (valid) this.scheduleTransientRetry();
      if (valid) return true;
      throw error;
    } finally {
      cancelTimeout();
    }
    const parsed = AcceptedAuthorizationSnapshotSchema.parse(response);
    if (this.stopped || generation !== this.generation) return false;
    if (parsed.accountId !== this.identity.accountId || parsed.deviceId !== this.identity.deviceId ||
        parsed.enrollmentId !== this.identity.enrollmentId) {
      this.invalidate("rotated");
      return false;
    }
    const policy = BigInt(parsed.policyGeneration);
    if (policy < this.policyGeneration) return policyChanges !== this.policyChanges ? SUPERSEDED : false;
    this.policyGeneration = policy;
    if (!parsed.allowed) {
      this.invalidate("denied");
      return false;
    }
    const acceptedDuration = Math.min(parsed.leaseMs, PEER_LEASE_MS);
    const deadline = started + acceptedDuration;
    const wallDeadline = startedWall + acceptedDuration;
    if (this.now() >= deadline || this.wall() >= wallDeadline) {
      this.invalidate("expired");
      return false;
    }
    const previous = this.snapshot?.endpoint;
    if (previous && (previous.endpointId !== parsed.endpoint?.endpointId ||
        previous.generation !== parsed.endpoint?.generation)) {
      this.invalidate("rotated");
      return false;
    }
    this.snapshot = parsed;
    this.deadline = deadline;
    this.wallDeadline = wallDeadline;
    this.transientFailures = 0;
    this.cancelExpiry?.();
    this.cancelExpiry = this.schedule(() => this.invalidate("expired"), Math.max(0, deadline - this.now()));
    const refreshAt = started + acceptedDuration / 3 * (0.9 + this.random() * 0.2);
    this.cancelRefresh = this.schedule(() => {
      this.cancelRefresh = null;
      void this.refresh().catch(() => {});
    }, Math.max(0, refreshAt - this.now()));
    // Session owners synchronously recheck each peer before dispatch resumes.
    this.onSnapshot(parsed);
    return true;
  }

  invalidate(reason: LeaseFailure): void {
    this.generation++;
    this.drop(reason);
  }

  private drop(reason: LeaseFailure): void {
    this.snapshot = null;
    this.deadline = 0;
    this.wallDeadline = 0;
    this.cancelExpiry?.();
    this.cancelExpiry = null;
    this.cancelRefresh?.();
    this.cancelRefresh = null;
    if (reason === "closed") this.stopped = true;
    this.onInvalidated(reason);
  }

  private scheduleTransientRetry(): void {
    const ceiling = Math.min(5_000, 500 * 2 ** this.transientFailures++);
    const delay = ceiling / 2 + this.random() * ceiling / 2;
    const remaining = this.leftMs();
    if (remaining <= 0) {
      this.invalidate("expired");
      return;
    }
    this.cancelRefresh?.();
    this.cancelRefresh = this.schedule(() => {
      this.cancelRefresh = null;
      void this.refresh().catch(() => {});
    }, Math.min(delay, remaining));
  }
}
