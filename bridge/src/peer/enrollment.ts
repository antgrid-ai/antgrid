import { createPrivateKey, createPublicKey, sign } from "node:crypto";
import { EndpointChallengeSchema, EndpointRegistrationSchema, endpointChallengeBytes } from "antgrid-wire";
import { AcceptedAuthorizationSnapshotSchema } from "./dev-insecure-relay";
import { rawSeedToPkcs8 } from "../e2e";
import type { EnrollmentIdentity } from "./authorization-lease";

export class EndpointApiError extends Error {
  constructor(readonly status: number) { super(`Endpoint API refused request (${status})`); }
}

export class EndpointEnrollment {
  readonly endpointId: string;
  private readonly seed: Buffer;
  private stopped = false;

  constructor(
    private readonly identity: EnrollmentIdentity,
    endpointSecret: string,
    private readonly deviceSecret: string,
    private readonly baseUrl: string,
    private readonly getToken: () => Promise<string> | string,
    private readonly request: typeof fetch = fetch,
  ) {
    this.seed = Buffer.from(endpointSecret, "base64");
    if (this.seed.length !== 32) throw new Error("Invalid endpoint secret");
    this.endpointId = createPublicKey(this.privateKey(this.seed)).export({ type: "spki", format: "der" }).subarray(-32).toString("hex");
  }

  seedBytes(): number[] { return Array.from(this.seed); }

  private privateKey(seed: Buffer) {
    return createPrivateKey({ key: rawSeedToPkcs8(seed), format: "der", type: "pkcs8" });
  }

  async authorization(): Promise<unknown> {
    return this.call("authorization");
  }

  async register(): Promise<void> {
    const snapshot = AcceptedAuthorizationSnapshotSchema.parse(await this.authorization());
    this.checkIdentity(snapshot);
    if (!snapshot.allowed) throw new Error("Endpoint authorization denied");
    if (snapshot.endpoint?.endpointId === this.endpointId) return;
    const challenge = EndpointChallengeSchema.parse(await this.call("endpoint-challenge", {
      endpointId: this.endpointId, expectedGeneration: snapshot.registrationGeneration,
    }));
    if (this.stopped) throw new Error("Endpoint enrollment closed");
    this.checkIdentity(challenge);
    if (challenge.endpointId !== this.endpointId || challenge.expectedGeneration !== (snapshot.registrationGeneration)) {
      throw new Error("Endpoint challenge binding mismatch");
    }
    const bytes = endpointChallengeBytes(challenge);
    const registration = EndpointRegistrationSchema.parse(await this.call("endpoint-registration", {
      challengeId: challenge.challengeId,
      endpointSignature: sign(null, bytes, this.privateKey(this.seed)).toString("base64"),
      deviceSignature: sign(null, bytes, this.privateKey(Buffer.from(this.deviceSecret, "base64"))).toString("base64"),
    }));
    if (registration.endpointId !== this.endpointId || BigInt(registration.generation) !== BigInt(challenge.expectedGeneration) + 1n) {
      throw new Error("Endpoint registration binding mismatch");
    }
  }

  private checkIdentity(value: EnrollmentIdentity): void {
    if (value.accountId !== this.identity.accountId || value.deviceId !== this.identity.deviceId ||
        value.enrollmentId !== this.identity.enrollmentId) throw new Error("Endpoint credential binding mismatch");
  }

  private async call(route: string, body?: object): Promise<unknown> {
    if (this.stopped) throw new Error("Endpoint enrollment closed");
    const response = await this.request(`${this.baseUrl.replace(/\/$/, "")}/account/devices/me/${route}`, {
      method: body ? "POST" : "GET",
      headers: { authorization: `Bearer ${await this.getToken()}`, ...(body ? { "content-type": "application/json" } : {}) },
      body: body ? JSON.stringify(body) : undefined,
      signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) throw new EndpointApiError(response.status);
    return response.json();
  }

  close(): void { this.stopped = true; this.seed.fill(0); }
}
