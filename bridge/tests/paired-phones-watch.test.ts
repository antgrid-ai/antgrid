import { describe, it, expect } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadPairedPhones } from "../src/paired-phones";

describe("paired-phones live reload", () => {
  it("reflects an external allow within the watch window", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-watch-"));
    const host = loadPairedPhones(dir);
    host.upsert({
      phonePubkey: "pk1", phoneDeviceId: "d1",
      pairedAt: "x", lastSeenAt: "x", admission: "pair-code", allowedProjects: [],
    });
    let fired = 0;
    const stop = host.watch(() => { fired++; });

    // simulate the CLI process mutating the same file
    const cli = loadPairedPhones(dir);
    cli.allowProject("pk1", "projA");

    await new Promise((r) => setTimeout(r, 150));
    expect(fired).toBeGreaterThan(0);
    expect(host.isAllowed("pk1", "projA")).toBe(true);

    stop();
    rmSync(dir, { recursive: true });
  });
});
