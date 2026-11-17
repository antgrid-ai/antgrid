import { describe, expect, test } from "bun:test";
import { join } from "node:path";

import type { NamingModelProbe } from "../src/agents/types";
import {
  parseVerboseModels, resolveOpencodeNamingModel, resolveOpencodeV1FamilyNamingModel, smallModelFor, type OpencodeModel,
} from "../src/agents/opencode/naming-model";
import { resolveKiloNamingModel } from "../src/agents/kilo/naming-model";

// Output shapes as opencode 1.19.5 prints them: `models --verbose` is a
// `provider/id` line then the model's pretty-printed JSON (more fields than the
// resolver reads), `debug paths` is a padded two-column table, and the state
// dir's model.json holds the TUI's recently used models.
const STATE = join("scratch", "state", "opencode");
const PATHS = `home       /scratch\ndata       /scratch/data/opencode\nstate      ${STATE}\ntmp        /scratch/tmp\n`;

function m(providerID: string, id: string, family: string, release_date: string): OpencodeModel {
  return { providerID, id, family, release_date };
}

function verbose(models: OpencodeModel[], eol = "\n"): string {
  return models.map((model) => `${model.providerID}/${model.id}${eol}${JSON.stringify({
    ...model, name: model.id, api: { id: model.id, npm: "@ai-sdk/synthetic" }, status: "active",
    cost: { input: 1, output: 2 }, limit: { context: 1000, output: 100 },
  }, null, 2).replaceAll("\n", eol)}`).join(eol) + eol;
}

function probe(opts: {
  config?: Record<string, unknown> | string; models?: OpencodeModel[]; recent?: Array<[string, string]>; paths?: string;
}): NamingModelProbe & { runs: string[][] } {
  const runs: string[][] = [];
  return {
    runs,
    async run(args) {
      runs.push(args);
      const key = args.join(" ");
      if (key === "debug config") return typeof opts.config === "string" ? opts.config : opts.config && JSON.stringify(opts.config);
      if (key === "debug paths") return opts.paths ?? PATHS;
      if (key === "models --verbose") return verbose(opts.models ?? []);
      return undefined;
    },
    async readText(path) {
      if (path !== join(STATE, "model.json") || !opts.recent) return undefined;
      return JSON.stringify({ recent: opts.recent.map(([providerID, modelID]) => ({ providerID, modelID })) });
    },
  };
}

// A ChatGPT sign-in narrows the openai provider to its Codex catalog, which has
// no model in a family opencode ranks as small.
const CHATGPT_OPENAI = [
  m("openai", "gpt-6.1-sol", "gpt-sol", "2026-09-29"),
  m("openai", "gpt-6-luna", "gpt-luna", "2026-09-22"),
  m("openai", "gpt-5.4-mini", "gpt-mini", "2026-03-17"),
];
const API_OPENAI = [
  ...CHATGPT_OPENAI,
  m("openai", "gpt-5-nano", "gpt-nano", "2025-08-07"),
  m("openai", "gpt-5.4-nano", "gpt-nano", "2026-03-17"),
];

describe("resolveOpencodeV1FamilyNamingModel (opencode 1.19.5's path, kept by Kilo)", () => {
  test("a provider with no small family leaves the call on opencode's default", async () => {
    // What opencode's own titling does here too: getSmallModel finds nothing,
    // so the title runs on the session's model.
    expect(await resolveOpencodeV1FamilyNamingModel(probe({
      config: {}, models: CHATGPT_OPENAI, recent: [["openai", "gpt-6.1-sol"]],
    }))).toBeUndefined();
  });

  test("an API-key openai provider names with its newest gpt-nano", async () => {
    expect(await resolveOpencodeV1FamilyNamingModel(probe({
      config: {}, models: API_OPENAI, recent: [["openai", "gpt-6.1-sol"]],
    }))).toBe("openai/gpt-5.4-nano");
  });

  test("the configured model's provider decides, ahead of recent models", async () => {
    const models = [
      ...API_OPENAI,
      m("anthropic", "claude-haiku-4-5", "claude-haiku", "2025-10-15"),
      m("anthropic", "claude-haiku-5-5", "claude-haiku", "2026-08-01"),
      m("anthropic", "claude-sonnet-5", "claude-sonnet", "2026-08-01"),
    ];
    expect(await resolveOpencodeV1FamilyNamingModel(probe({
      config: { model: "anthropic/claude-sonnet-5" }, models, recent: [["openai", "gpt-6.1-sol"]],
    }))).toBe("anthropic/claude-haiku-5-5");
  });

  test("a recent model the provider no longer lists is skipped", async () => {
    const models = [...API_OPENAI, m("anthropic", "claude-haiku-5-5", "claude-haiku", "2026-08-01")];
    expect(await resolveOpencodeV1FamilyNamingModel(probe({
      config: {}, models, recent: [["openai", "gpt-retired"], ["anthropic", "claude-haiku-5-5"]],
    }))).toBe("anthropic/claude-haiku-5-5");
  });

  test("the title agent's model wins over everything", async () => {
    expect(await resolveOpencodeV1FamilyNamingModel(probe({
      config: { agent: { title: { model: "openai/gpt-6-luna" } }, small_model: "openai/gpt-5-nano" },
      models: API_OPENAI, recent: [["openai", "gpt-6.1-sol"]],
    }))).toBe("openai/gpt-6-luna");
  });

  test("small_model is used when listed, and an unlisted one stops the search", async () => {
    expect(await resolveOpencodeV1FamilyNamingModel(probe({
      config: { small_model: "openai/gpt-6-luna" }, models: API_OPENAI,
    }))).toBe("openai/gpt-6-luna");
    expect(await resolveOpencodeV1FamilyNamingModel(probe({
      config: { small_model: "openai/gpt-gone" }, models: API_OPENAI, recent: [["openai", "gpt-6.1-sol"]],
    }))).toBeUndefined();
  });

  test("an unreadable install resolves to no model rather than a guess", async () => {
    expect(await resolveOpencodeV1FamilyNamingModel(probe({ config: undefined, models: API_OPENAI }))).toBeUndefined();
    expect(await resolveOpencodeV1FamilyNamingModel(probe({ config: "not json", models: API_OPENAI }))).toBeUndefined();
    // No configured model and no model.json: opencode's last-resort ranking is
    // not reproducible from the CLI, so the call keeps opencode's own default.
    expect(await resolveOpencodeV1FamilyNamingModel(probe({ config: {}, models: API_OPENAI }))).toBeUndefined();
    expect(await resolveOpencodeV1FamilyNamingModel(probe({
      config: {}, models: API_OPENAI, recent: [["openai", "gpt-6.1-sol"]], paths: "home  /scratch\n",
    }))).toBeUndefined();
  });
});

describe("smallModelFor", () => {
  test("gemini-flash outranks gpt-nano and claude-haiku on one provider", () => {
    const models = [
      m("router", "haiku", "claude-haiku", "2026-09-01"),
      m("router", "nano", "gpt-nano", "2026-09-01"),
      m("router", "flash", "gemini-flash", "2025-01-01"),
    ];
    expect(smallModelFor("router", models)?.id).toBe("flash");
  });

  test("opencode's own providers rank only gpt-nano; copilot tries gpt-mini first", () => {
    const models = [m("x", "haiku", "claude-haiku", "2026-09-01"), m("x", "mini", "gpt-mini", "2026-01-01")];
    expect(smallModelFor("opencode", models)).toBeUndefined();
    expect(smallModelFor("github-copilot", models)?.id).toBe("mini");
  });

  test("azure never gets a small model", () => {
    expect(smallModelFor("azure", [m("azure", "nano", "gpt-nano", "2026-01-01")])).toBeUndefined();
  });

  test("bedrock prefers a global profile, then the configured region's", () => {
    const models = [
      m("amazon-bedrock", "us.anthropic.claude-haiku", "claude-haiku", "2026-08-01"),
      m("amazon-bedrock", "eu.anthropic.claude-haiku", "claude-haiku", "2026-08-01"),
      m("amazon-bedrock", "anthropic.claude-haiku", "claude-haiku", "2026-08-01"),
    ];
    const eu = { provider: { "amazon-bedrock": { options: { region: "eu-west-1" } } } };
    expect(smallModelFor("amazon-bedrock", models, eu)?.id).toBe("eu.anthropic.claude-haiku");
    expect(smallModelFor("amazon-bedrock", models)?.id).toBe("anthropic.claude-haiku");
    const global = [...models, m("amazon-bedrock", "global.anthropic.claude-haiku", "claude-haiku", "2026-08-01")];
    expect(smallModelFor("amazon-bedrock", global, eu)?.id).toBe("global.anthropic.claude-haiku");
  });
});

// Kilo 7.8.x's catalog under its own gateway provider: model ids carry their
// own slash, and most entries have no family at all.
const KILO_GATEWAY = [
  { providerID: "kilo", id: "kilo-auto/balanced", release_date: "2026-11-03" },
  { providerID: "kilo", id: "kilo-auto/small", release_date: "2026-11-03" },
  m("kilo", "google/gemini-3-flash", "gemini-flash", "2026-10-01"),
  m("kilo", "anthropic/claude-haiku-5-5", "claude-haiku", "2026-08-01"),
];

describe("resolveKiloNamingModel", () => {
  test("a kilo provider names with kilo-auto/small ahead of the family search", async () => {
    const recent: Array<[string, string]> = [["kilo", "kilo-auto/balanced"]];
    expect(await resolveKiloNamingModel(probe({ config: {}, models: KILO_GATEWAY, recent })))
      .toBe("kilo/kilo-auto/small");
    // opencode's rules alone pick the family match, which is what Kilo's own rule overrides.
    expect(await resolveOpencodeV1FamilyNamingModel(probe({ config: {}, models: KILO_GATEWAY, recent })))
      .toBe("kilo/google/gemini-3-flash");
  });

  test("a kilo provider without kilo-auto/small falls back to the family search", async () => {
    const models = KILO_GATEWAY.filter((model) => model.id !== "kilo-auto/small");
    expect(await resolveKiloNamingModel(probe({ config: {}, models, recent: [["kilo", "kilo-auto/balanced"]] })))
      .toBe("kilo/google/gemini-3-flash");
  });

  // Kilo would fall back to kilo/kilo-auto/small here only for a user holding
  // Kilo credentials, which the resolver does not read.
  test("another provider with no small family names on Kilo's default, not the gateway", async () => {
    expect(await resolveKiloNamingModel(probe({
      config: {}, models: [...CHATGPT_OPENAI, ...KILO_GATEWAY], recent: [["openai", "gpt-6.1-sol"]],
    }))).toBeUndefined();
  });

  test("the preferred id applies only to kilo providers", async () => {
    const models = [{ providerID: "router", id: "kilo-auto/small" }, m("router", "nano", "gpt-nano", "2026-01-01")];
    expect(await resolveKiloNamingModel(probe({ config: {}, models, recent: [["router", "nano"]] })))
      .toBe("router/nano");
  });
});

test("parseVerboseModels reads every model, LF or CRLF", () => {
  for (const eol of ["\n", "\r\n"]) {
    const parsed = parseVerboseModels(verbose(API_OPENAI, eol));
    expect(parsed.map((model) => model.id)).toEqual(API_OPENAI.map((model) => model.id));
    expect(parsed[3]).toEqual(API_OPENAI[3]!);
  }
});

// OpenCode 2.2.6 `opencode api --standalone <operation>` output: the request's
// location, then `data`. Field sets as 2.2.6 prints them; the content is invented.
const LOCATION = { directory: join("scratch", "naming") };

function v2Model(providerID: string, id: string, family?: string, extra: Record<string, unknown> = {}) {
  return {
    id, modelID: id, providerID, type: "chat", name: id, ...(family ? { family } : {}),
    package: "@opencode/ai/providers/openai-compatible", settings: {},
    capabilities: { tools: true, input: ["text", "image"], output: ["text"] },
    variants: [], time: { released: 0 }, cost: [], status: "active", enabled: true,
    limit: { context: 32000, output: 2048 }, ...extra,
  };
}

function v2Agent(id: string, model?: Record<string, string>) {
  return { id, name: id, ...(model ? { model } : {}), request: { settings: {}, headers: {}, body: {} },
    mode: "primary", hidden: id === "title", permissions: [] };
}

const V2_AGENTS = ["build", "plan", "general", "explore", "compaction", "title", "summary"].map((id) => v2Agent(id));

function v2Probe(opts: {
  agents?: unknown[]; defaultModel?: Record<string, unknown>; models?: unknown[]; fail?: string;
}): NamingModelProbe & { runs: string[][] } {
  const runs: string[][] = [];
  const answers: Record<string, unknown> = {
    "agent.list": { location: LOCATION, data: opts.agents ?? V2_AGENTS },
    "model.default": opts.defaultModel && { location: LOCATION, data: opts.defaultModel },
    "model.list": { location: LOCATION, data: opts.models ?? [] },
  };
  return {
    runs,
    async run(args) {
      runs.push(args);
      if (args[0] !== "api" || args[1] !== "--standalone") return undefined;
      const answer = answers[args[2]!];
      return args[2] === opts.fail || answer === undefined ? undefined : JSON.stringify(answer, null, 2);
    },
    async readText() { return undefined; },
  };
}

const SMOKE = [
  v2Model("smoke", "big"),
  v2Model("smoke", "flash", "gemini-flash"),
  v2Model("smoke", "haiku", "claude-haiku"),
  v2Model("other", "luna", "gpt-luna"),
];

describe("resolveOpencodeNamingModel (OpenCode 2)", () => {
  test("every probe runs on a private server, never the shared background service", async () => {
    // A server-backed command without --standalone starts the user's background
    // service with this probe's OPENCODE_DB=:memory:, and it stays running.
    const probe = v2Probe({ defaultModel: SMOKE[0], models: SMOKE });
    await resolveOpencodeNamingModel(probe);
    expect(probe.runs.length).toBeGreaterThan(0);
    for (const args of probe.runs) expect(args).toContain("--standalone");
  });

  test("the default model's provider names with its first small-family model", async () => {
    expect(await resolveOpencodeNamingModel(v2Probe({ defaultModel: SMOKE[0], models: SMOKE }))).toBe("smoke/flash");
  });

  test("families rank gpt-luna, gemini-flash-lite, gemini-flash, claude-haiku; catalog order breaks ties", async () => {
    const models = [
      v2Model("p", "haiku", "claude-haiku"), v2Model("p", "flash", "gemini-flash"),
      v2Model("p", "lite-old", "gemini-flash-lite"), v2Model("p", "lite-new", "gemini-flash-lite"),
    ];
    expect(await resolveOpencodeNamingModel(v2Probe({ defaultModel: v2Model("p", "main"), models }))).toBe("p/lite-old");
    const luna = [...models, v2Model("p", "luna", "gpt-luna")];
    expect(await resolveOpencodeNamingModel(v2Probe({ defaultModel: v2Model("p", "main"), models: luna }))).toBe("p/luna");
  });

  test("inactive and non-text models are not small-model candidates", async () => {
    const models = [
      v2Model("p", "retired", "gpt-luna", { status: "deprecated" }),
      v2Model("p", "speech", "gemini-flash", { capabilities: { tools: false, input: ["audio"], output: ["audio"] } }),
      v2Model("p", "haiku", "claude-haiku"),
    ];
    expect(await resolveOpencodeNamingModel(v2Probe({ defaultModel: v2Model("p", "main"), models }))).toBe("p/haiku");
  });

  // 2.2.6 `run --model smoke/tiny#low` ran on that variant; `#nope` failed the
  // run with "Variant unavailable for smoke/tiny: nope".
  test("the title agent's model wins, with its variant, when the install knows both", async () => {
    const titled = (model: Record<string, string>) => [...V2_AGENTS.filter((agent) => agent.id !== "title"), v2Agent("title", model)];
    const models = [...SMOKE, v2Model("other", "sol", "gpt-sol", { variants: [{ id: "low", settings: { reasoningEffort: "low" } }] })];
    const agents = titled({ providerID: "other", id: "sol", variant: "low" });
    expect(await resolveOpencodeNamingModel(v2Probe({ agents, defaultModel: SMOKE[0], models }))).toBe("other/sol#low");
    expect(await resolveOpencodeNamingModel(v2Probe({ agents: titled({ providerID: "other", id: "sol" }), defaultModel: SMOKE[0], models })))
      .toBe("other/sol");
    expect(await resolveOpencodeNamingModel(v2Probe({
      agents: titled({ providerID: "other", id: "sol", variant: "max" }), defaultModel: SMOKE[0], models,
    }))).toBeUndefined();
    const unknown = [...V2_AGENTS.filter((agent) => agent.id !== "title"), v2Agent("title", { providerID: "other", id: "gone" })];
    expect(await resolveOpencodeNamingModel(v2Probe({ agents: unknown, defaultModel: SMOKE[0], models: SMOKE }))).toBeUndefined();
  });

  test("no small model, no title agent or an unreadable probe leaves OpenCode's default", async () => {
    expect(await resolveOpencodeNamingModel(v2Probe({ defaultModel: SMOKE[3], models: [SMOKE[3]!, v2Model("other", "big")] })))
      .toBe("other/luna");
    expect(await resolveOpencodeNamingModel(v2Probe({ defaultModel: v2Model("other", "big"), models: [v2Model("other", "big")] })))
      .toBeUndefined();
    expect(await resolveOpencodeNamingModel(v2Probe({
      agents: V2_AGENTS.filter((agent) => agent.id !== "title"), defaultModel: SMOKE[0], models: SMOKE,
    }))).toBeUndefined();
    for (const fail of ["agent.list", "model.default", "model.list"]) {
      expect(await resolveOpencodeNamingModel(v2Probe({ defaultModel: SMOKE[0], models: SMOKE, fail }))).toBeUndefined();
    }
  });
});
