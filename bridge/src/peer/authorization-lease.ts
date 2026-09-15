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
  private timer: ReturnType<typeof setTimeout> | null = null;
  private stopped = false;

  constructor(
    private readonly identity: EnrollmentIdentity,
    private readonly request: () => Promise<unknown>,
    private readonly onInvalidated: (reason: LeaseFailure) => void,
    private readonly onSnapshot: (snapshot: PeerAuthorizationSnapshot) => void = () => {},
    private readonly now: () => number = () => performance.now(),
  ) {}

  get current(): PeerAuthorizationSnapshot | null {
    if (this.snapshot && this.now() >= this.deadline) this.invalidate("expired");
    return this.snapshot;
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
    const generation = this.generation;
    const started = this.now();
    const operation = (async () => {
      // Must stay the schema `EndpointEnrollment` registers against. A host
      // that enrolls for an origin and then refuses every snapshot carrying it
      // kills its own transport at startup, and a rejected parse surfaces as a
      // Zod dump under PEER_TRANSPORT_UNAVAILABLE rather than a scheme refusal.
      const parsed = AcceptedAuthorizationSnapshotSchema.parse(await this.request());
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
      if (this.timer) clearTimeout(this.timer);
      this.timer = setTimeout(() => this.invalidate("expired"), Math.max(0, deadline - this.now()));
      this.timer.unref?.();
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
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    if (reason === "closed") this.stopped = true;
    this.onInvalidated(reason);
  }
}
