import { describe, it, expect } from "bun:test";
import { tmpdir } from "node:os";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createConnState } from "../src/conn-state";
import { TerminalManager } from "../src/terminal-manager";
import { FileWatcher } from "../src/file-watcher";
import { TunnelManager } from "../src/tunnel-manager";
import type { AbMessage } from "../src/protocol";

describe("pause-streams end-to-end", () => {
  it("paused agent emits zero heavy frames; snapshots reflect work; seq monotonic across resume", async () => {
    let emitted: AbMessage[] = [];
    const send = (m: AbMessage) => {
      emitted.push(m);
    };

    const root = mkdtempSync(join(tmpdir(), "antgrid-pause-"));
    writeFileSync(join(root, "a.txt"), "initial\n");

    const connState = createConnState();
    const tm = new TerminalManager(send, undefined, connState);
    const fw = new FileWatcher({ path: root, id: "p" }, send, connState);
    const tunnel = new TunnelManager({
      projectId: "p",
      portLabels: new Map(),
      previewPorts: new Set([3000]),
      sendTunnel: () => {},
      sendEncrypted: send,
      relayHost: "relay.test",
      connState,
    });

    fw.startWatching();
    await new Promise((r) => setTimeout(r, 100)); // let chokidar settle

    // Spawn before pause; let startup chatter flush so post-pause assertion
    // isn't fooled by stale shell-prompt output.
    const terminalId = tm.spawn({ terminalId: "t1", cols: 80, rows: 24, cwd: root });
    await new Promise((r) => setTimeout(r, 300));

    // Drain everything emitted before the pause window so heavy-frame count is clean.
    emitted = [];

    // === Pause window ===
    connState.appFocusPaused = true;
    tm.write(terminalId, "echo PAUSED_MARK\n");
    writeFileSync(join(root, "b.txt"), "added\n");
    tunnel.onPortsUpdate([{ port: 3000 }]);
    await new Promise((r) => setTimeout(r, 300));

    const heavyTypes = new Set(["terminal:output", "tree:update", "preview:url"]);
    const heavies = emitted.filter((m) => heavyTypes.has(m.type));
    expect(heavies).toHaveLength(0);

    // Snapshots should contain the work performed while paused.
    const termSnap = tm.getScrollback(terminalId);
    expect(termSnap).not.toBeNull();
    expect(termSnap!.seq).toBeGreaterThan(0);
    expect(termSnap!.text).toContain("PAUSED_MARK");

    const fileSnap = fw.getTreeSnapshot();
    expect(fileSnap.seq).toBeGreaterThan(0);
    const childNames = (fileSnap.tree.children ?? []).map((c) => c.name);
    expect(childNames).toContain("b.txt");

    const previewSnap = tunnel.getPreviewSnapshot();
    expect(previewSnap).toHaveLength(1);
    expect(previewSnap[0]!.port).toBe(3000);

    // === Resume window ===
    connState.appFocusPaused = false;
    emitted = [];
    tm.write(terminalId, "echo POST\n");
    await new Promise((r) => setTimeout(r, 300));

    const outs = emitted.filter(
      (m): m is Extract<AbMessage, { type: "terminal:output" }> =>
        m.type === "terminal:output",
    );
    expect(outs.length).toBeGreaterThanOrEqual(1);
    for (const o of outs) {
      expect(o.seq ?? 0).toBeGreaterThan(termSnap!.seq);
    }

    tm.kill(terminalId);
    fw.stop();
    tunnel.stop();
  }, 10000);
});
