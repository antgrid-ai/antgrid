import { describe, it, expect } from "bun:test";
import { PortDetector } from "../src/port-detector";
import type { PortInfo } from "../src/protocol";

const makeProject = (proxies?: { name: string; port: number; browser?: boolean }[]) => ({
  ports: proxies?.map((p) => ({ port: p.port, name: p.name })),
});

describe("PortDetector", () => {
  it("detects http://localhost:PORT", () => {
    const detected: PortInfo[][] = [];
    const pd = new PortDetector(makeProject());
    pd.onPortsChange = (ports) => detected.push(ports);

    pd.feed("t1", "Server ready at http://localhost:3000\n");

    expect(detected.length).toBe(1);
    expect(detected[0]).toEqual([{ port: 3000 }]);
  });

  it("detects http://127.0.0.1:PORT", () => {
    const detected: PortInfo[][] = [];
    const pd = new PortDetector(makeProject());
    pd.onPortsChange = (ports) => detected.push(ports);

    pd.feed("t1", "Listening on http://127.0.0.1:8080/\n");

    expect(detected.length).toBe(1);
    expect(detected[0][0].port).toBe(8080);
  });

  it("detects http://0.0.0.0:PORT", () => {
    const detected: PortInfo[][] = [];
    const pd = new PortDetector(makeProject());
    pd.onPortsChange = (ports) => detected.push(ports);

    pd.feed("t1", "http://0.0.0.0:5173\n");

    expect(detected.length).toBe(1);
    expect(detected[0][0].port).toBe(5173);
  });

  it("detects 'listening on port NNNN'", () => {
    const detected: PortInfo[][] = [];
    const pd = new PortDetector(makeProject());
    pd.onPortsChange = (ports) => detected.push(ports);

    pd.feed("t1", "Listening on port 4000\n");

    expect(detected.length).toBe(1);
    expect(detected[0][0].port).toBe(4000);
  });

  it("detects 'started on :NNNN'", () => {
    const detected: PortInfo[][] = [];
    const pd = new PortDetector(makeProject());
    pd.onPortsChange = (ports) => detected.push(ports);

    pd.feed("t1", "Server started on :5173\n");

    expect(detected.length).toBe(1);
    expect(detected[0][0].port).toBe(5173);
  });

  it("detects 'running on :NNNN'", () => {
    const detected: PortInfo[][] = [];
    const pd = new PortDetector(makeProject());
    pd.onPortsChange = (ports) => detected.push(ports);

    pd.feed("t1", "App running on :9000\n");

    expect(detected.length).toBe(1);
    expect(detected[0][0].port).toBe(9000);
  });

  it("detects general :NNNN pattern", () => {
    const detected: PortInfo[][] = [];
    const pd = new PortDetector(makeProject());
    pd.onPortsChange = (ports) => detected.push(ports);

    pd.feed("t1", "  ➜ Local: :3000\n");

    expect(detected.length).toBe(1);
    expect(detected[0][0].port).toBe(3000);
  });

  it("ignores file:line references (ghost ports)", () => {
    const detected: PortInfo[][] = [];
    const pd = new PortDetector(makeProject());
    pd.onPortsChange = (ports) => detected.push(ports);

    pd.feed("t1", "  at doWork (agent-core.ts:1091)\n");
    pd.feed("t1", "webpack compiled bundle.js:10234 in 3s\n");
    pd.feed("t1", "error in preview_screen.dart:2648\n");

    expect(detected.length).toBe(0);
  });

  it("ignores file:line references even when the path contains a hint word", () => {
    const detected: PortInfo[][] = [];
    const pd = new PortDetector(makeProject());
    pd.onPortsChange = (ports) => detected.push(ports);

    // "host", "local", "serv" all pass SERVING_HINT — the `<name>.<ext>:<line>`
    // shape itself must be rejected.
    pd.feed("t1", "  at handleHello (host-server.ts:1091)\n");
    pd.feed("t1", "  at fetchLocalhost (localhost-fetch.ts:2345)\n");
    pd.feed("t1", "error in http-client.js:4242\n");

    expect(detected.length).toBe(0);
  });

  it("still detects a bare IP:port serving announcement (digit after dot is not an extension)", () => {
    const detected: PortInfo[][] = [];
    const pd = new PortDetector(makeProject());
    pd.onPortsChange = (ports) => detected.push(ports);

    pd.feed("t1", "Listening on 127.0.0.1:8080\n");

    expect(detected.length).toBe(1);
    expect(detected[0][0].port).toBe(8080);
  });

  it("still detects schemeless host:port serving announcements", () => {
    const detected: PortInfo[][] = [];
    const pd = new PortDetector(makeProject());
    pd.onPortsChange = (ports) => detected.push(ports);

    pd.feed("t1", "Listening on localhost:3000\n");

    expect(detected.length).toBe(1);
    expect(detected[0][0].port).toBe(3000);
  });

  it("ignores ports outside 1024-65535", () => {
    const detected: PortInfo[][] = [];
    const pd = new PortDetector(makeProject());
    pd.onPortsChange = (ports) => detected.push(ports);

    pd.feed("t1", "http://localhost:80\n");
    pd.feed("t1", "http://localhost:22\n");

    expect(detected.length).toBe(0);
  });

  it("handles split chunks via line buffering", () => {
    const detected: PortInfo[][] = [];
    const pd = new PortDetector(makeProject());
    pd.onPortsChange = (ports) => detected.push(ports);

    pd.feed("t1", "Server ready at http://local");
    expect(detected.length).toBe(0);

    pd.feed("t1", "host:3000\n");
    expect(detected.length).toBe(1);
    expect(detected[0][0].port).toBe(3000);
  });

  it("does not fire onPortsChange for duplicate port on same terminal", () => {
    const detected: PortInfo[][] = [];
    const pd = new PortDetector(makeProject());
    pd.onPortsChange = (ports) => detected.push(ports);

    pd.feed("t1", "http://localhost:3000\n");
    pd.feed("t1", "http://localhost:3000\n");

    expect(detected.length).toBe(1);
  });

  it("removes non-configured ports on terminal exit", () => {
    const detected: PortInfo[][] = [];
    const pd = new PortDetector(makeProject());
    pd.onPortsChange = (ports) => detected.push(ports);

    pd.feed("t1", "http://localhost:3000\n");
    expect(detected.length).toBe(1);

    pd.removeTerminal("t1");
    expect(detected.length).toBe(2);
    expect(detected[1]).toEqual([]);
  });

  it("keeps configured proxy ports on terminal exit", () => {
    const detected: PortInfo[][] = [];
    const pd = new PortDetector(makeProject([{ name: "app", port: 3000 }]));
    pd.onPortsChange = (ports) => detected.push(ports);

    pd.feed("t1", "http://localhost:3000\n");
    pd.removeTerminal("t1");

    const lastPorts = detected[detected.length - 1];
    expect(lastPorts.some((p) => p.port === 3000)).toBe(true);
  });

  it("applies labels from configured proxies", () => {
    const detected: PortInfo[][] = [];
    const pd = new PortDetector(makeProject([{ name: "Frontend", port: 3000 }]));
    pd.onPortsChange = (ports) => detected.push(ports);

    pd.feed("t1", "http://localhost:3000\n");

    expect(detected[0][0].label).toBe("Frontend");
  });

  it("tracks same port from multiple terminals", () => {
    const detected: PortInfo[][] = [];
    const pd = new PortDetector(makeProject());
    pd.onPortsChange = (ports) => detected.push(ports);

    pd.feed("t1", "http://localhost:3000\n");
    pd.feed("t2", "http://localhost:3000\n");

    // Remove first terminal — port should stay (t2 still owns it)
    pd.removeTerminal("t1");
    const afterT1 = detected[detected.length - 1];
    expect(afterT1.some((p) => p.port === 3000)).toBe(true);

    // Remove second terminal — port should go
    pd.removeTerminal("t2");
    const afterT2 = detected[detected.length - 1];
    expect(afterT2.some((p) => p.port === 3000)).toBe(false);
  });

  it("includes configured ports even without terminal output", () => {
    const pd = new PortDetector(makeProject([{ name: "api", port: 8080 }]));
    expect(pd.getConfiguredPorts()).toEqual(new Set([8080]));
  });
});

describe("PortDetector output source", () => {
  it("accepts URLs from terminal output and emits port:detected with source=output", async () => {
    const detector = new PortDetector(makeProject());
    const events: any[] = [];
    detector.onDetection((e) => events.push(e));
    detector.observeOutput("term-1", "Local: http://127.0.0.1:3000/dashboard\n");
    expect(events.length).toBe(1);
    expect(events[0]).toMatchObject({
      port: 3000,
      url: "http://localhost:3000/dashboard",
      scheme: "http",
      source: "output",
      sourceSessionId: "term-1",
    });
  });

  it("deduplicates identical URLs within a short window", () => {
    const detector = new PortDetector(makeProject());
    const events: any[] = [];
    detector.onDetection((e) => events.push(e));
    detector.observeOutput("term-1", "Local: http://localhost:3000/\n");
    detector.observeOutput("term-1", "Local: http://localhost:3000/\n");
    expect(events.length).toBe(1);
  });

  it("re-emits when path or scheme changes on the same port", () => {
    const detector = new PortDetector(makeProject());
    const events: any[] = [];
    detector.onDetection((e) => events.push(e));
    detector.observeOutput("t", "http://localhost:3000/a");
    detector.observeOutput("t", "http://localhost:3000/b");
    expect(events.length).toBe(2);
  });

  it("attaches detected scheme to ports:update entries", () => {
    const detected: PortInfo[][] = [];
    const pd = new PortDetector(makeProject());
    pd.onPortsChange = (ports) => detected.push(ports);

    // Line-based feed advertises the port first, scheme unknown.
    pd.feed("t1", "Server started on :3000\n");
    expect(detected[0]).toEqual([{ port: 3000 }]);

    // URL sighting reveals https — the port list must be re-emitted with it.
    pd.observeOutput("t1", "Local: https://localhost:3000/\n");
    expect(detected.length).toBe(2);
    expect(detected[1]).toEqual([{ port: 3000, scheme: "https" }]);
  });

  it("emitCurrent re-emits the current list unconditionally (reconnect resync)", () => {
    const detected: PortInfo[][] = [];
    const pd = new PortDetector(makeProject());
    pd.onPortsChange = (ports) => detected.push(ports);

    pd.feed("t1", "https://localhost:3000\n");
    pd.observeOutput("t1", "https://localhost:3000/\n");
    const before = detected.length;

    pd.emitCurrent();
    expect(detected.length).toBe(before + 1);
    expect(detected[detected.length - 1]).toEqual([{ port: 3000, scheme: "https" }]);
  });

  it("does not re-emit ports for a sighting of an unadvertised port", () => {
    const detected: PortInfo[][] = [];
    const pd = new PortDetector(makeProject());
    pd.onPortsChange = (ports) => detected.push(ports);

    // Port 9999 was never fed nor configured — it isn't in the advertised
    // list, so the sighting must not push an identical ports:update.
    pd.observeOutput("t1", "see https://localhost:9999/docs");

    expect(detected.length).toBe(0);
  });

  it("does not re-emit ports when a sighting only changes the path", () => {
    const detected: PortInfo[][] = [];
    const pd = new PortDetector(makeProject());
    pd.onPortsChange = (ports) => detected.push(ports);

    pd.feed("t1", "http://localhost:3000\n");
    pd.observeOutput("t1", "http://localhost:3000/a");
    const after = detected.length;
    pd.observeOutput("t1", "http://localhost:3000/b");
    expect(detected.length).toBe(after);
  });
});
