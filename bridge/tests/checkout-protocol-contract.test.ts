import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { CHECKOUT_VARIABLE_MESSAGE_TYPES, createMessage, parseMessage } from "../src/protocol";

/** The text of one top-level `const NAME = ...;` declaration, so a registration
 *  assertion pins the block it means rather than any later occurrence. */
function sourceBlock(source: string, declaration: string): string {
  const start = source.indexOf(declaration);
  if (start < 0) throw new Error(`no declaration ${declaration}`);
  const end = source.indexOf("\n]);", start);
  if (end < 0) throw new Error(`unterminated declaration ${declaration}`);
  return source.slice(start, end);
}

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

  test("session:setup is deliberately NOT checkout-variable", () => {
    // Do not "fix" this by adding it to the set. Every `session:*` verb routes
    // by sessionId on the project stream and the bridge resolves the checkout
    // from the session entry, so a checkoutId on this frame would be a second,
    // conflicting answer to a question already settled bridge-side. The only
    // `session:*` member of the set is `session:result`, which carries the
    // checkout back OUT.
    expect([...CHECKOUT_VARIABLE_MESSAGE_TYPES]).not.toContain("session:setup");
    expect([...CHECKOUT_VARIABLE_MESSAGE_TYPES].filter((type) => type.startsWith("session:")))
      .toEqual(["session:result"]);
  });

  test("session:setup is wired at all five registration points", () => {
    // Miss one and the type silently fails: it parses but nothing answers, or it
    // answers but never parses. The list is the checklist in CLAUDE.md.
    const protocol = readFileSync(join(import.meta.dir, "../src/protocol.ts"), "utf8");
    // 1. the schema, 2. the AbMessageSchema union, 3. the export.
    expect(protocol).toContain('type: z.literal("session:setup")');
    expect(sourceBlock(protocol, "export const AbMessageSchema")).toContain("SessionSetupMessage,");
    expect(protocol).toContain("export type SessionSetup =");

    // 5. the handler. CLAUDE.md still calls it "the index.ts switch"; the inbound
    // switch itself now lives in agent-core.ts.
    const core = readFileSync(join(import.meta.dir, "../src/agent-core.ts"), "utf8");
    expect(core).toContain('case "session:setup"');

    // 4. KNOWN_TYPES and the union, proven by behaviour rather than by grep:
    // parseMessage refuses a type either one has not heard of.
    const parsed = parseMessage(JSON.stringify(createMessage("session:setup", {
      requestId: "r1", sessionId: "s1", action: "skip",
    })));
    expect(parsed).toMatchObject({ type: "session:setup", sessionId: "s1", action: "skip" });
  });

  test("session:setup accepts only the three actions the bridge implements", () => {
    for (const action of ["skip", "cancel", "rerun"]) {
      expect(parseMessage(JSON.stringify({
        ...createMessage("session:setup", { requestId: "r1", sessionId: "s1", action: "skip" }),
        action,
      }))).not.toBeNull();
    }
    expect(parseMessage(JSON.stringify({
      ...createMessage("session:setup", { requestId: "r1", sessionId: "s1", action: "skip" }),
      action: "start",
    }))).toBeNull();
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
