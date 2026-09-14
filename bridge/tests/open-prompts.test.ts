import { describe, expect, test } from "bun:test";
import { OpenAgentPrompts } from "../src/agents/open-prompts";

describe("OpenAgentPrompts", () => {
  test("answers about the prompt's tool, not about the slot", () => {
    // The batch case: AskUserQuestion and a Bash call needing approval are open
    // on one terminal at once, and only the first has been announced with its
    // text. A slot-wide answer swallows the Bash approval entirely.
    const open = new OpenAgentPrompts();
    open.open("t1", "toolu_1", "AskUserQuestion");
    expect(open.has("t1", "AskUserQuestion")).toBe(true);
    expect(open.has("t1", "Bash")).toBe(false);
  });

  test("an unnamed tool is answered no", () => {
    // The predicate only ever silences, so "I cannot say which prompt this is
    // about" has to cost a duplicate push rather than a missing block.
    const open = new OpenAgentPrompts();
    open.open("t1", "toolu_1", "AskUserQuestion");
    expect(open.has("t1", undefined)).toBe(false);
  });

  test("a prompt is closed by its own id and leaves its siblings alone", () => {
    const open = new OpenAgentPrompts();
    open.open("t1", "toolu_1", "AskUserQuestion");
    open.open("t1", "toolu_2", "Bash");
    open.close("t1", "toolu_1");
    expect(open.has("t1", "AskUserQuestion")).toBe(false);
    expect(open.has("t1", "Bash")).toBe(true);
  });

  test("a prompt reported with no id pairs with the completion reported the same way", () => {
    // Both halves come from one CLI whose payload either carries the id or does
    // not, so the sentinel is only ever matched against itself — and it never
    // leaves this class, where an absent id would mean "every prompt is gone".
    const open = new OpenAgentPrompts();
    open.open("t1", undefined, "AskUserQuestion");
    open.open("t1", "toolu_2", "Bash");
    open.close("t1", undefined);
    expect(open.has("t1", "AskUserQuestion")).toBe(false);
    expect(open.has("t1", "Bash")).toBe(true);
  });

  test("closing what was never open is a no-op, and slots do not bleed", () => {
    const open = new OpenAgentPrompts();
    open.close("t1", "toolu_1");
    open.open("t1", "toolu_1", "AskUserQuestion");
    expect(open.has("t2", "AskUserQuestion")).toBe(false);
    open.clear("t1");
    expect(open.has("t1", "AskUserQuestion")).toBe(false);
  });
});
