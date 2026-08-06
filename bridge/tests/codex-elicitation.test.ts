import { describe, it, expect } from "bun:test";
import { planElicitation } from "../src/agents/codex/elicitation";

describe("planElicitation", () => {
  it("flattens a flat form schema into typed questions", () => {
    const plan = planElicitation({
      mode: "form",
      message: "Configure",
      requestedSchema: {
        type: "object",
        properties: {
          env: { type: "string", enum: ["dev", "prod"] },
          confirmed: { type: "boolean" },
          name: { type: "string" },
          count: { type: "number" },
        },
      },
    });
    expect(plan.mode).toBe("form");
    if (plan.mode !== "form") return;
    const [env, confirmed, name, count] = plan.questions;
    expect(env?.kind).toBe("single_select");
    expect(env?.options?.map((o) => o.label)).toEqual(["dev", "prod"]);
    expect(env?.coerce("1")).toBe("prod");
    expect(confirmed?.kind).toBe("single_select");
    expect(confirmed?.coerce("yes")).toBe(true);
    expect(confirmed?.coerce("no")).toBe(false);
    expect(name?.kind).toBe("text");
    expect(name?.coerce("abc")).toBe("abc");
    expect(count?.kind).toBe("text");
    expect(count?.coerce("3")).toBe(3);
  });

  it("maps url mode to a done/decline single_select", () => {
    const plan = planElicitation({ mode: "url", message: "Sign in", url: "https://x.test/auth" });
    expect(plan.mode).toBe("url");
    if (plan.mode !== "url") return;
    expect(plan.question.kind).toBe("single_select");
    expect(plan.question.prompt).toContain("https://x.test/auth");
    expect(plan.question.options?.map((o) => o.id)).toEqual(["done", "decline"]);
  });

  it("falls back to a JSON question for openai/form and non-flat schemas", () => {
    expect(planElicitation({ mode: "openai/form", message: "m", requestedSchema: {} }).mode).toBe("json-fallback");
    expect(planElicitation({
      mode: "form",
      message: "m",
      requestedSchema: { type: "object", properties: { nested: { type: "object" } } },
    }).mode).toBe("json-fallback");
    const plan = planElicitation({ mode: "form", message: "m" }); // no schema at all
    expect(plan.mode).toBe("json-fallback");
    if (plan.mode === "json-fallback") expect(plan.question.kind).toBe("text");
  });

  it("falls back to a JSON question for an empty-properties form (never auto-accepts)", () => {
    const plan = planElicitation({
      mode: "form",
      message: "m",
      requestedSchema: { type: "object", properties: {} },
    });
    // A zero-question form plan would make handleElicitation reply {action:"accept"}
    // without ever showing the user — surface a prompt instead.
    expect(plan.mode).toBe("json-fallback");
  });
});
