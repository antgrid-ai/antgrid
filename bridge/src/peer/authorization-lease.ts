import { PEER_LEASE_MS, type PeerAuthorizationSnapshot } from "antgrid-wire";
import { AcceptedAuthorizationSnapshotSchema } from "./dev-insecure-relay";

export interface EnrollmentIdentity {
  accountId: string;
  deviceId: string;
  enrollmentId: string;
}

export type LeaseFailure = "expired" | "denied" | "revoked" | "rotated" | "resume" | "closed";

/** A response can consume the request's lifetime, but cannot extend it. */
export class AuthorizationLease {
  private snapshot: PeerAuthorizationSnapshot | null = null;
  private deadline = 0;
  private generation = 0;
  private policyGeneration = -1n;
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
  ) {}

  get current(): PeerAuthorizationSnapshot | null {
    if (this.snapshot && this.now() >= this.deadline) this.invalidate("expired");
    return this.snapshot;
  }

  get remainingMs(): number {
    return this.snapshot ? Math.max(0, this.deadline - this.now()) : 0;
  }

  allows(deviceId: string, endpointId?: string): boolean {
    return this.current?.peers.some((peer) => peer.deviceId === deviceId &&
      (endpointId === undefined || peer.endpoint?.endpointId === endpointId)) ?? false;
  }

  observePolicyGeneration(generation: string): void {
    const next = BigInt(generation);
    if (next <= this.policyGeneration) return;
    this.policyGeneration = next;
    this.invalidate("revoked");
  }

  refresh(): Promise<boolean> {
    if (this.stopped) return Promise.resolve(false);
    if (this.pending) return this.pending;
    this.cancelRefresh?.();
    this.cancelRefresh = null;
    const generation = this.generation;
    const started = this.now();
    const operation = (async () => {
      // Must stay the schema `EndpointEnrollment` registers against. A host
      // that enrolls for an origin and then refuses every snapshot carrying it
      // kills its own transport at startup, and a rejected parse surfaces as a
      // Zod dump under PEER_TRANSPORT_UNAVAILABLE rather than a scheme refusal.
      const remaining = this.snapshot ? Math.max(0, this.deadline - started) : 10_000;
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
        const valid = this.snapshot !== null && this.now() < this.deadline;
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
      if (policy < this.policyGeneration) return false;
      this.policyGeneration = policy;
      if (!parsed.allowed) {
        this.invalidate("denied");
        return false;
      }
      const deadline = started + Math.min(parsed.leaseMs, PEER_LEASE_MS);
      if (this.now() >= deadline) {
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
      this.transientFailures = 0;
      this.cancelExpiry?.();
      this.cancelExpiry = this.schedule(() => this.invalidate("expired"), Math.max(0, deadline - this.now()));
      const acceptedDuration = deadline - started;
      const refreshAt = started + acceptedDuration / 3 * (0.9 + this.random() * 0.2);
      this.cancelRefresh = this.schedule(() => {
        this.cancelRefresh = null;
        void this.refresh().catch(() => {});
      }, Math.max(0, refreshAt - this.now()));
      // Session owners synchronously recheck each peer before dispatch resumes.
      this.onSnapshot(parsed);
      return true;
    })();
    this.pending = operation.finally(() => { this.pending = null; });
    return this.pending;
  }

  resume(): Promise<boolean> {
    const pending = this.pending;
    this.invalidate("resume");
    // An in-flight pre-sleep response is fenced, then a new request starts.
    return pending ? pending.catch(() => false).then(() => this.refresh()) : this.refresh();
  }

  invalidate(reason: LeaseFailure): void {
    this.generation++;
    this.snapshot = null;
    this.deadline = 0;
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
    const remaining = this.deadline - this.now();
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
