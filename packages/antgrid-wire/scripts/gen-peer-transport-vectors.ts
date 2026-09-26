// Generates the cross-language native peer transport pin.
// Run: cd packages/antgrid-wire && bun run gen:peer-vectors
import {
  ENDPOINT_CHALLENGE_MS,
  FIXED_PREFIX,
  FRAME_VERSION,
  FrameKind,
  MAX_TRANSFER_BYTES,
  MAX_HEADER_LEN,
  PEER_ALPN,
  PEER_IDENTITY_MAX_CHARS,
  PEER_LEASE_MS,
  PEER_MAX_AUTHORIZED_PEERS,
  PEER_MAX_GENERATION,
  PEER_MAX_RECORD_BYTES,
  PEER_MAX_BRIDGE_RECORD_BYTES,
  PEER_MAX_RELAY_URLS,
  PEER_REFRESH_MS,
  PEER_SELECTION_MS,
  STREAM_MAX_BIDI_STREAMS_PER_CONNECTION,
  STREAM_MAX_PENDING_OPENS_PER_PEER,
  STREAM_MAX_PROJECTS_PER_PEER,
  STREAM_MAX_TERMINAL_ATTACHMENTS_PER_PEER,
  STREAM_MAX_TUNNEL_STREAMS_PER_PEER,
  STREAM_MAX_UPLOAD_STREAMS_PER_PEER,
  STREAM_OPEN_MAX_BYTES,
  STREAM_OPEN_MAX_ID_LENGTH,
  STREAM_PROJECT_APP_RECORD_MAX_BYTES,
  STREAM_PROJECT_BRIDGE_RECORD_MAX_BYTES,
  STREAM_TERMINAL_APP_RECORD_MAX_BYTES,
  STREAM_TERMINAL_BRIDGE_RECORD_MAX_BYTES,
  STREAM_UPLOAD_BRIDGE_RECORD_MAX_BYTES,
  STREAM_UPLOAD_MAX_FILE_NAME_LENGTH,
  STREAM_UPLOAD_MAX_MIME_TYPE_LENGTH,
  STREAM_TUNNEL_DATA_MAX_BYTES,
  STREAM_TUNNEL_RECORD_MAX_BYTES,
  STREAM_TUNNEL_REQUEST_BODY_MAX_BYTES,
  TUNNEL_RECORD_TAG_WS_TEXT,
  TUNNEL_RECORD_TAG_WS_BINARY,
  StreamOpen,
  StreamRefused,
  encodePeerFrame,
} from "../src/index";

// The bridge's own `streamLabelOf` (`bridge/src/peer/stream-dispatch.ts`) is
// ELv2 and must not move into this Apache package, so the expected label per
// open kind is hand-restated here and pinned as a vector instead of imported.
function expectedLabel(open: StreamOpen): { kind: string; id: string } {
  switch (open.kind) {
    case "session": return { kind: open.kind, id: "0" };
    case "project": return { kind: open.kind, id: open.projectId };
    case "terminal": return { kind: open.kind, id: open.requestId };
    case "tunnel-http": return { kind: open.kind, id: open.requestId };
    case "tunnel-ws": return { kind: open.kind, id: open.wsId };
    case "upload": return { kind: open.kind, id: open.requestId };
  }
}

export function buildPeerTransportVectors() {
  const samples = [
    {
      name: "message",
      header: { type: "message" } as const,
      kind: FrameKind.message,
      payloadHex: "deadbeef",
    },
    {
      name: "session",
      header: { type: "session" } as const,
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
      maxPayloadBytes: MAX_TRANSFER_BYTES,
      maxRecordBytes: PEER_MAX_RECORD_BYTES,
      maxBridgeRecordBytes: PEER_MAX_BRIDGE_RECORD_BYTES,
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
    {
      name: "upload",
      json: { kind: "upload", projectId: "proj-1", requestId: "req-1", fileName: "notes.txt", size: 12 },
    },
    {
      name: "upload-with-checkout-and-mime",
      json: {
        kind: "upload",
        projectId: "proj-1",
        checkoutId: "chk-1",
        requestId: "req-1",
        fileName: "notes.txt",
        mimeType: "text/plain",
        size: 0,
      },
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
    { name: "upload-missing-size", json: { kind: "upload", projectId: "proj-1", requestId: "req-1", fileName: "a" } },
    { name: "upload-negative-size", json: { kind: "upload", projectId: "proj-1", requestId: "req-1", fileName: "a", size: -1 } },
    { name: "upload-fractional-size", json: { kind: "upload", projectId: "proj-1", requestId: "req-1", fileName: "a", size: 1.5 } },
    { name: "upload-string-size", json: { kind: "upload", projectId: "proj-1", requestId: "req-1", fileName: "a", size: "12" } },
    { name: "upload-empty-file-name", json: { kind: "upload", projectId: "proj-1", requestId: "req-1", fileName: "", size: 1 } },
    {
      name: "upload-overlong-file-name",
      json: { kind: "upload", projectId: "proj-1", requestId: "req-1", fileName: "a".repeat(256), size: 1 },
    },
    { name: "upload-null-mime", json: { kind: "upload", projectId: "proj-1", requestId: "req-1", fileName: "a", size: 1, mimeType: null } },
    { name: "upload-empty-checkout", json: { kind: "upload", projectId: "proj-1", checkoutId: "", requestId: "req-1", fileName: "a", size: 1 } },
    { name: "upload-extra-field", json: { kind: "upload", projectId: "proj-1", requestId: "req-1", fileName: "a", size: 1, uploadId: "u" } },
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

  // One label row per stream kind, generated from the SAME `opens` samples
  // above rather than hand-duplicated ids, so a changed sample id cannot drift
  // silently from what the label vector claims for it.
  const labelSampleByKind: Record<string, string> = {
    session: "session",
    project: "project",
    terminal: "terminal",
    "tunnel-http": "tunnel-http",
    "tunnel-ws": "tunnel-ws",
    upload: "upload",
  };
  const labels = Object.entries(labelSampleByKind).map(([kind, sampleName]) => {
    const sample = opens.find((o) => o.name === sampleName);
    if (!sample) throw new Error(`no open sample named ${sampleName} for label kind ${kind}`);
    const open = StreamOpen.parse(sample.json);
    const label = expectedLabel(open);
    return { name: kind, open: sample.json, streamKind: label.kind, streamId: label.id };
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
      maxUploadStreamsPerPeer: STREAM_MAX_UPLOAD_STREAMS_PER_PEER,
    },
    projectRecords: {
      appMaxRecordBytes: STREAM_PROJECT_APP_RECORD_MAX_BYTES,
      bridgeMaxRecordBytes: STREAM_PROJECT_BRIDGE_RECORD_MAX_BYTES,
      maxTransferBytes: MAX_TRANSFER_BYTES,
    },
    terminalRecords: {
      appMaxRecordBytes: STREAM_TERMINAL_APP_RECORD_MAX_BYTES,
      bridgeMaxRecordBytes: STREAM_TERMINAL_BRIDGE_RECORD_MAX_BYTES,
    },
    uploadRecords: {
      bridgeMaxRecordBytes: STREAM_UPLOAD_BRIDGE_RECORD_MAX_BYTES,
      maxFileNameLength: STREAM_UPLOAD_MAX_FILE_NAME_LENGTH,
      maxMimeTypeLength: STREAM_UPLOAD_MAX_MIME_TYPE_LENGTH,
    },
    tunnelRecords: {
      maxDataBytes: STREAM_TUNNEL_DATA_MAX_BYTES,
      maxRecordBytes: STREAM_TUNNEL_RECORD_MAX_BYTES,
      requestBodyMaxBytes: STREAM_TUNNEL_REQUEST_BODY_MAX_BYTES,
      tags: {
        wsText: TUNNEL_RECORD_TAG_WS_TEXT,
        wsBinary: TUNNEL_RECORD_TAG_WS_BINARY,
      },
    },
    opens,
    refusals,
    rejectedOpens,
    rejectedRefusals,
    labels,
  };
}

if (import.meta.main) {
  await Bun.write(
    new URL("../../../evals/fixtures/peer-transport-vectors.json", import.meta.url),
    JSON.stringify(buildPeerTransportVectors(), null, 2) + "\n",
  );
  console.log("wrote evals/fixtures/peer-transport-vectors.json");
}
