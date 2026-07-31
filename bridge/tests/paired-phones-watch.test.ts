import { describe, it, expect } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadPairedPhones } from "../src/paired-phones";

describe("paired-phones live reload", () => {
  it("reflects an external phone removal within the watch window", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-watch-"));
    const host = loadPairedPhones(dir);
    host.upsert({
      phonePubkey: "pk1", phoneDeviceId: "d1",
      pairedAt: "x", lastSeenAt: "x", label: "pixel",
    });
    let fired = 0;
    const stop = host.watch(() => { fired++; });

    // simulate `antgrid phones remove` in another process mutating the same file
    const cli = loadPairedPhones(dir);
    cli.remove("pk1");

    await new Promise((r) => setTimeout(r, 150));
    expect(fired).toBeGreaterThan(0);
    // The running host must drop the row from ITS memory too — push targeting
    // and phones:list read that in-memory view live.
    expect(host.has("pk1")).toBe(false);

    stop();
    rmSync(dir, { recursive: true });
  });
});
