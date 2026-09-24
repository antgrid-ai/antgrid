export {
  FRAME_VERSION,
  MAX_HEADER_LEN,
  FrameError,
  FrameKind,
  FIXED_PREFIX,
  encodePeerFrame,
  decodePeerFrame,
  type FrameErrorReason,
} from "./peer-frame";

export * from "./client-ip";
export * from "./relay-protocol";
export * from "./relay-auth";
export * from "./relay-slot";
export * from "./frag";
export * from "./flow";
export * from "./push-protocol";
export * from "./peer-authorization";
export * from "./peer-protocol";

// Named, not `export *`: MAX_TRANSFER_BYTES and PEER_MAX_RECORD_BYTES are
// re-exported from stream-open.ts too (their documented new home), and a
// star export would make those two names ambiguous against frag.ts /
// peer-authorization.ts above.
export {
  SessionStreamOpen,
  ProjectStreamOpen,
  TerminalStreamOpen,
  TunnelHttpStreamOpen,
  TunnelWsStreamOpen,
  StreamOpen,
  type StreamOpenKind,
  StreamRefusedCode,
  StreamRefused,
  encodeStreamOpen,
  decodeStreamOpen,
  encodeStreamRefused,
  decodeStreamRefused,
  STREAM_OPEN_MAX_BYTES,
  STREAM_OPEN_MAX_ID_LENGTH,
  STREAM_MAX_BIDI_STREAMS_PER_CONNECTION,
  STREAM_MAX_PROJECTS_PER_PEER,
  STREAM_MAX_TERMINAL_ATTACHMENTS_PER_PEER,
  STREAM_MAX_TUNNEL_STREAMS_PER_PEER,
  STREAM_MAX_PENDING_OPENS_PER_PEER,
} from "./stream-open";
