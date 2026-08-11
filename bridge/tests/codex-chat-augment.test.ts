import { describe, expect, it } from "bun:test";
import { buildChatSpawnAugment } from "../src/agent-core";
import { codexNotifyOnlyArgs, codexUnifiedExecArgs } from "../src/agents/codex/driver";

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

  it("forces unified exec on (codex defaults it OFF on Windows; background terminals need it)", () => {
    expect(codexUnifiedExecArgs()).toEqual(["-c", "experimental_use_unified_exec_tool=true"]);
  });
});
