import { describe, it, expect } from "bun:test";
import { tmpdir } from "node:os";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createConnState } from "../src/conn-state";
import { TerminalManager } from "../src/terminal-manager";
import { FileWatcher } from "../src/file-watcher";
import { TunnelManager } from "../src/tunnel-manager";
import type { AbMessage } from "../src/protocol";

// A real PTY's latency is not a constant: Git Bash on Windows takes anywhere
// from ~200ms to ~350ms to echo a write, so every fixed sleep here straddled the
// distribution and failed ~25% of runs. Poll the thing being asserted instead.
async function waitFor(what: string, ready: () => boolean, timeoutMs = 8000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (ready()) return;
    await new Promise((r) => setTimeout(r, 20));
  }
  throw new Error(`timed out after ${timeoutMs}ms waiting for ${what}`);
}

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
    // chokidar attaches asynchronously and `ignoreInitial` suppresses whatever
    // is already on disk when its initial walk runs — so a lone warmup write
    // races INTO that set and is never reported. Keep writing fresh probes until
    // one lands after the walk and bumps the seq; that is the only proof the
    // watcher is live. b.txt written before this point would vanish the same
    // way, and `getTreeSnapshot` rebuilds from disk, so the tree would still
    // show it and only the seq would betray the loss.
    for (let probe = 0; fw.getTreeSnapshot().seq === 0; probe++) {
      if (probe > 100) throw new Error("file watcher never went live");
      writeFileSync(join(root, `warmup-${probe}.txt`), "warmup\n");
      await new Promise((r) => setTimeout(r, 50));
    }
    // Drain the warmup batch, so a late flush of it can't later be mistaken for
    // the watcher having seen b.txt.
    let settled = fw.getTreeSnapshot().seq;
    for (;;) {
      await new Promise((r) => setTimeout(r, 200));
      const now = fw.getTreeSnapshot().seq;
      if (now === settled) break;
      settled = now;
    }
    const seqBeforePause = settled;

    // Spawn before pause, then round-trip a marker: the shell is only proven
    // interactive once it echoes one, and startup chatter has flushed by then so
    // the post-pause assertion isn't fooled by stale shell-prompt output.
    const terminalId = tm.spawn({ terminalId: "t1", cols: 80, rows: 24, cwd: root });
    tm.write(terminalId, "echo READY_MARK\n");
    await waitFor("the shell to become interactive", () =>
      (tm.getScrollback(terminalId)?.text ?? "").includes("READY_MARK"),
    );

    // Drain everything emitted before the pause window so heavy-frame count is clean.
    emitted = [];
    const termSeqBeforePause = tm.getScrollback(terminalId)?.seq ?? 0;

    // === Pause window ===
    connState.appFocusPaused = true;
    tm.write(terminalId, "echo PAUSED_MARK\n");
    writeFileSync(join(root, "b.txt"), "added\n");
    tunnel.onPortsUpdate([{ port: 3000 }]);

    // Wait for the paused work to MATERIALIZE in the snapshots before asserting
    // that nothing was emitted — a shell that hadn't run the echo yet would
    // satisfy the zero-heavy-frame count without the gate ever being exercised.
    await waitFor("the paused write to reach the scrollback", () =>
      (tm.getScrollback(terminalId)?.text ?? "").includes("PAUSED_MARK"),
    );
    await waitFor("the paused file write to reach the watcher", () =>
      fw.getTreeSnapshot().seq > seqBeforePause,
    );

    const heavyTypes = new Set(["terminal:output", "tree:update", "preview:url"]);
    const heavies = emitted.filter((m) => heavyTypes.has(m.type));
    expect(heavies).toHaveLength(0);

    // Snapshots should contain the work performed while paused.
    const termSnap = tm.getScrollback(terminalId);
    expect(termSnap).not.toBeNull();
    // Advanced *during* the pause, not merely non-zero: a suppressed emitter
    // still has to bump seq or the next snapshot carries a stale cutoff and the
    // app silently re-requests output it already has.
    expect(termSnap!.seq).toBeGreaterThan(termSeqBeforePause);
    expect(termSnap!.text).toContain("PAUSED_MARK");

    // The seq is the load-bearing half: `tree` is rebuilt from disk on every
    // call, so it would show b.txt even if the watcher had missed the write.
    const fileSnap = fw.getTreeSnapshot();
    expect(fileSnap.seq).toBeGreaterThan(seqBeforePause);
    const childNames = (fileSnap.tree.children ?? []).map((c) => c.name);
    expect(childNames).toContain("b.txt");

    const previewSnap = tunnel.getPreviewSnapshot();
    expect(previewSnap).toHaveLength(1);
    expect(previewSnap[0]!.port).toBe(3000);

    // === Resume window ===
    connState.appFocusPaused = false;
    emitted = [];
    tm.write(terminalId, "echo POST\n");
    await waitFor("a resumed terminal:output frame", () =>
      emitted.some((m) => m.type === "terminal:output"),
    );

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
  }, 30000);
});
