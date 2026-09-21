// The relay-facing seams a ProjectCore is built on, stubbed. Shared for the
// reason `fake-session.ts` states: these shapes are wide, so a per-file copy
// goes stale in whichever file nobody remembered to update.

import type { MessageBus } from "../src/message-bus";
import type { ProjectCoreRemoteDeps } from "../src/project-core";
import type { MachineRelaySession } from "../src/relay-promotion";
import type { AttachStreamOpts, PeerSessionView, StreamHandle } from "../src/stream-mux";

/** Bare machine deviceUuid, in the shape `AgentEnableRelayAuth` demands. */
export const MACHINE_UUID = "0bbd1111-2222-3333-4444-555566667777";

/** One established app session, as the relay transport would report it. */
export function peerView(over: Partial<PeerSessionView> = {}): PeerSessionView {
  return {
    peerId: "app-dev#machine-dev",
    peerPubkey: "pub",
    checkoutRouting: true,
    reachable: true,
    pullsTree: true,
    ...over,
  };
}

/** A stream that accepts everything. Override `sendTo` to record what left. */
export function fakeStreamHandle(over: Partial<StreamHandle> = {}): StreamHandle {
  return {
    streamId: "stream-1",
    detach: () => {},
    sendTunnel: async () => "sent" as const,
    sendTo: async () => "sent" as const,
    ...over,
  };
}

/** `attachStream` captures the bus + opts instead of reaching a live machine
 *  socket — the seam v3 uses in place of the deleted `makeRelayClient` hook. */
export function fakeRemoteDeps(over: Partial<ProjectCoreRemoteDeps> = {}): {
  deps: ProjectCoreRemoteDeps;
  calls: Array<{ bus: MessageBus; opts: AttachStreamOpts }>;
} {
  const calls: Array<{ bus: MessageBus; opts: AttachStreamOpts }> = [];
  return {
    deps: {
      attachStream: (bus, opts) => {
        calls.push({ bus, opts });
        return fakeStreamHandle();
      },
      establishedPeers: () => [],
      peerSession: () => null,
      machineDeviceId: () => MACHINE_UUID,
      sendPushDeliver: () => {},
      ...over,
    },
    calls,
  };
}

/** The host's half of the wizard promotion path — {@link fakeRemoteDeps}'s
 *  surface but for `agentDeviceId`, where the two interfaces disagree. */
export function fakeMachineSession(over: Partial<MachineRelaySession> = {}): MachineRelaySession {
  return {
    attachStream: () => fakeStreamHandle(),
    establishedPeers: () => [],
    peerSession: () => null,
    sendPushDeliver: () => {},
    agentDeviceId: MACHINE_UUID,
    ...over,
  };
}
