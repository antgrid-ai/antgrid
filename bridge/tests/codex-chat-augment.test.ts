import { describe, expect, it } from "bun:test";
import { buildChatSpawnAugment, codexNotifyOnlyArgs } from "../src/agent-core";

describe("codex chat-mode augment", () => {
  it("slices out only the notify=[...] -c pair", () => {
    const sliced = codexNotifyOnlyArgs(
      buildChatSpawnAugment("codex", "slot-7", 8790).args,
    );
    expect(sliced.length).toBe(2);
    expect(sliced[0]).toBe("-c");
    expect(sliced[1]?.startsWith("notify=")).toBe(true);
  });

  it("drops every hooks.* arg (app-server's -c parser rejects them)", () => {
    const sliced = codexNotifyOnlyArgs(
      buildChatSpawnAugment("codex", "slot-7", 8790).args,
    );
    expect(sliced.some((a) => a.includes("hooks."))).toBe(false);
  });

  it("stamps the slot id into the correlation env", () => {
    expect(buildChatSpawnAugment("codex", "slot-7", 8790).env.ANTGRID_TERMINAL_ID).toBe("slot-7");
  });
});
