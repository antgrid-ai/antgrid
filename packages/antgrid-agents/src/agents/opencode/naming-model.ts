import { join } from "node:path";

import type { NamingModelProbe } from "../types";

/**
 * The model OpenCode 2 itself would title a session with, so a naming call asks
 * for one this user's providers can actually serve.
 *
 * opencode reaches many providers, so no fixed `provider/model` string is right
 * for every install: an account with no `openai` provider has no `openai/…`
 * model at all, and a ChatGPT sign-in serves only that account's Codex catalog.
 * This ports OpenCode 2.2.6's `SessionContext.selectTitle` for a call with no
 * session of its own:
 *
 *   1. the `title` agent's model (a legacy `small_model` is translated into it),
 *      when the install knows that model;
 *   2. the first model, in catalog order, of the small families `Model.small`
 *      ranks for the default model's provider.
 *
 * Undefined means "no --model", which leaves `opencode run` on its default
 * model, as OpenCode's own last fallback does; so does any probe failure.
 *
 * Every probe runs `--standalone`. Without it, a 2.x command that needs a server
 * starts the user's shared background service, which outlives the probe and
 * inherits the naming spawn's `OPENCODE_DB=:memory:`: every later session the
 * user opens through that service would be written to memory and lost.
 */
export async function resolveOpencodeNamingModel(probe: NamingModelProbe): Promise<string | undefined> {
  const [agentsText, defaultText, modelsText] = await Promise.all([
    probe.run(["api", "--standalone", "agent.list"]),
    probe.run(["api", "--standalone", "model.default"]),
    probe.run(["api", "--standalone", "model.list"]),
  ]);
  const agents = rec(parseJson(agentsText)).data;
  const models = rec(parseJson(modelsText)).data;
  if (!Array.isArray(agents) || !Array.isArray(models)) return undefined;
  const title = agents.map(rec).find((agent) => agent.id === "title");
  // No title agent, no generated title in OpenCode either.
  if (!title) return undefined;
  const listed = models.map(rec);

  const configured = rec(title.model);
  const providerID = str(configured.providerID);
  const id = str(configured.id);
  if (providerID && id) {
    const model = listed.find((entry) => entry.providerID === providerID && entry.id === id);
    if (!model) return undefined;
    const variant = str(configured.variant);
    if (!variant) return `${providerID}/${id}`;
    // `run --model p/m#v` fails the whole run ("Variant unavailable") on a
    // variant the model does not list.
    const variants = Array.isArray(model.variants) ? model.variants.map(rec) : [];
    return variants.some((entry) => entry.id === variant) ? `${providerID}/${id}#${variant}` : undefined;
  }

  const provider = str(rec(rec(parseJson(defaultText)).data).providerID);
  if (!provider) return undefined;
  const text = (kinds: unknown) => Array.isArray(kinds) && kinds.some((kind) => typeof kind === "string" && kind.startsWith("text"));
  const candidates = listed.filter((model) => model.providerID === provider && model.status === "active"
    && text(rec(model.capabilities).input) && text(rec(model.capabilities).output));
  for (const family of V2_SMALL_FAMILIES) {
    const small = str(candidates.find((model) => model.family === family)?.id);
    if (small) return `${provider}/${small}`;
  }
  return undefined;
}

const V2_SMALL_FAMILIES = ["gpt-luna", "gemini-flash-lite", "gemini-flash", "claude-haiku"];

/**
 * The model an opencode-1.x-family CLI would title a session with. Kilo 7.8.x
 * keeps opencode 1.19.5's title path, probe commands and output shapes, so this
 * is that port; OpenCode 2 itself resolves through `resolveOpencodeNamingModel`.
 *
 * Ports opencode 1.19.5's `SessionPrompt` title → `Provider.getSmallModel` →
 * `Provider.defaultModel` over what its CLI prints:
 *
 *   1. the `title` agent's configured model;
 *   2. `small_model` from config, when the provider lists it;
 *   3. the newest model of the small family opencode ranks for the provider of
 *      the default model (the session's model in opencode's own path; a naming
 *      call has no session, which is the case opencode's project-name
 *      generator resolves the same way).
 *
 * Undefined means "no --model", which leaves `opencode run` on that same
 * default model — exactly opencode's own last fallback. So is any probe
 * failure: a resolution that cannot read the install must not invent a model.
 *
 * Not ported: the `experimental.provider.small_model` plugin hook, which only a
 * running opencode can answer, and the last-resort default ranking when neither
 * `model` nor a recent model is set (opencode picks it from provider order this
 * CLI does not print, so the call runs on opencode's own default instead).
 *
 * `rules` carries a fork's additions to that path (Kilo's are in
 * `kilo/naming-model.ts`); a fork that keeps the probe commands and output
 * shapes reuses everything else.
 */
export async function resolveOpencodeV1FamilyNamingModel(
  probe: NamingModelProbe, rules: SmallModelRules = {},
): Promise<string | undefined> {
  const [configText, pathsText, modelsText] = await Promise.all([
    probe.run(["debug", "config"]),
    probe.run(["debug", "paths"]),
    probe.run(["models", "--verbose"]),
  ]);
  const config = parseJson(configText);
  if (!isRec(config)) return undefined;

  const titleModel = str(rec(rec(config.agent).title).model);
  if (titleModel) return titleModel;

  const models = parseVerboseModels(modelsText);
  const has = (ref: ModelRef) => models.some((m) => m.providerID === ref.providerID && m.id === ref.modelID);

  const small = str(config.small_model);
  // opencode stops at small_model whether or not it resolves: an unlisted one
  // falls straight through to the session's model, not to the family search.
  if (small) return has(parseRef(small)) ? small : undefined;

  const provider = await defaultProvider(config, pathsText, has, probe);
  if (!provider) return undefined;
  const picked = smallModelFor(provider, models.filter((m) => m.providerID === provider), config, rules);
  return picked ? `${provider}/${picked.id}` : undefined;
}

export interface SmallModelRules {
  /** Exact model ids tried, in order, before the small-family search. */
  preferredIds?: (providerID: string) => readonly string[];
}

export interface OpencodeModel {
  id: string;
  providerID: string;
  family?: string;
  release_date?: string;
}

interface ModelRef { providerID: string; modelID: string }

/** `Provider.defaultModel`'s first two tiers, reduced to the provider. */
async function defaultProvider(
  config: Record<string, unknown>,
  pathsText: string | undefined,
  has: (ref: ModelRef) => boolean,
  probe: NamingModelProbe,
): Promise<string | undefined> {
  const configured = str(config.model);
  if (configured) return parseRef(configured).providerID;
  const stateDir = pathsText?.match(/^state\s+(.+?)\s*$/m)?.[1];
  if (!stateDir) return undefined;
  const recent = rec(parseJson(await probe.readText(join(stateDir, "model.json")))).recent;
  for (const entry of Array.isArray(recent) ? recent : []) {
    const ref = { providerID: str(rec(entry).providerID) ?? "", modelID: str(rec(entry).modelID) ?? "" };
    if (ref.providerID && ref.modelID && has(ref)) return ref.providerID;
  }
  return undefined;
}

const SMALL_FAMILIES = ["gemini-flash", "gpt-nano", "claude-haiku"];
const BEDROCK_PREFIXES = ["global.", "us.", "eu."];

/** `Provider.getSmallModel` after its small_model and plugin tiers. */
export function smallModelFor(
  providerID: string, models: OpencodeModel[], config: Record<string, unknown> = {}, rules: SmallModelRules = {},
): OpencodeModel | undefined {
  if (providerID === "azure" || providerID === "azure-cognitive-services") return undefined;
  for (const id of rules.preferredIds?.(providerID) ?? []) {
    const preferred = models.find((m) => m.id === id);
    if (preferred) return preferred;
  }
  const families = providerID.startsWith("opencode") ? ["gpt-nano"]
    : providerID.startsWith("github-copilot") ? ["gpt-mini", ...SMALL_FAMILIES]
    : SMALL_FAMILIES;
  const sorted = [...models].sort((a, b) =>
    desc(a.release_date ?? "", b.release_date ?? "") || desc(a.id, b.id));
  for (const family of families) {
    const candidates = sorted.filter((m) => m.family === family);
    if (providerID !== "amazon-bedrock") {
      if (candidates[0]) return candidates[0];
      continue;
    }
    const global = candidates.find((m) => m.id.startsWith("global."));
    if (global) return global;
    const region = str(rec(rec(rec(config.provider)["amazon-bedrock"]).options).region)?.split("-")[0];
    if (region === "us" || region === "eu") {
      const regional = candidates.find((m) => m.id.startsWith(`${region}.`));
      if (regional) return regional;
    }
    const unprefixed = candidates.find((m) => !BEDROCK_PREFIXES.some((p) => m.id.startsWith(p)));
    if (unprefixed) return unprefixed;
  }
  return undefined;
}

/**
 * `opencode models --verbose`: each model is a `provider/id` line followed by
 * its JSON, pretty-printed, closing on a `}` at column 0.
 */
export function parseVerboseModels(text: string | undefined): OpencodeModel[] {
  const out: OpencodeModel[] = [];
  for (const [, , body] of (text ?? "").matchAll(/^([^\s{}]+\/[^\s{}]+)\r?\n(\{[\s\S]*?\r?\n\})/gm)) {
    const value = rec(parseJson(body));
    const id = str(value.id);
    const providerID = str(value.providerID);
    if (!id || !providerID) continue;
    out.push({ id, providerID, family: str(value.family), release_date: str(value.release_date) });
  }
  return out;
}

function parseRef(ref: string): ModelRef {
  const [providerID = "", ...rest] = ref.split("/");
  return { providerID, modelID: rest.join("/") };
}

function desc(a: string, b: string): number {
  return a < b ? 1 : a > b ? -1 : 0;
}

function parseJson(text: string | undefined): unknown {
  if (!text) return undefined;
  try { return JSON.parse(text); } catch { return undefined; }
}

function isRec(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function rec(value: unknown): Record<string, unknown> {
  return isRec(value) ? value : {};
}

function str(value: unknown): string | undefined {
  return typeof value === "string" && value ? value : undefined;
}
