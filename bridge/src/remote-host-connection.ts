import type { PeerSessionOwner } from "./peer-session-owner";
import type { CentralControlClient } from "./central-control-client";

/** Host capabilities shared by native production connections and protocol fixtures. */
export interface RemoteHostConnection extends Pick<PeerSessionOwner,
  "deviceId" | "setBus" | "attachStream" | "establishedPeers" | "peerSession" |
  "hasEstablishedSession" | "anySessionSupportsCheckoutRouting" | "sendOnChannel" |
  "noteStreamBound" | "send"> {
  connect(): void;
  close(): Promise<void>;
  redialWithFreshToken(): void;
  sendPushDeliver(message: Parameters<CentralControlClient["sendPushDeliver"]>[0]): void;
  noteResume(): Promise<boolean>;
  recheckAuthorization(): void;
}
