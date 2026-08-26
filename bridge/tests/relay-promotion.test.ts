// v3 desktop "enable mobile access" wizard. In v2
// relay-promotion.ts built its own RelayClient and reacted to its connection
// events (onAuthenticated/onPaired/onError). In v3 there is exactly
// ONE machine RelayClient, owned by HostServer — this controller just asks the
// host to bring it up (`ensureMachineRelay`), attaches the local core's bus as
// a stream (`attach`), and announces readiness. All the reconnect/auth/
// unpair reactivity that used to live here moved to HostServer's control-plane
// wiring and ProjectCore's attachRelayStream (see host-promotion.test.ts,
// project-core.test.ts).
import { expect, test } from "bun:test";
import { MessageBus } from "../src/message-bus";
import { createMessage, type AbMessage } from "../src/protocol";
import { createRelayPromotion, type MachineRelaySession, type LocalStreamAttachment } from "../src/relay-promotion";
import type { StreamHandle } from "../src/stream-mux";

const ENABLE = createMessage("agent:enableRelay", {
  relayUrl: "https://relay.example.com",
  auth: {
    deviceUuid: "0bbd1111-2222-3333-4444-555566667777",
    ed25519Pub: Buffer.from("edpub").toString("base64url"),
    ed25519Priv: Buffer.from("edpriv").toString("base64url"),
    licenseToken: "static-token",
  },
}) as Extract<AbMessage, { type: "agent:enableRelay" }>;

function makeMachineSession(overrides: Partial<MachineRelaySession> = {}): MachineRelaySession {
  return {
    attachStream: () => ({ streamId: "s1", detach: () => {}, sendTunnel: () => {} }),
    currentPeerPubkey: () => null,
    sendPushDeliver: () => {},
    agentDeviceId: "0bbd1111-2222-3333-4444-555566667777",
    ...overrides,
  };
}

/** Tracks ensureMachineRelay/attach call counts the same way the old suite
 *  tracked RelayClient construction — the seam moved, the intent (idempotent
 *  bring-up, exactly one attach per promotion) did not. */
function makeDeps(session: MachineRelaySession) {
  const calls = { ensureMachineRelay: 0, attach: 0, detach: 0 };
  const handle: StreamHandle = { streamId: "s1", detach: () => {}, sendTunnel: () => {} };
  return {
    calls,
    ensureMachineRelay: async (_msg: Extract<AbMessage, { type: "agent:enableRelay" }>) => {
      calls.ensureMachineRelay++;
      return session;
    },
    attach: (): LocalStreamAttachment => {
      calls.attach++;
      return { handle, detach: () => { calls.detach++; } };
    },
  };
}

test("enableRelay attaches the core as a stream and emits relayReady from the machine session", async () => {
  const bus = new MessageBus();
  const out: AbMessage[] = [];
  bus.setInboundHandler(() => {});
  const unsub = bus.subscribe({ deliver: (m) => out.push(m) });
  const session = makeMachineSession();
  const deps = makeDeps(session);
  const ctrl = createRelayPromotion({ bus, ...deps });

  expect(ctrl.handleInbound(ENABLE)).toBe(true);
  await Bun.sleep(10);

  expect(deps.calls.ensureMachineRelay).toBe(1);
  expect(deps.calls.attach).toBe(1);
  const ready = out.find((m) => m.type === "agent:relayReady");
  expect(ready).toBeDefined();
  // @ts-expect-error narrowed at runtime
  expect(ready.agentDeviceId).toBe(session.agentDeviceId);

  ctrl.stop();
  expect(deps.calls.detach).toBe(1);
  unsub();
});

test("a repeat enableRelay (already promoted) re-answers relayReady WITHOUT a second attach", async () => {
  const bus = new MessageBus();
  const out: AbMessage[] = [];
  bus.setInboundHandler(() => {});
  const unsub = bus.subscribe({ deliver: (m) => out.push(m) });
  const session = makeMachineSession();
  const deps = makeDeps(session);
  const ctrl = createRelayPromotion({ bus, ...deps });

  expect(ctrl.handleInbound(ENABLE)).toBe(true);
  await Bun.sleep(10);
  expect(out.filter((m) => m.type === "agent:relayReady").length).toBe(1);

  // Under account trust there is no pairing window to gate on — a repeat
  // enableRelay against the ALREADY-promoted session just re-answers.
  expect(ctrl.handleInbound(ENABLE)).toBe(true);
  await Bun.sleep(10);

  expect(out.filter((m) => m.type === "agent:relayReady").length).toBe(2);
  expect(deps.calls.ensureMachineRelay).toBe(1);
  expect(deps.calls.attach).toBe(1);
  ctrl.stop();
  unsub();
});

test("concurrent enableRelay calls coalesce onto a single in-flight bring-up", async () => {
  const bus = new MessageBus();
  bus.setInboundHandler(() => {});
  const deps = makeDeps(makeMachineSession());
  const ctrl = createRelayPromotion({ bus, ...deps });

  // Both calls land before the first `await ensureMachineRelay` resolves — the
  // `starting` guard must make the second an immediate no-op.
  expect(ctrl.handleInbound(ENABLE)).toBe(true);
  expect(ctrl.handleInbound(ENABLE)).toBe(true);
  await Bun.sleep(10);

  expect(deps.calls.ensureMachineRelay).toBe(1);
  expect(deps.calls.attach).toBe(1);
  ctrl.stop();
});

test("a disableRelay landing mid-start cancels the in-flight attach", async () => {
  const bus = new MessageBus();
  const out: AbMessage[] = [];
  bus.setInboundHandler(() => {});
  const unsub = bus.subscribe({ deliver: (m) => out.push(m) });
  let resolveEnsure!: (s: MachineRelaySession) => void;
  const gate = new Promise<MachineRelaySession>((res) => { resolveEnsure = res; });
  let ensureCalls = 0;
  let attachCalls = 0;
  const ctrl = createRelayPromotion({
    bus,
    ensureMachineRelay: async () => { ensureCalls++; return gate; },
    attach: () => { attachCalls++; return { handle: { streamId: "s1", detach: () => {}, sendTunnel: () => {} }, detach: () => {} }; },
  });

  expect(ctrl.handleInbound(ENABLE)).toBe(true); // start() begins, awaiting ensureMachineRelay
  ctrl.stop(); // disableRelay lands mid-start: bumps activeGen
  resolveEnsure(makeMachineSession()); // ensureMachineRelay now resolves, but the generation has moved on
  await Bun.sleep(10);

  expect(ensureCalls).toBe(1);
  expect(attachCalls).toBe(0); // the stale attempt never reaches attach()
  expect(out.find((m) => m.type === "agent:relayReady")).toBeUndefined();
  unsub();
});

test("ensureMachineRelay rejecting surfaces relayError(ENABLE_FAILED) and allows a later retry", async () => {
  const bus = new MessageBus();
  const out: AbMessage[] = [];
  bus.setInboundHandler(() => {});
  const unsub = bus.subscribe({ deliver: (m) => out.push(m) });
  let fail = true;
  let ensureCalls = 0;
  let attachCalls = 0;
  const ctrl = createRelayPromotion({
    bus,
    ensureMachineRelay: async () => {
      ensureCalls++;
      if (fail) throw new Error("boom: machine socket failed to start");
      return makeMachineSession();
    },
    attach: () => { attachCalls++; return { handle: { streamId: "s1", detach: () => {}, sendTunnel: () => {} }, detach: () => {} }; },
  });

  ctrl.handleInbound(ENABLE);
  await Bun.sleep(10);
  const err = out.find((m) => m.type === "agent:relayError");
  expect(err).toBeDefined();
  // @ts-expect-error narrowed at runtime
  expect(err.code).toBe("ENABLE_FAILED");
  expect(attachCalls).toBe(0);

  // A later successful enable must retry (state stayed torn down on failure).
  fail = false;
  ctrl.handleInbound(ENABLE);
  await Bun.sleep(10);
  expect(ensureCalls).toBe(2);
  expect(attachCalls).toBe(1);
  ctrl.stop();
  unsub();
});

test("enableRelay without any credentials emits relayError(NO_CREDENTIALS)", async () => {
  const bus = new MessageBus();
  const out: AbMessage[] = [];
  bus.setInboundHandler(() => {});
  const unsub = bus.subscribe({ deliver: (m) => out.push(m) });
  const deps = makeDeps(makeMachineSession());
  const ctrl = createRelayPromotion({ bus, ...deps });

  ctrl.handleInbound(createMessage("agent:enableRelay", {}) as any);
  await Bun.sleep(10);
  const err = out.find((m) => m.type === "agent:relayError");
  expect(err).toBeDefined();
  // @ts-expect-error narrowed at runtime
  expect(err.code).toBe("NO_CREDENTIALS");
  expect(deps.calls.ensureMachineRelay).toBe(0);
  ctrl.stop();
  unsub();
});

test("a malformed deviceUuid is rejected up front with INVALID_REQUEST, before ensureMachineRelay runs", async () => {
  const bus = new MessageBus();
  const out: AbMessage[] = [];
  bus.setInboundHandler(() => {});
  const unsub = bus.subscribe({ deliver: (m) => out.push(m) });
  const deps = makeDeps(makeMachineSession());
  const ctrl = createRelayPromotion({ bus, ...deps });

  ctrl.handleInbound(
    createMessage("agent:enableRelay", {
      auth: { deviceUuid: "not-a-uuid", ed25519Pub: "a", ed25519Priv: "b", licenseToken: "tok" },
    }) as any,
  );
  await Bun.sleep(10);
  const err = out.find((m) => m.type === "agent:relayError");
  expect(err).toBeDefined();
  // @ts-expect-error narrowed at runtime
  expect(err.code).toBe("INVALID_REQUEST");
  expect(deps.calls.ensureMachineRelay).toBe(0);
  ctrl.stop();
  unsub();
});

test("enableRelay on a bare agent (no host — ensureMachineRelay/attach absent) emits relayError(NO_HOST)", async () => {
  const bus = new MessageBus();
  const out: AbMessage[] = [];
  bus.setInboundHandler(() => {});
  const unsub = bus.subscribe({ deliver: (m) => out.push(m) });
  const ctrl = createRelayPromotion({ bus });

  ctrl.handleInbound(ENABLE);
  await Bun.sleep(10);
  const err = out.find((m) => m.type === "agent:relayError");
  expect(err).toBeDefined();
  // @ts-expect-error narrowed at runtime
  expect(err.code).toBe("NO_HOST");
  ctrl.stop();
  unsub();
});

test("stop() detaches the stream it attached (the machine socket itself is the host's concern, untouched here)", async () => {
  const bus = new MessageBus();
  bus.setInboundHandler(() => {});
  const deps = makeDeps(makeMachineSession());
  const ctrl = createRelayPromotion({ bus, ...deps });

  expect(ctrl.handleInbound(ENABLE)).toBe(true);
  await Bun.sleep(10);
  expect(deps.calls.detach).toBe(0);
  ctrl.stop();
  expect(deps.calls.detach).toBe(1);
  // Idempotent: a second stop() must not detach twice.
  ctrl.stop();
  expect(deps.calls.detach).toBe(1);
});

test("disableRelay before any enable is a no-op and is consumed", () => {
  const bus = new MessageBus();
  bus.setInboundHandler(() => {});
  const ctrl = createRelayPromotion({ bus, ...makeDeps(makeMachineSession()) });
  expect(ctrl.handleInbound(createMessage("agent:disableRelay", {}) as any)).toBe(true);
  ctrl.stop();
});

test("non-promotion messages are not consumed", () => {
  const bus = new MessageBus();
  bus.setInboundHandler(() => {});
  const ctrl = createRelayPromotion({ bus, ...makeDeps(makeMachineSession()) });
  expect(
    ctrl.handleInbound(
      createMessage("terminal:resize", { terminalId: "t", cols: 80, rows: 24, clientId: "test" }) as any,
    ),
  ).toBe(false);
  ctrl.stop();
});
