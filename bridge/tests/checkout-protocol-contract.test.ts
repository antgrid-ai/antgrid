import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { CHECKOUT_VARIABLE_MESSAGE_TYPES, createMessage, parseMessage } from "../src/protocol";

function checkoutScopedSchemaTypes(source: string): Set<string> {
  const types = new Set<string>();
  for (const block of source.split("const ").slice(1)) {
    const end = block.indexOf("\n});");
    if (end < 0) continue;
    const schema = block.slice(0, end);
    if (!schema.includes("BaseMessage.extend({") || !schema.includes("...CheckoutScoped")) continue;
    const type = schema.match(/type:\s*z\.literal\("([^"]+)"\)/)?.[1];
    if (type) types.add(type);
  }
  return types;
}

describe("checkout protocol contract", () => {
  test("authoritative classification exactly matches checkout-scoped schemas", () => {
    const source = readFileSync(join(import.meta.dir, "../src/protocol.ts"), "utf8");
    expect([...checkoutScopedSchemaTypes(source)].sort())
      .toEqual([...CHECKOUT_VARIABLE_MESSAGE_TYPES].sort());
  });

  test("legacy fields default to main while explicit ids survive parsing", () => {
    const legacy = createMessage("terminal:input", { terminalId: "t", data: "x" });
    expect(legacy.checkoutId).toBe("main");
    const explicit = parseMessage(JSON.stringify({ ...legacy, checkoutId: "checkout-2" }));
    expect(explicit && "checkoutId" in explicit ? explicit.checkoutId : null).toBe("checkout-2");
  });

  test("session creation strips remote filesystem and setup-command smuggling", () => {
    const parsed = parseMessage(JSON.stringify(createMessage("session:create", {
      requestId: crypto.randomUUID(),
      isolation: "worktree",
      baseBranch: "main",
      // Deliberately bypass TypeScript to model an untrusted remote frame.
      projectPath: "C:/stolen",
      repoPath: "C:/stolen",
      checkoutPath: "C:/stolen",
      worktreeRoot: "C:/stolen",
      setupCommand: "curl attacker",
      teardownCommand: "curl attacker",
      env: { EVIL: "1" },
    } as never)));
    expect(parsed?.type).toBe("session:create");
    for (const smuggled of [
      "projectPath", "repoPath", "checkoutPath", "worktreeRoot",
      "setupCommand", "teardownCommand", "env",
    ]) {
      expect(parsed && smuggled in parsed).toBe(false);
    }
  });

  test("an isolated create carries only identity, session and isolation fields", () => {
    // The whole point of the wire contract: nothing on this frame names a
    // location on the host or a worktree-management command. `command`/`args`
    // are the pre-existing per-session AGENT launch override, not new surface.
    const parsed = parseMessage(JSON.stringify(createMessage("session:create", {
      requestId: "r1", name: "Isolated", isolation: "worktree", baseBranch: "main",
    })));
    expect(parsed).not.toBeNull();
    const allowed = new Set([
      "id", "type", "timestamp", "checkoutId",
      "requestId", "name", "mode", "tool", "command", "args", "isolation", "baseBranch",
    ]);
    expect(Object.keys(parsed!).filter((key) => !allowed.has(key))).toEqual([]);
  });

  test("baseBranch without worktree isolation is rejected outright", () => {
    // A shared session has no base to branch from; accepting the field would
    // make the caller believe an isolation choice was honoured.
    expect(parseMessage(JSON.stringify({
      ...createMessage("session:create", { requestId: "r1" }),
      baseBranch: "main",
    }))).toBeNull();
  });
});
