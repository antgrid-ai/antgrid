// Generates the cross-language native peer transport pin.
// Run: cd packages/antgrid-wire && bun run gen:peer-vectors
import {
  CHANNEL_WINDOW_BYTES,
  CREDIT_BATCH_BYTES,
  ENDPOINT_CHALLENGE_MS,
  FIXED_PREFIX,
  FRAG_DATA_BUDGET,
  FRAG_THRESHOLD,
  FRAME_VERSION,
  FrameKind,
  GLOBAL_REASSEMBLY_BUDGET,
  MAX_FRAGMENT_COUNT,
  MAX_FRAME_PAYLOAD,
  MAX_REREQUESTS,
  MAX_TRANSFER_BYTES,
  MAX_HEADER_LEN,
  MAX_SEND_QUEUE_BYTES,
  PEER_ALPN,
  PEER_IDENTITY_MAX_CHARS,
  PEER_LEASE_MS,
  PEER_MAX_AUTHORIZED_PEERS,
  PEER_MAX_GENERATION,
  PEER_MAX_RECORD_BYTES,
  PEER_MAX_RELAY_URLS,
  PEER_REFRESH_MS,
  PEER_SELECTION_MS,
  SEAL_OVERHEAD_BYTES,
  SOCKET_INFLIGHT_BYTES,
  TRANSFER_TIMEOUT_MS,
  WINDOW_RESYNC_AGE_MS,
  WINDOW_STALL_WARN_MS,
  encodePeerFrame,
} from "../src/index";

export function buildPeerTransportVectors() {
  const samples = [
    {
      name: "sealed-control",
      header: { type: "message", channel: "control" } as const,
      kind: FrameKind.sealed,
      payloadHex: "deadbeef",
    },
    {
      name: "handshake-preview",
      header: { type: "message", channel: "preview" } as const,
      kind: FrameKind.handshake,
      payloadHex: "000102ff",
    },
  ].map((sample) => ({
    ...sample,
    frameHex: Buffer.from(
      encodePeerFrame(
        sample.header,
        Buffer.from(sample.payloadHex, "hex"),
        sample.kind,
      ),
    ).toString("hex"),
  }));

  return {
    comment:
      "Peer transport v3 cross-language pin. Regenerate: cd packages/antgrid-wire && bun run gen:peer-vectors",
    framing: {
      version: FRAME_VERSION,
      fixedPrefixBytes: FIXED_PREFIX,
      maxHeaderBytes: MAX_HEADER_LEN,
      maxPayloadBytes: MAX_FRAME_PAYLOAD,
      maxRecordBytes: PEER_MAX_RECORD_BYTES,
      kinds: FrameKind,
      samples,
    },
    native: {
      alpn: PEER_ALPN,
      leaseMs: PEER_LEASE_MS,
      refreshMs: PEER_REFRESH_MS,
      selectionMs: PEER_SELECTION_MS,
      endpointChallengeMs: ENDPOINT_CHALLENGE_MS,
    },
    fragmentation: {
      thresholdBytes: FRAG_THRESHOLD,
      dataBudgetBytes: FRAG_DATA_BUDGET,
      maxTransferBytes: MAX_TRANSFER_BYTES,
      transferTimeoutMs: TRANSFER_TIMEOUT_MS,
      globalReassemblyBudgetBytes: GLOBAL_REASSEMBLY_BUDGET,
      maxRerequests: MAX_REREQUESTS,
      maxFragmentCount: MAX_FRAGMENT_COUNT,
    },
    flowControl: {
      channelWindowBytes: CHANNEL_WINDOW_BYTES,
      socketInflightBytes: SOCKET_INFLIGHT_BYTES,
      creditBatchBytes: CREDIT_BATCH_BYTES,
      maxSendQueueBytes: MAX_SEND_QUEUE_BYTES,
      sealOverheadBytes: SEAL_OVERHEAD_BYTES,
      windowResyncAgeMs: WINDOW_RESYNC_AGE_MS,
      windowStallWarnMs: WINDOW_STALL_WARN_MS,
    },
    authorization: {
      identityMaxChars: PEER_IDENTITY_MAX_CHARS,
      maxAuthorizedPeers: PEER_MAX_AUTHORIZED_PEERS,
      maxRelayUrls: PEER_MAX_RELAY_URLS,
      maxGeneration: PEER_MAX_GENERATION,
      maxLeaseMs: PEER_LEASE_MS,
    },
  };
}

if (import.meta.main) {
  await Bun.write(
    new URL("../../../evals/fixtures/peer-transport-vectors.json", import.meta.url),
    JSON.stringify(buildPeerTransportVectors(), null, 2) + "\n",
  );
  console.log("wrote evals/fixtures/peer-transport-vectors.json");
}
