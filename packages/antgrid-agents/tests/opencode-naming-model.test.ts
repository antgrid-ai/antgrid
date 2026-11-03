import { describe, expect, test } from "bun:test";
import { join } from "node:path";

import type { NamingModelProbe } from "../src/agents/types";
import {
  parseVerboseModels, resolveOpencodeNamingModel, smallModelFor, type OpencodeModel,
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

describe("resolveOpencodeNamingModel", () => {
  test("a provider with no small family leaves the call on opencode's default", async () => {
    // What opencode's own titling does here too: getSmallModel finds nothing,
    // so the title runs on the session's model.
    expect(await resolveOpencodeNamingModel(probe({
      config: {}, models: CHATGPT_OPENAI, recent: [["openai", "gpt-6.1-sol"]],
    }))).toBeUndefined();
  });

  test("an API-key openai provider names with its newest gpt-nano", async () => {
    expect(await resolveOpencodeNamingModel(probe({
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
    expect(await resolveOpencodeNamingModel(probe({
      config: { model: "anthropic/claude-sonnet-5" }, models, recent: [["openai", "gpt-6.1-sol"]],
    }))).toBe("anthropic/claude-haiku-5-5");
  });

  test("a recent model the provider no longer lists is skipped", async () => {
    const models = [...API_OPENAI, m("anthropic", "claude-haiku-5-5", "claude-haiku", "2026-08-01")];
    expect(await resolveOpencodeNamingModel(probe({
      config: {}, models, recent: [["openai", "gpt-retired"], ["anthropic", "claude-haiku-5-5"]],
    }))).toBe("anthropic/claude-haiku-5-5");
  });

  test("the title agent's model wins over everything", async () => {
    expect(await resolveOpencodeNamingModel(probe({
      config: { agent: { title: { model: "openai/gpt-6-luna" } }, small_model: "openai/gpt-5-nano" },
      models: API_OPENAI, recent: [["openai", "gpt-6.1-sol"]],
    }))).toBe("openai/gpt-6-luna");
  });

  test("small_model is used when listed, and an unlisted one stops the search", async () => {
    expect(await resolveOpencodeNamingModel(probe({
      config: { small_model: "openai/gpt-6-luna" }, models: API_OPENAI,
    }))).toBe("openai/gpt-6-luna");
    expect(await resolveOpencodeNamingModel(probe({
      config: { small_model: "openai/gpt-gone" }, models: API_OPENAI, recent: [["openai", "gpt-6.1-sol"]],
    }))).toBeUndefined();
  });

  test("an unreadable install resolves to no model rather than a guess", async () => {
    expect(await resolveOpencodeNamingModel(probe({ config: undefined, models: API_OPENAI }))).toBeUndefined();
    expect(await resolveOpencodeNamingModel(probe({ config: "not json", models: API_OPENAI }))).toBeUndefined();
    // No configured model and no model.json: opencode's last-resort ranking is
    // not reproducible from the CLI, so the call keeps opencode's own default.
    expect(await resolveOpencodeNamingModel(probe({ config: {}, models: API_OPENAI }))).toBeUndefined();
    expect(await resolveOpencodeNamingModel(probe({
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
    expect(await resolveOpencodeNamingModel(probe({ config: {}, models: KILO_GATEWAY, recent })))
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
