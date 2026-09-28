import { createHmac, createPublicKey, randomBytes, randomUUID, verify } from "node:crypto";
import {
  EndpointChallengeRequestSchema, EndpointRegistrationRequestSchema,
  PeerAuthorizationSnapshotSchema, endpointChallengeBytes,
  type EndpointChallenge,
} from "antgrid-wire";

export interface FixtureCredential {
  clientId: string;
  clientSecret: string;
  deviceUuid: string;
  ed25519Pub: string;
  userId: string;
}

/** In-memory authorization authority for transport evaluations, not a JWT/backend qualification. */
export class PeerAuthorizationFixture {
  private credentials = new Map<string, FixtureCredential>();
  private tokens = new Map<string, { clientId: string; expires: number }>();
  private signingSecret = randomBytes(32);
  private registrations = new Map<string, { endpointId: string; generation: string }>();
  private endpointHistory = new Set<string>();
  private challenges = new Map<string, { value: EndpointChallenge; expires: number }>();
  private revoked = new Set<string>();
  private generation = 0n;

  constructor(private peers: () => Array<{ deviceId: string; ed25519Pub: string }>) {}

  provision(auth: FixtureCredential): void { this.credentials.set(auth.clientId, auth); }
  revoke(deviceId: string): void { this.revoked.add(deviceId); this.generation++; }

  token(authorization: string | null): string | null {
    if (!authorization?.startsWith("Basic ")) return null;
    const [id, secret] = Buffer.from(authorization.slice(6), "base64").toString().split(":");
    const credential = this.credentials.get(id!);
    if (!credential || credential.clientSecret !== secret || this.revoked.has(credential.deviceUuid)) return null;
    const expires = Math.floor(Date.now() / 1000) + 3600;
    // The bridge reads the issued tier claim; endpoint routes still require an
    // exact token issued by this authority rather than trusting decoded claims.
    const header = Buffer.from(JSON.stringify({ alg: "HS256", typ: "JWT" })).toString("base64url");
    const payload = Buffer.from(JSON.stringify({ exp: expires, tier: "pro", uid: credential.userId,
      azp: credential.clientId, deviceUuid: credential.deviceUuid, pk: credential.ed25519Pub })).toString("base64url");
    const bytes = `${header}.${payload}`;
    const token = `${bytes}.${createHmac("sha256", this.signingSecret).update(bytes).digest("base64url")}`;
    for (const [old, value] of this.tokens) if (value.expires <= Date.now() / 1000) this.tokens.delete(old);
    this.tokens.set(token, { clientId: credential.clientId, expires });
    return token;
  }

  async handle(req: Request): Promise<Response | null> {
    const route = new URL(req.url).pathname.split("/").at(-1);
    if (!["authorization", "endpoint-challenge", "endpoint-registration"].includes(route!)) return null;
    const token = req.headers.get("authorization")?.replace(/^Bearer /, "");
    const issued = token ? this.tokens.get(token) : undefined;
    const auth = issued && issued.expires > Date.now() / 1000 ? this.credentials.get(issued.clientId) : undefined;
    if (!auth) return Response.json({ error: "invalid_device" }, { status: 401 });
    const allowed = !this.revoked.has(auth.deviceUuid);
    const existing = this.registrations.get(auth.clientId);
    const identity = { accountId: auth.userId, deviceId: auth.deviceUuid, enrollmentId: auth.clientId };
    if (route === "authorization" && req.method === "GET") {
      const accountPeers = new Map(this.peers().map((peer) => [peer.deviceId, peer]));
      for (const credential of this.credentials.values()) {
        if (credential.userId !== auth.userId) continue;
        accountPeers.set(credential.deviceUuid, { deviceId: credential.deviceUuid, ed25519Pub: credential.ed25519Pub });
      }
      return Response.json(PeerAuthorizationSnapshotSchema.parse({
        ...identity, allowed, leaseMs: allowed ? 60_000 : 0,
        policyGeneration: String(this.generation), registrationGeneration: existing?.generation ?? "0",
        endpoint: allowed ? existing ?? null : null, relayUrls: ["https://relay.invalid/"],
        peers: [...accountPeers.values()].filter((peer) => peer.deviceId !== auth.deviceUuid && !this.revoked.has(peer.deviceId))
          .map((peer) => {
            const credential = [...this.credentials.values()].find((value) =>
              value.userId === auth.userId && value.deviceUuid === peer.deviceId);
            return { ...peer, endpoint: credential ? this.registrations.get(credential.clientId) ?? null : null };
          }),
      }));
    }
    if (!allowed) return Response.json({ error: "revoked" }, { status: 403 });
    if (req.method !== "POST") return new Response(null, { status: 405 });
    const body = await req.json().catch(() => null);
    if (route === "endpoint-challenge") {
      const parsed = EndpointChallengeRequestSchema.safeParse(body);
      if (!parsed.success) return new Response(null, { status: 400 });
      if (parsed.data.expectedGeneration !== (existing?.generation ?? "0")) return new Response(null, { status: 409 });
      const value = { ...parsed.data, ...identity, challengeId: randomUUID(), challenge: randomBytes(32).toString("base64") };
      this.challenges.set(value.challengeId, { value, expires: Date.now() + 120_000 });
      return Response.json(value);
    }
    const parsed = EndpointRegistrationRequestSchema.safeParse(body);
    if (!parsed.success) return new Response(null, { status: 400 });
    const challenge = this.challenges.get(parsed.data.challengeId);
    if (!challenge || challenge.expires <= Date.now() || challenge.value.enrollmentId !== auth.clientId) return new Response(null, { status: 403 });
    this.challenges.delete(parsed.data.challengeId);
    if (challenge.value.expectedGeneration !== (this.registrations.get(auth.clientId)?.generation ?? "0") || this.endpointHistory.has(challenge.value.endpointId)) return new Response(null, { status: 409 });
    const bytes = endpointChallengeBytes(challenge.value);
    const publicKey = (raw: Buffer) => createPublicKey({ key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), raw]), format: "der", type: "spki" });
    if (!verify(null, bytes, publicKey(Buffer.from(auth.ed25519Pub, "base64")), Buffer.from(parsed.data.deviceSignature, "base64")) ||
      !verify(null, bytes, publicKey(Buffer.from(challenge.value.endpointId, "hex")), Buffer.from(parsed.data.endpointSignature, "base64"))) return new Response(null, { status: 403 });
    const registration = { endpointId: challenge.value.endpointId, generation: String(BigInt(challenge.value.expectedGeneration) + 1n) };
    this.registrations.set(auth.clientId, registration);
    this.endpointHistory.add(registration.endpointId);
    this.generation++;
    return Response.json(registration);
  }
}
