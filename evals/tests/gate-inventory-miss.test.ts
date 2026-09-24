import { test, expect } from "bun:test";
import { randomUUID } from "node:crypto";
import { Endpoint, EndpointAddr, EndpointId } from "@number0/iroh/index.js";
import {
  decodePeerFrame,
  encodePeerFrame,
  encodeStreamOpen,
  PEER_ALPN,
  type PeerAuthorizationSnapshot,
} from "antgrid-wire";
import { EndpointEnrollment } from "../../bridge/src/peer/enrollment";
import { PeerRecords } from "../../bridge/src/peer/records";
import { createMessage } from "../../bridge/src/protocol";
import { generateEvalAuth, setupTestEnv } from "../helpers/harness";

/**
 * Failure-matrix row: a phone's Iroh endpoint the agent's cached
 * authorization lease has never seen. After the Stage B flip the native path
 * authorizes at QUIC accept time (`acceptPeer` in
 * `bridge/src/peer/native-host-connection.ts`) — an endpoint absent from the
 * lease is refused outright (the connection is closed) rather than admitted
 * and then silently dropping an unrecognized app-layer identity. The very
 * next connect from that same endpoint after it registers is what admits it:
 * `acceptPeer` refreshes the lease inline on an unrecognized endpoint id.
 *
 * Superseded: this used to exercise `TrustedPeersProvider.noteMiss()` racing
 * a phone whose Ed25519 identity reached the account inventory after the
 * agent's own startup fetch (see D6, docs/iroh-reduction/stage-B-waves.md).
 * That provider, and native admission's use of it, are deleted — the lease
 * check below is the only gate left.
 */
test("an endpoint absent from the lease is refused at accept, and admitted once it registers", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  let rawEndpoint: Endpoint | undefined;
  let connection: Awaited<ReturnType<Endpoint["connect"]>> | undefined;
  let records: PeerRecords | undefined;
  try {
    const credential = generateEvalAuth();
    env.license.provision(credential);
    const token = async (): Promise<string> => {
      const response = await fetch(`${env.license.url.replace(/\/$/, "")}/api/auth/oauth2/token`, {
        method: "POST",
        headers: {
          authorization: `Basic ${Buffer.from(`${credential.clientId}:${credential.clientSecret}`).toString("base64")}`,
        },
      });
      if (!response.ok) throw new Error(`Eval endpoint token failed: ${response.status}`);
      const body = (await response.json()) as { access_token?: string };
      if (!body.access_token) throw new Error("Eval endpoint token response omitted access_token");
      return body.access_token;
    };
    const enrollment = new EndpointEnrollment(
      { accountId: credential.userId, deviceId: credential.deviceUuid, enrollmentId: credential.clientId },
      credential.endpointSecret,
      credential.ed25519Priv,
      env.license.url,
      token,
    );
    try {
      let target: { endpointId: string } | null = null;
      for (let attempt = 0; attempt < 100 && !target; attempt++) {
        const snapshot = (await enrollment.authorization()) as PeerAuthorizationSnapshot;
        target = snapshot.peers.find((peer) => peer.deviceId === env.agentDeviceId)?.endpoint ?? null;
        if (!target) await Bun.sleep(100);
      }
      if (!target) throw new Error(`agent ${env.agentDeviceId} never published a native endpoint`);

      const builder = Endpoint.builder();
      builder.applyMinimal();
      builder.secretKey(enrollment.seedBytes());
      builder.bindAddr("127.0.0.1:0");
      rawEndpoint = await builder.bind();
      const addr = new EndpointAddr(EndpointId.fromString(target.endpointId), undefined, [`127.0.0.1:${env.nativePort}`]);
      const alpn = Array.from(Buffer.from(PEER_ALPN));

      // (1) This endpoint has never registered, so the agent's inline
      // accept-time refresh still finds nothing for it — refused, not a
      // connection that opens and then drops the first frame.
      // QUIC completes the TLS handshake and opens a stream locally before the
      // agent has judged the endpoint, so a refusal shows only as the agent
      // closing the connection.
      let refused = false;
      let refusedConnection: Awaited<ReturnType<Endpoint["connect"]>> | undefined;
      try {
        refusedConnection = await rawEndpoint.connect(addr, alpn);
        const outcome = await Promise.race([
          refusedConnection.closed().then(() => "closed", () => "closed"),
          Bun.sleep(10_000).then(() => "open"),
        ]);
        refused = outcome === "closed";
      } catch {
        refused = true;
      } finally {
        refusedConnection?.close(1n, []);
      }
      expect(refused).toBe(true);

      // (2) Registering is the refresh trigger: the very next connect from
      // this same endpoint is admitted.
      await enrollment.register();
      // The agent refuses a repeat of an unrecognized id without refreshing
      // for UNKNOWN_ENDPOINT_REFRESH_WINDOW_MS (5s, native-host-connection.ts);
      // the connect that proves admission has to land after it.
      await Bun.sleep(5_500);
      connection = await rawEndpoint.connect(addr, alpn);
      const stream = await connection.openBi();
      records = new PeerRecords(stream, () => true, () => connection?.close(1n, []));
      void records.send(encodeStreamOpen({ kind: "session" }));
      const attemptId = randomUUID();
      const send = (value: object) =>
        records!.send(encodePeerFrame({ type: "message", channel: "control" }, Buffer.from(JSON.stringify(value), "utf8")));
      const read = async (predicate: (value: any) => boolean): Promise<any> => {
        for (;;) {
          const frame = decodePeerFrame(await records!.read());
          const value = JSON.parse(Buffer.from(frame.payload).toString("utf8"));
          const message = value.m ?? value;
          if (predicate(message)) return message;
        }
      };
      await send({
        type: "session:hello",
        attemptId,
        capabilities: { checkoutRouting: true, pullsTree: true, terminalFramesV1: true },
      });
      await read((value) => value.type === "established" && value.attemptId === attemptId);

      const requestId = "gate-inventory-miss-baseline";
      await send({ m: createMessage("request", { requestId, method: "state.snapshot", params: { types: ["*"] } }) });
      const response = await read((value) => value.type === "response" && value.requestId === requestId);
      expect(response.ok).toBe(true);
    } finally {
      enrollment.close();
    }
  } finally {
    records?.close();
    connection?.close(1n, []);
    await rawEndpoint?.close();
    await env.teardown();
  }
}, 60_000);
