// Readers for the usage envelopes the agent CLIs emit when asked for one, and
// the vendor-agnostic unwrapper the output parsers run first.
//
// Every path below was read off a real run of the installed binary — the numbers
// in the comments are from those captures, not from documentation, and a field
// nobody observed is absent here rather than guessed at. What each reader must
// keep is that a shape it does not recognise is `null`, never a throw and never
// a partial answer: an envelope that changes next month costs the token counts
// and nothing else.

import type { HeadlessUsageReading, HeadlessUsageTokens } from "./types";

function asObject(v: unknown): Record<string, unknown> | null {
  return typeof v === "object" && v !== null && !Array.isArray(v)
    ? (v as Record<string, unknown>)
    : null;
}

function num(v: unknown): number | undefined {
  return typeof v === "number" && Number.isFinite(v) ? v : undefined;
}

function str(v: unknown): string | undefined {
  return typeof v === "string" && v.length > 0 ? v : undefined;
}

/** One JSON object, or null for anything else — a blank line, a plain-text line
 *  interleaved into a JSONL stream, a truncated write. */
function parseJsonObject(text: string): Record<string, unknown> | null {
  const trimmed = text.trim();
  if (!trimmed.startsWith("{")) return null;
  try {
    return asObject(JSON.parse(trimmed));
  } catch {
    return null;
  }
}

/** The tokens object, or `undefined` when every field of it was absent — an
 *  empty `usage` on the record would read as "this vendor reported zero", which
 *  is a different claim from "this vendor reported nothing". */
function tokensOrNothing(t: HeadlessUsageTokens): HeadlessUsageTokens | undefined {
  return Object.values(t).some((v) => v !== undefined) ? t : undefined;
}

/**
 * A money field, or nothing at all below a positive amount.
 *
 * Measured, and the reason the rule is shared rather than per vendor: opencode
 * reports `cost: 0` for a call that spent 6463 input tokens, because this
 * machine's provider is signed in by OAuth and carries no price metadata. A zero
 * recorded there asserts the call was free. claude's own zero is truthful (its
 * failed run never reached a model), so withholding it costs a reader nothing
 * that the failure itself does not already tell them.
 */
function money(amount: number | undefined, unit: string): { unit: string; amount: number } | undefined {
  return amount !== undefined && amount > 0 ? { unit, amount } : undefined;
}

/** An answer of zero characters is not an answer: leaving `text` unset is what
 *  hands the caller the raw stdout back, which is the behaviour it had before
 *  any of this existed. */
function answer(text: string): string | undefined {
  return text.length > 0 ? text : undefined;
}

/**
 * claude-code's `--output-format json`: one JSON object, on one line of stdout,
 * with the model's own answer inside it as `result`.
 *
 * TOKENS ARE SUMMED OVER `modelUsage`, NOT TAKEN FROM THE TOP-LEVEL `usage`, and
 * the two are not the same measurement. A one-word prompt measured here billed
 * TWO models — the requested `claude-opus-5[1m]` and a background
 * `claude-haiku-4-5-20251001` — and the top-level `usage` describes only the
 * first (2 input tokens against 901 for the pair). `total_cost_usd` is the exact
 * sum of the per-model `costUSD` values, so taking the top-level tokens beside
 * it would put a token count and a cost in one record that describe different
 * sets of API calls. Everything the user is billed for is in `modelUsage`; the
 * price is list price (`costBasis: "list"`), not what a subscription seat pays.
 */
export function readClaudeCodeUsage(stdout: string): HeadlessUsageReading | null {
  const env = parseJsonObject(stdout);
  // `type` and a string `result` together are what identify the envelope. A
  // looser guard would let a judge's own JSON answer — which is also one object
  // on stdout — be read as a wrapper around itself.
  if (!env || env.type !== "result" || typeof env.result !== "string") return null;

  const models = Object.values(asObject(env.modelUsage) ?? {})
    .map((m) => asObject(m))
    .filter((m): m is Record<string, unknown> => m !== null);
  const sum = (field: string): number | undefined => {
    let total: number | undefined;
    for (const m of models) {
      const n = num(m[field]);
      if (n !== undefined) total = (total ?? 0) + n;
    }
    return total;
  };

  return {
    text: answer(env.result),
    // The signal, and the only one: `subtype` reads "success" on a 404 run too.
    // `api_error_status` and `terminal_reason` say more about WHY and are not
    // needed to answer whether the answer is usable.
    failed: env.is_error === true,
    usage: tokensOrNothing({
      // Measured DISJOINT here: the capture reports 2 input tokens beside 15232
      // cache reads, so the two are separate quantities and the prompt is their
      // sum. That is not true of every vendor — see readCodexUsage.
      inputTokens: sum("inputTokens"),
      cacheReadTokens: sum("cacheReadInputTokens"),
      cacheWriteTokens: sum("cacheCreationInputTokens"),
      outputTokens: sum("outputTokens"),
      // ALREADY INSIDE `outputTokens` for this vendor, which is why it is read
      // from the per-model `thinkingTokens` rather than added to anything: the
      // envelope's own top-level home for it is
      // `usage.output_tokens_details.thinking_tokens`, a breakdown OF the output
      // count. codex and opencode report theirs as a sibling instead.
      reasoningTokens: sum("thinkingTokens"),
      money: money(num(env.total_cost_usd), "USD"),
      numTurns: num(env.num_turns),
      // An ARRAY, not a count, and its element shape is unmeasured — nothing in
      // either capture denied a tool. Only its length is read.
      permissionDenials: Array.isArray(env.permission_denials)
        ? env.permission_denials.length
        : undefined,
      // Says out loud what the sum above is: the counts describe every model
      // this call billed, while `actualModel` below can name only the one that
      // answered. Without it a row reads 901 input tokens against a model that
      // spent 2 of them, and nothing anywhere would say why.
      modelsBilled: models.length > 1 ? models.length : undefined,
    }),
    actualModel: billedModel(asObject(env.modelUsage)),
    apiMs: num(env.duration_api_ms),
  };
}

/**
 * Which of the models on a claude run the caller actually asked for.
 *
 * There is no scalar model field in the envelope at all; the names are the KEYS
 * of `modelUsage`, and a trivial prompt had two of them. The expensive entry is
 * the one that answered — the other is Claude Code's own background model — so
 * spend picks it, with the token count as the fallback for a run whose costs are
 * all zero. `{}` on a failed run leaves no name to report.
 */
function billedModel(models: Record<string, unknown> | null): string | undefined {
  let best: string | undefined;
  let bestCost = 0;
  let bestTokens = -1;
  for (const [id, raw] of Object.entries(models ?? {})) {
    const m = asObject(raw);
    if (!m) continue;
    const cost = num(m.costUSD) ?? 0;
    const toks = (num(m.inputTokens) ?? 0) + (num(m.outputTokens) ?? 0);
    if (cost > bestCost || (bestCost === 0 && cost === 0 && toks > bestTokens)) {
      best = id;
      bestCost = cost;
      bestTokens = toks;
    }
  }
  return best;
}

/**
 * codex's `--json`: newline-delimited events, with the model's answer on an
 * `item.completed` line and every usage number on the terminal `turn.completed`.
 *
 * No model name exists anywhere in the stream — `-m` is input-only and the CLI
 * never echoes what it used — and there is no cost, turn count or denial count
 * either. Those stay unset rather than being synthesised from the event tally.
 */
export function readCodexUsage(stdout: string): HeadlessUsageReading | null {
  const lines = jsonLines(stdout);
  if (!lines.some((l) => CODEX_TERMINAL_TYPES.has(String(l.type)))) return null;

  const texts: string[] = [];
  let usage: HeadlessUsageTokens | undefined;
  let failed = false;
  for (const line of lines) {
    if (line.type === "item.completed") {
      const item = asObject(line.item);
      if (item?.type === "agent_message") {
        const t = str(item.text);
        if (t) texts.push(t);
      }
    } else if (line.type === "turn.completed") {
      const u = asObject(line.usage);
      if (u) {
        usage = tokensOrNothing({
          // UNMEASURED, and the one number here a reader must not assume:
          // whether `input_tokens` (16666 on the capture) already CONTAINS
          // `cached_input_tokens` (12544). claude's equivalents are provably
          // disjoint; this pair's single trivial run could not tell the two
          // readings apart, so both are recorded as the vendor gave them and
          // neither is ever added to the other.
          inputTokens: num(u.input_tokens),
          cacheReadTokens: num(u.cached_input_tokens),
          cacheWriteTokens: num(u.cache_write_input_tokens),
          outputTokens: num(u.output_tokens),
          // A SIBLING of output_tokens here, not a breakdown of it as claude's
          // is: separate spend, so adding this vendor's pair is the right
          // arithmetic where adding claude's would double count.
          reasoningTokens: num(u.reasoning_output_tokens),
        });
      }
    } else if (line.type === "turn.failed" || line.type === "error") {
      failed = true;
    }
  }
  // Failure is what the stream SAYS failed — a `turn.failed`, or the top-level
  // error line that precedes it — never the ABSENCE of a `turn.completed`. The
  // answer arrives on its own `item.completed` line, so deriving the verdict
  // from the terminal event would let a renamed one veto an answer this reader
  // has already read correctly, and the exit code still speaks for the run
  // either way. An `item.completed` whose item type is "error" is not a failure
  // at all: a non-fatal metadata warning arrives that way.
  return { text: answer(texts.join("\n")), usage, failed };
}

const CODEX_TERMINAL_TYPES = new Set(["thread.started", "turn.completed", "turn.failed"]);

/**
 * opencode's `--format json`: newline-delimited `{type, timestamp, sessionID,
 * …}` events with no wrapper and no terminal summary.
 *
 * TOKENS ONLY, deliberately. `cost` is a false zero under this machine's OAuth
 * provider (see `money`), and the model name is SUPPRESSED by the shipped binary
 * whenever the format is json — the banner carrying it is printed on the
 * default format only, so there is nothing to read rather than something we
 * chose not to.
 *
 * Two properties of the numbers a reader should know and nothing in the file
 * records: usage must be SUMMED over every `step_finish` line, because a
 * multi-step run emits one per step and nothing aggregates them; and every
 * record undercounts by one call, because opencode auto-titles each new session
 * and that call emits no step at all.
 */
export function readOpencodeUsage(stdout: string): HeadlessUsageReading | null {
  // Unparseable lines are SKIPPED rather than fatal, and that is not defensive
  // padding: a permission ask with no --auto prints "! permission requested …
  // auto-rejecting" as plain text into this stream, ungated by the format flag.
  const lines = jsonLines(stdout).filter(
    (l) => typeof l.sessionID === "string" && OPENCODE_TYPES.has(String(l.type)),
  );
  if (lines.length === 0) return null;

  const texts: string[] = [];
  let usage: HeadlessUsageTokens | undefined;
  let failed = false;
  const add = (into: number | undefined, v: number | undefined): number | undefined =>
    v === undefined ? into : (into ?? 0) + v;
  for (const line of lines) {
    const part = asObject(line.part);
    if (line.type === "text") {
      const t = str(part?.text);
      if (t) texts.push(t);
    } else if (line.type === "step_finish") {
      const tk = asObject(part?.tokens);
      const cache = asObject(tk?.cache);
      const acc = usage ?? {};
      usage = {
        inputTokens: add(acc.inputTokens, num(tk?.input)),
        cacheReadTokens: add(acc.cacheReadTokens, num(cache?.read)),
        cacheWriteTokens: add(acc.cacheWriteTokens, num(cache?.write)),
        outputTokens: add(acc.outputTokens, num(tk?.output)),
        // Billed, and a SIBLING of `output` rather than a breakdown of it as
        // claude's is — so the two vendors' output counts do not mean the same
        // thing, and dropping this would put a reasoning model's real output
        // spend nowhere on the machine at all.
        reasoningTokens: add(acc.reasoningTokens, num(tk?.reasoning)),
      };
    } else if (line.type === "error") {
      failed = true;
    }
  }
  return { text: answer(texts.join("\n")), usage: usage && tokensOrNothing(usage), failed };
}

const OPENCODE_TYPES = new Set(["step_start", "step_finish", "text", "tool_use", "reasoning", "error"]);

/**
 * github-copilot's `--usage-output-file`: one JSON object in a file we name,
 * with stdout left byte-identical to a run without the flag.
 *
 * The file is written on the failure path too, and its shape there is not the
 * success shape zeroed — `tokenDetails` and `currentModel` are absent outright —
 * so every field is read independently.
 *
 * `numTurns` and `permissionDenials` have no source here and are left unset:
 * `totalUserRequests` is prompts submitted (always 1 for a `-p` spawn) and
 * `modelMetrics[*].requests.count` is API calls, and recording either under a
 * name that says turns would make the column mean two things.
 */
export function readCopilotUsage(contents: string): HeadlessUsageReading | null {
  const env = parseJsonObject(contents);
  // Present on both the success and the failure capture, which is what makes it
  // the identity field rather than one of the ones failure drops.
  if (!env || num(env.totalUserRequests) === undefined) return null;

  const details = asObject(env.tokenDetails);
  const tokenCount = (key: string): number | undefined => num(asObject(details?.[key])?.tokenCount);
  // Read by name out of each model's own block, never by spreading it: the
  // envelope's `codeChanges.filesModified` is an array of paths out of the
  // user's working tree sitting one key away from these numbers.
  const models = Object.values(asObject(env.modelMetrics) ?? {})
    .map((m) => asObject(m))
    .filter((m): m is Record<string, unknown> => m !== null);
  let reasoning: number | undefined;
  for (const m of models) {
    const n = num(asObject(m.usage)?.reasoningTokens);
    if (n !== undefined) reasoning = (reasoning ?? 0) + n;
  }
  return {
    usage: tokensOrNothing({
      inputTokens: tokenCount("input"),
      cacheReadTokens: tokenCount("cache_read"),
      cacheWriteTokens: tokenCount("cache_write"),
      outputTokens: tokenCount("output"),
      // Whether it is also inside `output` is unmeasured — the capture reported
      // zero of them — so the two are recorded separately and never added.
      reasoningTokens: reasoning,
      // Two currencies, both always present, and they are not interchangeable:
      // nano AI credits are what Copilot bills today, premium requests are the
      // legacy count an account may still be on. The unit travels with the
      // amount so a reader is never left to assume which one a row is in.
      money: money(num(env.totalNanoAiu), "nanoAiu")
        ?? money(num(env.totalPremiumRequestCost), "premiumRequests"),
      // `tokenDetails` is the whole session's total while `currentModel` names
      // one model, so a run that reached two of them needs the same disclosure
      // claude's does.
      modelsBilled: models.length > 1 ? models.length : undefined,
    }),
    // The measured value of this field is why it is read at all: a spawn under a
    // scratch COPILOT_HOME with no --model resolved to a full-cost model rather
    // than the cheap one, and nothing else on the machine would have said so.
    actualModel: str(env.currentModel),
    apiMs: num(env.totalApiDurationMs),
    // No error field exists anywhere in this envelope, so this is an inference
    // from a billing counter rather than a verdict the vendor stated, and it is
    // kept for the direction it errs in. It can only reject an answer, and on
    // the naming path a rejection is a retryable `failed` while its opposite —
    // a refusal short enough to pass the length checks — becomes the session's
    // name for good. The exit code remains the authority; this agrees with it
    // on every captured run.
    failed: num(env.totalUserRequests) === 0,
  };
}

function jsonLines(stdout: string): Record<string, unknown>[] {
  const out: Record<string, unknown>[] = [];
  for (const line of stdout.split("\n")) {
    const obj = parseJsonObject(line);
    if (obj) out.push(obj);
  }
  return out;
}

/**
 * The assistant's own answer inside a stdout that may be one of the envelopes
 * above, plus whether that envelope reports the run as failed. Null = not an
 * envelope, and the caller uses the text it already had.
 *
 * Vendor-agnostic because its callers are: a parser is handed a string and knows
 * what it wants out of it, never which CLI produced it — a naming call borrows
 * whichever agent is installed. It is not a fifth parser either; it tries the
 * same readers the registry declares, each identifying itself on fields measured
 * on a real run.
 *
 * The unwrap belongs at the parsers rather than at the spawn: `runHeadless`
 * returns what the process actually wrote (see `HeadlessResult.stdout`), and a
 * reconstruction handed back in its place would leave nobody able to see what
 * the CLI really said.
 */
export function unwrapEnvelope(
  stdout: string,
  // Test seam; production callers omit it. It exists so the guard below can be
  // shown to still work: every reader written so far swallows its own parse
  // errors, so nothing else could ever reach that catch.
  readers: readonly EnvelopeReader[] = ENVELOPE_READERS,
): { text: string; failed: boolean } | null {
  // Deliberately no "does this start with a brace" fast path. The readers are
  // line-oriented and skip what they cannot parse, because opencode prints
  // "! permission requested … auto-rejecting" as plain text into its own JSON
  // stream, ungated by the format flag — a leading line of that kind would
  // otherwise take a whole valid stream back to the pre-unwrap behaviour, where
  // the judge burns a retry and fail-closed escalates on an answer that was
  // correct and present. Prose still costs only a per-line brace check.
  for (const read of readers) {
    let reading: HeadlessUsageReading | null;
    try {
      reading = read(stdout);
    } catch {
      // A reader must never be the reason a title or a decision is lost.
      continue;
    }
    // The empty string, never the raw stdout: a reader that RECOGNISED the
    // envelope has already established the answer is not outside it, so falling
    // back would hand a parser the one input this function exists to keep away
    // from it — and the resulting schema error describes the wrapper, sending
    // the next person to debug it after the wrong file entirely.
    if (reading) return { text: reading.text ?? "", failed: reading.failed === true };
  }
  return null;
}

export type EnvelopeReader = (stdout: string) => HeadlessUsageReading | null;

/** The readers tried, in the order a stdout is offered to them. */
const ENVELOPE_READERS: readonly EnvelopeReader[] =
  [readClaudeCodeUsage, readCodexUsage, readOpencodeUsage];
