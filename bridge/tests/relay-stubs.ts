// The relay-facing seams a ProjectCore is built on, stubbed: one established app
// session, the host deps behind a stream, and the machine session the desktop
// wizard attaches to. Shared for the reason `fake-session.ts` states — these
// shapes are wide and every field is required, so a per-file copy compiles until
// the interface gains a member and then goes stale in whichever file nobody
// remembered. A caller that cares about one field passes it as an override and
// inherits the rest.

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

/** `attachStream` captures the bus + opts it was called with instead of
 *  reaching a live machine socket — the seam v3 uses in place of the deleted
 *  per-core `makeRelayClient`/RelayClientOptions hook. */
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

/** The host's half of the wizard promotion path. Same surface as
 *  {@link fakeRemoteDeps}'s deps but for `agentDeviceId`, which is where the
 *  two interfaces disagree on naming this machine. */
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
