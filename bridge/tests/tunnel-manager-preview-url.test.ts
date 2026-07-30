import { test, expect } from "bun:test";
import { TunnelManager } from "../src/tunnel-manager";
import { createConnState } from "../src/conn-state";
import type { AbMessage, PortInfo } from "../src/protocol";

function makeManager(opts: { previewPorts?: number[]; relayHost?: string } = {}) {
  const sent: AbMessage[] = [];
  const connState = createConnState();
  const mgr = new TunnelManager({
    projectId: "proj",
    portLabels: new Map([[3000, "web"]]),
    previewPorts: new Set(opts.previewPorts ?? [3000]),
    sendTunnel: () => {},
    sendEncrypted: (msg) => sent.push(msg),
    relayHost: opts.relayHost ?? "relay.test",
    connState,
  });
  return { mgr, sent, connState };
}

function port(p: number, scheme?: "http" | "https"): PortInfo {
  return { port: p, ...(scheme ? { scheme } : {}) };
}

test("a first sighting pushes preview:url carrying the detected scheme", () => {
  const { mgr, sent } = makeManager();
  mgr.onPortsUpdate([port(3000, "https")]);
  expect(sent).toHaveLength(1);
  expect(sent[0]).toMatchObject({
    type: "preview:url",
    port: 3000,
    label: "web",
    scheme: "https",
    url: "http://relay.test/preview/3000/",
  });
});

test("scheme is omitted (not guessed) while the port has no sighting yet", () => {
  const { mgr, sent } = makeManager();
  mgr.onPortsUpdate([port(3000)]);
  expect(sent).toHaveLength(1);
  expect(sent[0]).not.toHaveProperty("scheme");
});

test("a later https sighting re-pushes preview:url, not just the snapshot", () => {
  // The URL sighting lands after the line-based port detection, so the entry
  // the phone holds goes stale. Re-push so the live push and the
  // welcome-replayed snapshot never disagree about the same port.
  const { mgr, sent } = makeManager();
  mgr.onPortsUpdate([port(3000)]);
  mgr.onPortsUpdate([port(3000, "https")]);
  expect(sent).toHaveLength(2);
  expect(sent[1]).toMatchObject({ type: "preview:url", port: 3000, scheme: "https" });
  expect(mgr.getPreviewSnapshot()).toEqual([
    { port: 3000, url: "http://relay.test/preview/3000/", label: "web", scheme: "https" },
  ]);
});

test("a label revealed later re-pushes the entry", () => {
  const { mgr, sent } = makeManager({ previewPorts: [5173] });
  mgr.onPortsUpdate([{ port: 5173 }]);
  mgr.onPortsUpdate([{ port: 5173, label: "vite" }]);
  expect(sent).toHaveLength(2);
  expect(sent[1]).toMatchObject({ port: 5173, label: "vite" });
});

test("an update with no sighting does not downgrade an already-known scheme", () => {
  const { mgr, sent } = makeManager();
  mgr.onPortsUpdate([port(3000, "https")]);
  mgr.onPortsUpdate([port(3000)]);
  expect(sent).toHaveLength(1);
  expect(mgr.getPreviewSnapshot()[0]).toMatchObject({ scheme: "https" });
});

test("an unchanged port does not re-push on every ports:update", () => {
  const { mgr, sent } = makeManager();
  mgr.onPortsUpdate([port(3000, "https")]);
  mgr.onPortsUpdate([port(3000, "https")]);
  mgr.onPortsUpdate([port(3000, "https")]);
  expect(sent).toHaveLength(1);
});

test("a non-preview port is never pushed", () => {
  const { mgr, sent } = makeManager({ previewPorts: [3000] });
  mgr.onPortsUpdate([port(5173, "https")]);
  expect(sent).toHaveLength(0);
  expect(mgr.getPreviewSnapshot()).toEqual([]);
});

test("a suppressed stream still records the entry for the welcome snapshot", () => {
  const { mgr, sent, connState } = makeManager();
  connState.peerOnline = false;
  mgr.onPortsUpdate([port(3000, "https")]);
  expect(sent).toHaveLength(0);
  expect(mgr.getPreviewSnapshot()).toHaveLength(1);
});

test("local mode (no relay host) sends nothing but still drops departed ports", () => {
  const { mgr, sent } = makeManager({ relayHost: "" });
  mgr.onPortsUpdate([port(3000, "https")]);
  expect(sent).toHaveLength(0);
  expect(mgr.getPreviewSnapshot()).toEqual([]);
});

test("a port that goes away is dropped from the snapshot and re-pushed on return", () => {
  const { mgr, sent } = makeManager();
  mgr.onPortsUpdate([port(3000, "http")]);
  mgr.onPortsUpdate([]);
  expect(mgr.getPreviewSnapshot()).toEqual([]);
  mgr.onPortsUpdate([port(3000, "http")]);
  expect(sent).toHaveLength(2);
});
