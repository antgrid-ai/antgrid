import { describe, expect, it } from "bun:test";
import { createAgentRegistry } from "../src/agents/create-registry";

describe("trusted agent registry", () => {
  it("registers definitions and keeps hook aliases in their own namespace", () => {
    const spec = { hookName: "hook-name", label: "Example" };
    const registry = createAgentRegistry([["agent-id", spec]]);
    expect(registry.get("agent-id")).toBe(spec);
    expect(registry.byHookName["hook-name"]).toBe("agent-id");
    expect(registry.get("hook-name")).toBeUndefined();
    expect(Object.isFrozen(registry.agents)).toBe(true);
    expect(Object.isFrozen(registry.byHookName)).toBe(true);
  });

  it("rejects duplicate ids before one definition can replace another", () => {
    expect(() => createAgentRegistry([
      ["same", { hookName: null }], ["same", { hookName: "other" }],
    ])).toThrow("Duplicate agent id: same");
  });

  it("rejects ambiguous hook dispatch", () => {
    expect(() => createAgentRegistry([
      ["first", { hookName: "same" }], ["second", { hookName: "same" }],
    ])).toThrow("Duplicate agent hook alias: same");
  });

  it("allows several integrations without hook aliases", () => {
    const registry = createAgentRegistry([
      ["first", { hookName: null }], ["second", { hookName: null }],
    ]);
    expect(Object.keys(registry.agents)).toEqual(["first", "second"]);
    expect(Object.keys(registry.byHookName)).toEqual([]);
  });

  it("never resolves inherited properties as installed agents or hook aliases", () => {
    const registry = createAgentRegistry([["agent", { hookName: "hook" }]]);
    expect(registry.get("constructor")).toBeUndefined();
    expect(registry.get("__proto__")).toBeUndefined();
    expect(registry.byHookName["constructor"]).toBeUndefined();
    expect(registry.byHookName["__proto__"]).toBeUndefined();
  });

  it("rejects empty ids and aliases", () => {
    expect(() => createAgentRegistry([["", { hookName: null }]])).toThrow();
    expect(() => createAgentRegistry([["agent", { hookName: "" }]])).toThrow();
  });
});
