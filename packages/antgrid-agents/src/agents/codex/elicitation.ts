// Best-effort flatten of one mcpServer/elicitation/request onto agent:question
// primitives. The rule from the design spec: always surface SOMETHING — never
// silently auto-decline, never block. Shapes verified against
// codex-rs/app-server-protocol/src/protocol/v2/mcp.rs (mode tags "form",
// "openai/form", "url"; McpElicitationSchema is a flat object-of-primitives).

export type FlatQuestion = {
  name: string;
  kind: "single_select" | "text";
  prompt: string;
  options?: Array<{ id: string; label: string }>;
  coerce: (value: string) => unknown;
};

export type ElicitationPlan =
  | { mode: "form"; questions: FlatQuestion[] }
  | { mode: "url"; question: FlatQuestion }
  | { mode: "json-fallback"; question: FlatQuestion };

export function planElicitation(p: any): ElicitationPlan {
  const message = String(p?.message ?? "");
  if (p?.mode === "url") {
    return {
      mode: "url",
      question: {
        name: "url",
        kind: "single_select",
        prompt: `${message}\n${String(p?.url ?? "")}`.trim(),
        options: [
          { id: "done", label: "Done — I opened the link" },
          { id: "decline", label: "Decline" },
        ],
        coerce: (v) => v,
      },
    };
  }
  if (p?.mode === "form") {
    const props = p?.requestedSchema?.properties;
    if (props && typeof props === "object") {
      const questions: FlatQuestion[] = [];
      let flat = true;
      for (const [name, schema] of Object.entries<any>(props)) {
        const prompt = `${message}\n${name}`.trim();
        if (Array.isArray(schema?.enum)) {
          const values: unknown[] = schema.enum;
          questions.push({
            name, kind: "single_select", prompt,
            options: values.map((v, i) => ({ id: String(i), label: String(v) })),
            coerce: (v) => {
              const i = Number(v);
              return Number.isInteger(i) && i >= 0 && i < values.length ? values[i] : v;
            },
          });
        } else if (schema?.type === "boolean") {
          questions.push({
            name, kind: "single_select", prompt,
            options: [{ id: "yes", label: "Yes" }, { id: "no", label: "No" }],
            coerce: (v) => v === "yes",
          });
        } else if (schema?.type === "string") {
          questions.push({ name, kind: "text", prompt, coerce: (v) => v });
        } else if (schema?.type === "number" || schema?.type === "integer") {
          questions.push({ name, kind: "text", prompt, coerce: (v) => Number(v) });
        } else {
          flat = false;
          break;
        }
      }
      // An empty-properties form asks for nothing; returning it would make the
      // driver auto-accept a request the user never saw. Fall through to the
      // JSON prompt so the elicitation is always surfaced (spec contract).
      if (flat && questions.length > 0) return { mode: "form", questions };
    }
  }
  // "openai/form" (free-form JSON schema), a non-flat form schema, or anything
  // unrecognized: one free-text question asking for a JSON object.
  return {
    mode: "json-fallback",
    question: {
      name: "json",
      kind: "text",
      prompt: `${message}\nAnswer with a JSON object matching the requested schema.`.trim(),
      coerce: (v) => v,
    },
  };
}
