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
  SOCKET_INFLIGHT_BYTES,
  STREAM_MAX_BIDI_STREAMS_PER_CONNECTION,
  STREAM_MAX_PENDING_OPENS_PER_PEER,
  STREAM_MAX_PROJECTS_PER_PEER,
  STREAM_MAX_TERMINAL_ATTACHMENTS_PER_PEER,
  STREAM_MAX_TUNNEL_STREAMS_PER_PEER,
  STREAM_OPEN_MAX_BYTES,
  STREAM_OPEN_MAX_ID_LENGTH,
  STREAM_TERMINAL_APP_RECORD_MAX_BYTES,
  STREAM_TERMINAL_BRIDGE_RECORD_MAX_BYTES,
  StreamOpen,
  StreamRefused,
  TRANSFER_TIMEOUT_MS,
  WINDOW_RESYNC_AGE_MS,
  WINDOW_STALL_WARN_MS,
  encodePeerFrame,
} from "../src/index";

export function buildPeerTransportVectors() {
  const samples = [
    {
      name: "message-control",
      header: { type: "message", channel: "control" } as const,
      kind: FrameKind.message,
      payloadHex: "deadbeef",
    },
    {
      name: "message-preview",
      header: { type: "message", channel: "preview" } as const,
      kind: FrameKind.message,
      payloadHex: "000102ff",
    },
  ].map((sample) => ({
    ...sample,
    frameHex: Buffer.from(
      encodePeerFrame(sample.header, Buffer.from(sample.payloadHex, "hex")),
    ).toString("hex"),
  }));

  return {
    comment:
      "Peer transport v4 cross-language pin. Regenerate: cd packages/antgrid-wire && bun run gen:peer-vectors",
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
    streamOpen: buildStreamOpenVectors(),
  };
}

// Stream open-frame JSON, not record bytes: what both hand-written parsers
// must accept AND reject identically, plus the constants they mirror. Every
// kind, refusal code and rejection rule needs an entry here, or the Dart side
// can drift with nothing to catch it.
function buildStreamOpenVectors() {
  const opens = [
    { name: "session", json: { kind: "session" } },
    { name: "project", json: { kind: "project", projectId: "proj-1" } },
    {
      name: "terminal",
      json: { kind: "terminal", projectId: "proj-1", requestId: "req-1" },
    },
    {
      name: "terminal-with-checkout",
      json: {
        kind: "terminal",
        projectId: "proj-1",
        checkoutId: "chk-1",
        requestId: "req-1",
      },
    },
    {
      name: "tunnel-http",
      json: { kind: "tunnel-http", projectId: "proj-1", requestId: "req-1" },
    },
    {
      name: "tunnel-ws",
      json: { kind: "tunnel-ws", projectId: "proj-1", wsId: "ws-1" },
    },
  ].map((sample) => {
    // Fails loudly at generation time if a sample and the schema drift,
    // rather than shipping a fixture neither language can actually parse.
    StreamOpen.parse(sample.json);
    return sample;
  });

  const refusals = [
    {
      name: "not-ready",
      json: { type: "stream:refused", code: "NOT_READY", message: "project core is still starting" },
    },
    {
      name: "update-required",
      json: { type: "stream:refused", code: "UPDATE_REQUIRED", message: "update the app to open this stream" },
    },
    {
      name: "not-allowed",
      json: { type: "stream:refused", code: "NOT_ALLOWED", message: "remote access is disabled on this machine" },
    },
    {
      name: "cap-exceeded",
      json: { type: "stream:refused", code: "CAP_EXCEEDED", message: "too many terminal attachments for this peer" },
    },
    {
      name: "invalid",
      json: { type: "stream:refused", code: "INVALID", message: "the open frame did not parse" },
    },
  ].map((sample) => {
    StreamRefused.parse(sample.json);
    return sample;
  });

  const overlongId = "x".repeat(STREAM_OPEN_MAX_ID_LENGTH + 1);
  const rejectedOpens = [
    { name: "missing-kind", json: { projectId: "proj-1" } },
    { name: "unknown-kind", json: { kind: "request", projectId: "proj-1" } },
    { name: "non-string-kind", json: { kind: 1 } },
    { name: "session-extra-field", json: { kind: "session", projectId: "proj-1" } },
    { name: "project-with-checkout", json: { kind: "project", projectId: "proj-1", checkoutId: "main" } },
    { name: "project-empty-id", json: { kind: "project", projectId: "" } },
    { name: "project-numeric-id", json: { kind: "project", projectId: 7 } },
    { name: "project-overlong-id", json: { kind: "project", projectId: overlongId } },
    { name: "terminal-missing-request", json: { kind: "terminal", projectId: "proj-1" } },
    { name: "terminal-null-checkout", json: { kind: "terminal", projectId: "proj-1", checkoutId: null, requestId: "req-1" } },
    { name: "terminal-empty-checkout", json: { kind: "terminal", projectId: "proj-1", checkoutId: "", requestId: "req-1" } },
    { name: "tunnel-http-missing-request", json: { kind: "tunnel-http", projectId: "proj-1" } },
    { name: "tunnel-ws-request-not-ws", json: { kind: "tunnel-ws", projectId: "proj-1", requestId: "req-1" } },
    { name: "tunnel-ws-overlong-id", json: { kind: "tunnel-ws", projectId: "proj-1", wsId: overlongId } },
  ].map((sample) => {
    if (StreamOpen.safeParse(sample.json).success) {
      throw new Error(`rejected open vector ${sample.name} parses`);
    }
    return sample;
  });

  const rejectedRefusals = [
    { name: "unknown-code", json: { type: "stream:refused", code: "EXTRA_STREAM", message: "x" } },
    { name: "missing-message", json: { type: "stream:refused", code: "INVALID" } },
    { name: "extra-field", json: { type: "stream:refused", code: "INVALID", message: "x", streamId: "1" } },
    { name: "wrong-type", json: { type: "stream-refused", code: "INVALID", message: "x" } },
  ].map((sample) => {
    if (StreamRefused.safeParse(sample.json).success) {
      throw new Error(`rejected refusal vector ${sample.name} parses`);
    }
    return sample;
  });

  return {
    maxOpenBytes: STREAM_OPEN_MAX_BYTES,
    maxIdLength: STREAM_OPEN_MAX_ID_LENGTH,
    caps: {
      maxBidiStreamsPerConnection: STREAM_MAX_BIDI_STREAMS_PER_CONNECTION,
      maxProjectsPerPeer: STREAM_MAX_PROJECTS_PER_PEER,
      maxTerminalAttachmentsPerPeer: STREAM_MAX_TERMINAL_ATTACHMENTS_PER_PEER,
      maxTunnelStreamsPerPeer: STREAM_MAX_TUNNEL_STREAMS_PER_PEER,
      maxPendingOpensPerPeer: STREAM_MAX_PENDING_OPENS_PER_PEER,
    },
    terminalRecords: {
      appMaxRecordBytes: STREAM_TERMINAL_APP_RECORD_MAX_BYTES,
      bridgeMaxRecordBytes: STREAM_TERMINAL_BRIDGE_RECORD_MAX_BYTES,
    },
    opens,
    refusals,
    rejectedOpens,
    rejectedRefusals,
  };
}

if (import.meta.main) {
  await Bun.write(
    new URL("../../../evals/fixtures/peer-transport-vectors.json", import.meta.url),
    JSON.stringify(buildPeerTransportVectors(), null, 2) + "\n",
  );
  console.log("wrote evals/fixtures/peer-transport-vectors.json");
}
