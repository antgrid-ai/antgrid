// bridge/src/e2e/index.ts
export { DOMAIN_V2, VERSION_BYTE, buildTranscript, type TranscriptFields } from "./transcript";
export { HKDF_INFO_V2, deriveSessionKeys, zeroizeSessionKeys, type SessionKeys } from "./key-schedule";
export { agentConfirmTag, phoneConfirmTag, verifyConfirmTag } from "./confirm";
export { E2eTransport } from "./transport";
export { signTranscript, verifyTranscriptSig } from "./handshake-sig";
