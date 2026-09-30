// The peer-facing seams a ProjectCore is built on, stubbed. Shared for the
// reason `fake-session.ts` states: these shapes are wide, so a per-file copy
// goes stale in whichever file nobody remembered to update.

import type { MessageBus } from "../src/message-bus";
import type { ProjectCoreRemoteDeps } from "../src/project-core";
import type { AttachStreamOpts, PeerSessionView, StreamHandle } from "../src/project-streams";

/** Bare machine deviceUuid, the id the host registers under. */
export const MACHINE_UUID = "0bbd1111-2222-3333-4444-555566667777";

/** One established app session, as the native transport would report it. */
export function peerView(over: Partial<PeerSessionView> = {}): PeerSessionView {
  return {
    peerId: "app-dev#machine-dev",
    peerPubkey: "pub",
    ...over,
  };
}

/** A stream that accepts everything. Override `sendTo` to record what left. */
export function fakeStreamHandle(over: Partial<StreamHandle> = {}): StreamHandle {
  return {
    detach: () => {},
    sendTo: async () => "sent" as const,
    deliverableTo: () => true,
    ...over,
  };
}

/** `attachStream` captures the bus + opts instead of reaching a live peer
 *  transport. */
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
