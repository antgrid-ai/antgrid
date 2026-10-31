import type { PeerSessionOwner } from "./peer-session-owner";
import type { BusClientMessage, BusServerMessage } from "antgrid-wire";
import type { CentralControlClient } from "./central-control-client";

/** What the session bus registers to ride the central socket. */
export interface BusHandler {
  onFrame(msg: BusServerMessage): void;
  onPresence(peerId: string, online: boolean): void;
  onAuthenticated(): void;
}

/** Host capabilities shared by native production connections and protocol fixtures. */
export interface RemoteHostConnection extends Pick<PeerSessionOwner,
  "deviceId" | "setBus" | "attachStream" | "establishedPeers" | "peerSession" |
  "hasEstablishedSession" | "sendOnChannel" |
  "send"> {
  connect(): void;
  close(): Promise<void>;
  redialWithFreshToken(): void;
  sendPushDeliver(message: Parameters<CentralControlClient["sendPushDeliver"]>[0]): void;
  accountDisowns(deviceId: string, ed25519Pub: string): boolean;
  noteResume(): Promise<boolean>;
  recheckAuthorization(): void;
  authorizeDevice?(deviceId: string): Promise<boolean>;
  sendBus?(frame: BusClientMessage): boolean;
  busLinkState?(): "ready" | "offline" | "unsupported";
  busNow?(): number;
  setBusHandler?(handler: BusHandler | null): void;
}
