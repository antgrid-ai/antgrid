// bridge/tests/headless-usage.test.ts
//
// The envelopes below are VERBATIM captures from real runs of the installed
// binaries, success and failure both, and that is what makes this suite worth
// anything: a hand-written fixture would only ever prove the reader agrees with
// whoever wrote it. Only two things were touched — claude's one-line stdout is
// reproduced as the single line it is, and copilot's pretty-printed file has its
// whitespace compacted. Keys, values and nesting are as captured.
//
// The property every test here is ultimately about: an observer must never break
// the observed. A vendor that changes its envelope next month must cost the token
// counts and nothing else — not a session name, not a supervision decision.
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, writeFileSync } from "node:fs";

import { runHeadless } from "../src/agents/headless";
import { parseTitleFromOutput } from "../src/agents/title-generate";
import { parseDecisionFromOutput } from "../src/handler/decision";
import { parseExtractionOutput } from "../src/handler/extract";
import { extractJsonObject } from "../src/handler/json-extract";
import { AGENTS } from "../src/agents/registry";
import {
  readClaudeCodeUsage, readCodexUsage, readCopilotUsage, readOpencodeUsage, unwrapEnvelope,
} from "../src/agents/usage-envelope";
import {
  armContextCapture, armPromptCapture, modelwatch, __resetModelwatchForTest,
  type ModelCallContext,
} from "../src/modelwatch";
import { generateTitleFromContext } from "../src/agents/title-generate";
import { runDecision } from "../src/handler/judge";

beforeEach(() => { __resetModelwatchForTest(); });
afterEach(() => { __resetModelwatchForTest(); });

// ---------------------------------------------------------------- fixtures

/** claude-code 2.1.263, exit 0. One line of stdout, nothing else on it. */
const CLAUDE_OK = '{"duration_api_ms":2666,"stop_reason":"end_turn","session_id":"bccba315-a805-4d25-8eea-9de6057f45f0","total_cost_usd":0.081095,"usage":{"input_tokens":2,"cache_creation_input_tokens":7243,"cache_read_input_tokens":15232,"output_tokens":4,"output_tokens_details":{"thinking_tokens":0},"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":7243,"ephemeral_5m_input_tokens":0},"inference_geo":"not_available","iterations":[{"input_tokens":2,"output_tokens":4,"cache_read_input_tokens":15232,"cache_creation_input_tokens":7243,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":7243},"type":"message"}],"speed":"standard"},"modelUsage":{"claude-haiku-4-5-20251001":{"inputTokens":899,"outputTokens":8,"cacheReadInputTokens":0,"cacheCreationInputTokens":0,"webSearchRequests":0,"costUSD":0.000939,"contextWindow":200000,"maxOutputTokens":32000,"thinkingTokens":0,"canonicalModel":"claude-haiku-4-5","provider":"firstParty","costBasis":"list"},"claude-opus-5[1m]":{"inputTokens":2,"outputTokens":4,"cacheReadInputTokens":15232,"cacheCreationInputTokens":7243,"webSearchRequests":0,"costUSD":0.080156,"contextWindow":1000000,"maxOutputTokens":64000,"thinkingTokens":0,"canonicalModel":"claude-opus-5","provider":"firstParty","costBasis":"list"}},"permission_denials":[],"terminal_reason":"completed","fast_mode_state":"off","fast_mode_disabled_reason":"sdk_opt_in_required","subagent_stats":{"spawned":0,"requested":{"background":0,"foreground":0,"unset":0},"started_in_background":0,"max_depth":0,"spawned_by_subagents":0,"completed":0,"failed":0,"killed":{"parent":0,"user":0,"system":0},"refused":{"depth_limit":0,"concurrency_limit":0,"budget":0},"by_type":{}},"is_error":false,"num_turns":1,"subtype":"success","api_error_status":null,"result":"ok","ttft_ms":1754,"type":"result","duration_ms":1792,"uuid":"f3df5e66-5554-4f74-aae9-fff51bbeb40c","ttft_stream_ms":1753,"time_to_request_ms":79,"first_content_frame_ms":1753,"queued_turn_count":0}\n';

/** The same CLI, exit 1, an unrecognised model. Note the fields the success run
 *  has and this one simply does not: no ttft_ms, no timings, an empty
 *  modelUsage — and `subtype` still reading "success". */
const CLAUDE_FAIL = '{"duration_api_ms":0,"stop_reason":"stop_sequence","session_id":"53374079-a1ab-4b20-893c-7109922094d0","total_cost_usd":0,"usage":{"output_tokens_details":{"thinking_tokens":0},"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0,"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0},"inference_geo":"","iterations":[],"speed":"standard"},"modelUsage":{},"permission_denials":[],"terminal_reason":"api_error","fast_mode_state":"off","fast_mode_disabled_reason":"sdk_opt_in_required","subagent_stats":{"spawned":0,"requested":{"background":0,"foreground":0,"unset":0},"started_in_background":0,"max_depth":0,"spawned_by_subagents":0,"completed":0,"failed":0,"killed":{"parent":0,"user":0,"system":0},"refused":{"depth_limit":0,"concurrency_limit":0,"budget":0},"by_type":{}},"is_error":true,"num_turns":1,"subtype":"success","api_error_status":404,"result":"There\'s an issue with the selected model (not-a-real-model-xyz). It may not exist or you may not have access to it. Run --model to pick a different model.","type":"result","duration_ms":1067,"uuid":"d8a32e77-971f-43af-ba98-ce987990a6d4","queued_turn_count":0}\n';

/** codex-cli 0.153.4, exit 0. */
const CODEX_OK = [
  '{"type":"thread.started","thread_id":"01a07cfc-e878-74f1-bb2d-55ed6723ad94"}',
  '{"type":"turn.started"}',
  '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"ok"}}',
  '{"type":"turn.completed","usage":{"input_tokens":16666,"cached_input_tokens":12544,"cache_write_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0}}',
  "",
].join("\n");

/** The same, exit 1. No turn.completed and no usage object anywhere. The
 *  `item.completed` carrying `item.type: "error"` is a NON-fatal warning. */
const CODEX_FAIL = [
  '{"type":"thread.started","thread_id":"01a07cfd-5bc0-73c2-aef4-f77411077a68"}',
  '{"type":"item.completed","item":{"id":"item_0","type":"error","message":"Model metadata for `gpt-not-a-real-model-xyz` not found. Defaulting to fallback metadata; this can degrade performance and cause issues."}}',
  '{"type":"turn.started"}',
  '{"type":"error","message":"{\\"type\\":\\"error\\",\\"status\\":400,\\"error\\":{\\"type\\":\\"invalid_request_error\\",\\"message\\":\\"The \'gpt-not-a-real-model-xyz\' model is not supported when using Codex with a ChatGPT account.\\"}}"}',
  '{"type":"turn.failed","error":{"message":"{\\"type\\":\\"error\\",\\"status\\":400,\\"error\\":{\\"type\\":\\"invalid_request_error\\",\\"message\\":\\"The \'gpt-not-a-real-model-xyz\' model is not supported when using Codex with a ChatGPT account.\\"}}"}}',
  "",
].join("\n");

/** opencode 1.18.29, exit 0. */
const OPENCODE_OK = [
  '{"type":"step_start","timestamp":1788803733283,"sessionID":"ses_f82fd3a20ffeIA79HblKx3IICf","part":{"id":"prt_07d02d71b001yLFhnQqDWEpAZI","messageID":"msg_07d02c7c4002WXwMXAYrLzTOu4","sessionID":"ses_f82fd3a20ffeIA79HblKx3IICf","type":"step-start"}}',
  '{"type":"text","timestamp":1788803733359,"sessionID":"ses_f82fd3a20ffeIA79HblKx3IICf","part":{"id":"prt_07d02d71e001Tm3cNqHkfaQZ7Z","messageID":"msg_07d02c7c4002WXwMXAYrLzTOu4","sessionID":"ses_f82fd3a20ffeIA79HblKx3IICf","type":"text","text":"ok","time":{"start":1788803733278,"end":1788803733356},"metadata":{"openai":{"itemId":"msg_0e8fb2446baf346f016a9efa95ecbc87d0910c78f32172dbf6","phase":"final_answer"}}}}',
  '{"type":"step_finish","timestamp":1788803733453,"sessionID":"ses_f82fd3a20ffeIA79HblKx3IICf","part":{"id":"prt_07d02d7bb001HE5N981pdTfOkU","reason":"stop","messageID":"msg_07d02c7c4002WXwMXAYrLzTOu4","sessionID":"ses_f82fd3a20ffeIA79HblKx3IICf","type":"step-finish","tokens":{"total":6468,"input":6463,"output":5,"reasoning":0,"cache":{"write":0,"read":0}},"cost":0}}',
  "",
].join("\n");

/** The same, exit 1. The only line, and there is no step_finish at all. */
const OPENCODE_FAIL = '{"type":"error","timestamp":1788803763981,"sessionID":"ses_f82fcb337ffenUB26NghT6topR","error":{"name":"UnknownError","data":{"message":"Unexpected server error. Check server logs for details.","ref":"err_686d189d"}}}\n';

/** GitHub Copilot CLI 1.0.83, exit 0 — the file it was asked to write. */
const COPILOT_OK = JSON.stringify({
  totalPremiumRequestCost: 1,
  totalUserRequests: 1,
  totalNanoAiu: 273860000,
  tokenDetails: {
    input: { tokenCount: 13663 },
    cache_read: { tokenCount: 0 },
    cache_write: { tokenCount: 0 },
    output: { tokenCount: 5 },
  },
  totalApiDurationMs: 14838,
  sessionStartTime: "2026-09-07T17:49:28.170Z",
  // Adjacent to every number this reads, and a real leak risk: an array of
  // paths out of the user's own tree. Kept in the fixture precisely so the
  // no-leak test below has something to find.
  codeChanges: {
    linesAdded: 0, linesRemoved: 0, filesModifiedCount: 0,
    filesModified: ["C:/Users/someone/secret-project/src/main.ts"],
  },
  modelMetrics: {
    "mai-code-1.1-flash": {
      requests: { count: 1, cost: 1 },
      usage: {
        inputTokens: 13663, outputTokens: 5,
        cacheReadTokens: 0, cacheWriteTokens: 0, reasoningTokens: 0,
      },
      totalNanoAiu: 273860000,
      tokenDetails: {
        input: { tokenCount: 13663 }, cache_read: { tokenCount: 0 },
        cache_write: { tokenCount: 0 }, output: { tokenCount: 5 },
      },
    },
  },
  agentMetrics: { main: { totalApiDurationMs: 14838, totalNanoAiu: 273860000, modelMetrics: {} } },
  currentModel: "mai-code-1.1-flash",
  lastCallInputTokens: 13663,
  lastCallOutputTokens: 5,
}, null, 2);

/** The same CLI, exit 1, a model it refused. The file is still written, and its
 *  shape is not the success shape zeroed: `tokenDetails` and `currentModel` are
 *  absent outright. */
const COPILOT_FAIL = JSON.stringify({
  totalPremiumRequestCost: 0,
  totalUserRequests: 0,
  totalNanoAiu: 0,
  totalApiDurationMs: 0,
  sessionStartTime: "2026-09-07T17:50:29.425Z",
  codeChanges: { linesAdded: 0, linesRemoved: 0, filesModifiedCount: 0, filesModified: [] },
  modelMetrics: {},
  agentMetrics: {},
  lastCallInputTokens: 0,
  lastCallOutputTokens: 0,
}, null, 2);

// ------------------------------------------------------------- the readers

describe("claude-code's --output-format json envelope", () => {
  test("reads the answer, the model that billed it, and the cross-model totals", () => {
    const r = readClaudeCodeUsage(CLAUDE_OK)!;
    expect(r.text).toBe("ok");
    expect(r.failed).toBe(false);
    expect(r.apiMs).toBe(2666);
    // The KEYS of modelUsage are the only model names in the envelope, and this
    // trivial prompt billed two of them. The expensive one answered; the other
    // is Claude Code's own background model.
    expect(r.actualModel).toBe("claude-opus-5[1m]");
    expect(r.usage).toEqual({
      // 899 + 2. The top-level `usage.input_tokens` says 2 — it describes ONE of
      // the two models, while `total_cost_usd` is the sum of both, so taking it
      // would put a token count and a cost in one record that describe different
      // sets of API calls.
      inputTokens: 901,
      cacheReadTokens: 15232,
      cacheWriteTokens: 7243,
      outputTokens: 12,
      // Reported as a breakdown OF the output count for this vendor, so it is
      // already inside the 12 above rather than beside it.
      reasoningTokens: 0,
      // Exactly 0.000939 + 0.080156, verified against the capture.
      money: { unit: "USD", amount: 0.081095 },
      numTurns: 1,
      // The field is an ARRAY. Only its length is read.
      permissionDenials: 0,
      // The counts above are the sum over BOTH models, while `actualModel`
      // names one of them — the named model spent 2 of those 901 input tokens,
      // and this is the only thing on the record that says so.
      modelsBilled: 2,
    });
  });

  test("the failed run names no model, reports no tokens, and asserts no cost", () => {
    const r = readClaudeCodeUsage(CLAUDE_FAIL)!;
    expect(r.failed).toBe(true);
    expect(r.actualModel).toBeUndefined();
    // `modelUsage` is `{}`, so there is nothing to sum; a zero here would claim
    // the call cost nothing rather than that nothing was reported.
    expect(r.usage).toEqual({ numTurns: 1, permissionDenials: 0 });
  });

  test("`subtype` is not the failure signal — it reads success on both runs", () => {
    expect(JSON.parse(CLAUDE_FAIL).subtype).toBe("success");
    expect(readClaudeCodeUsage(CLAUDE_FAIL)!.failed).toBe(true);
  });

  // The guard that keeps a judge's own answer — also one JSON object on stdout —
  // from being read as a wrapper around itself.
  test("a plain JSON answer is not an envelope", () => {
    const decision = JSON.stringify({ decision: "continue", confidence: 0.9, reason: "ok" });
    expect(readClaudeCodeUsage(decision)).toBeNull();
    expect(readClaudeCodeUsage("Some Title Here")).toBeNull();
    expect(readClaudeCodeUsage('{"type":"result"')).toBeNull();
  });
});

describe("codex's --json stream", () => {
  test("reads the answer and the terminal turn's usage", () => {
    const r = readCodexUsage(CODEX_OK)!;
    expect(r.text).toBe("ok");
    expect(r.failed).toBe(false);
    expect(r.usage).toEqual({
      inputTokens: 16666, cacheReadTokens: 12544, cacheWriteTokens: 0, outputTokens: 5,
      // A sibling of output here, not a breakdown of it as claude's is.
      reasoningTokens: 0,
    });
    // No cost, no model and no turn count exist anywhere in this stream. They
    // stay unset rather than being derived from the event tally.
    expect(r.actualModel).toBeUndefined();
    expect(r.usage?.money).toBeUndefined();
    expect(r.usage?.numTurns).toBeUndefined();
  });

  test("a turn.failed run reports no usage and no answer", () => {
    const r = readCodexUsage(CODEX_FAIL)!;
    expect(r.failed).toBe(true);
    expect(r.usage).toBeUndefined();
    // Unset, not empty: the caller falls back to the raw output it already had.
    expect(r.text).toBeUndefined();
  });

  test("an item.completed of type error is a warning, not a failed turn", () => {
    const warned = [
      '{"type":"item.completed","item":{"id":"item_0","type":"error","message":"Model metadata not found."}}',
      '{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"ok"}}',
      '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}',
    ].join("\n");
    const r = readCodexUsage(warned)!;
    expect(r.failed).toBe(false);
    expect(r.text).toBe("ok");
  });
});

describe("opencode's --format json stream", () => {
  test("reads the answer and sums the step tokens", () => {
    const r = readOpencodeUsage(OPENCODE_OK)!;
    expect(r.text).toBe("ok");
    expect(r.failed).toBe(false);
    expect(r.usage).toEqual({
      inputTokens: 6463, cacheReadTokens: 0, cacheWriteTokens: 0, outputTokens: 5,
      reasoningTokens: 0,
    });
  });

  // The two omissions that are the point of this reader, not gaps in it: `cost`
  // is 0 for a call that spent 6463 input tokens (an OAuth provider with no
  // price metadata), and the shipped binary suppresses the model banner whenever
  // the format is json.
  test("reports no cost and no model, because neither is in the stream", () => {
    const r = readOpencodeUsage(OPENCODE_OK)!;
    expect(r.usage?.money).toBeUndefined();
    expect(r.actualModel).toBeUndefined();
  });

  test("usage is summed across every step_finish, since nothing aggregates them", () => {
    const twoSteps = OPENCODE_OK + OPENCODE_OK.split("\n").filter(Boolean)[2] + "\n";
    expect(readOpencodeUsage(twoSteps)!.usage).toEqual({
      inputTokens: 12926, cacheReadTokens: 0, cacheWriteTokens: 0, outputTokens: 10,
      reasoningTokens: 0,
    });
  });

  // A permission ask with no --auto prints plain text into this stream, ungated
  // by the format flag, so the stream is not guaranteed to be pure JSONL.
  test("a plain-text line interleaved into the stream is skipped, not fatal", () => {
    const lines = OPENCODE_OK.split("\n");
    const withNoise = [
      lines[0], "! permission requested: edit (**); auto-rejecting", ...lines.slice(1),
    ].join("\n");
    expect(readOpencodeUsage(withNoise)!.usage).toEqual(readOpencodeUsage(OPENCODE_OK)!.usage);
  });

  test("an error line is the failure, and it carries no usage", () => {
    const r = readOpencodeUsage(OPENCODE_FAIL)!;
    expect(r.failed).toBe(true);
    expect(r.usage).toBeUndefined();
    expect(r.text).toBeUndefined();
  });
});

describe("github-copilot's --usage-output-file", () => {
  test("reads the tokens, the credit cost with its unit, and the model that ran", () => {
    const r = readCopilotUsage(COPILOT_OK)!;
    expect(r.failed).toBe(false);
    expect(r.apiMs).toBe(14838);
    // Measured under a scratch COPILOT_HOME with no --model: the run resolved to
    // a full-cost model, which nothing else on the machine would have reported.
    expect(r.actualModel).toBe("mai-code-1.1-flash");
    expect(r.usage).toEqual({
      inputTokens: 13663, cacheReadTokens: 0, cacheWriteTokens: 0, outputTokens: 5,
      // Summed out of each model's own block; one model ran, so no
      // `modelsBilled` disclosure is needed on this row.
      reasoningTokens: 0,
      // Nano AI credits, not premium requests. Both are present and they are
      // different currencies, so the unit travels with the amount.
      money: { unit: "nanoAiu", amount: 273860000 },
    });
    // Never derived from totalUserRequests (always 1 for a -p spawn) or from the
    // API-call count, which is not a turn count.
    expect(r.usage?.numTurns).toBeUndefined();
    expect(r.usage?.permissionDenials).toBeUndefined();
  });

  test("the failed run's envelope drops keys rather than zeroing them", () => {
    const r = readCopilotUsage(COPILOT_FAIL)!;
    expect(r.failed).toBe(true);
    expect(r.usage).toBeUndefined();
    expect(r.actualModel).toBeUndefined();
  });

  // `codeChanges.filesModified` sits one key away from every number this reads.
  // Fields are extracted by name for exactly this reason — the log's allow-list
  // guards the file, and nothing guards the in-memory ring.
  test("nothing but the named fields comes out — no working-tree paths", () => {
    const r = readCopilotUsage(COPILOT_OK)!;
    expect(JSON.stringify(r)).not.toContain("secret-project");
    expect(JSON.stringify(r)).not.toContain("filesModified");
  });
});

// ---------------------------------------------------- the existing parsers

describe("the output parsers under an envelope", () => {
  const TITLE = "Add usage capture";
  const DECISION = { decision: "continue", confidence: 0.9, reason: "the agent is working" };

  /** The envelope a vendor would produce for `answer`, per vendor. */
  const wrapped = {
    "claude-code": (answer: string) =>
      JSON.stringify({ type: "result", is_error: false, result: answer, modelUsage: {} }),
    codex: (answer: string) => [
      '{"type":"thread.started","thread_id":"t1"}',
      JSON.stringify({ type: "item.completed", item: { id: "i0", type: "agent_message", text: answer } }),
      '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}',
    ].join("\n"),
    opencode: (answer: string) => [
      '{"type":"step_start","timestamp":1,"sessionID":"ses_1","part":{"type":"step-start"}}',
      JSON.stringify({ type: "text", timestamp: 2, sessionID: "ses_1", part: { type: "text", text: answer } }),
      '{"type":"step_finish","timestamp":3,"sessionID":"ses_1","part":{"type":"step-finish","tokens":{"input":1,"output":1,"cache":{"read":0,"write":0}},"cost":0}}',
    ].join("\n"),
  };

  for (const [vendor, wrap] of Object.entries(wrapped)) {
    test(`a ${vendor} envelope still yields a title`, () => {
      expect(parseTitleFromOutput(wrap(TITLE))).toBe(TITLE);
    });

    // The worse of the two breaks: the envelope is itself a parseable object, so
    // a scan for the first `{…}` returns it, the schema rejects it, and the
    // judge burns its retry and fail-closed escalates on a correct answer.
    test(`a ${vendor} envelope still yields a decision`, () => {
      const out = parseDecisionFromOutput(wrap(JSON.stringify(DECISION)));
      expect(out.decision).toEqual(DECISION as never);
      expect(out.error).toBeUndefined();
    });

    test(`a ${vendor} envelope still yields an extraction`, () => {
      const items = JSON.stringify({ items: [{ ref: "r1", text: "run the tests" }] });
      expect(parseExtractionOutput(wrap(items)).items).toHaveLength(1);
    });
  }

  // The heuristic becoming a check. Without it a refusal short enough to pass
  // for a title becomes the session's name for good.
  test("a failed claude envelope is never read as a title, however short it is", () => {
    const refusal = JSON.stringify({
      type: "result", is_error: true, result: "Invalid API key", modelUsage: {},
    });
    // Six words and inside every length bound — this is the whole hazard.
    expect(parseTitleFromOutput(JSON.stringify({
      type: "result", is_error: false, result: "Invalid API key", modelUsage: {},
    }))).toBe("Invalid API key");
    expect(parseTitleFromOutput(refusal)).toBeNull();
  });

  test("the real captured envelopes carry their answers through", () => {
    expect(parseTitleFromOutput(CLAUDE_OK)).toBe("ok");
    expect(parseTitleFromOutput(CODEX_OK)).toBe("ok");
    expect(parseTitleFromOutput(OPENCODE_OK)).toBe("ok");
    // Every failed capture: no title, by the envelope's own verdict.
    expect(parseTitleFromOutput(CLAUDE_FAIL)).toBeNull();
    expect(parseTitleFromOutput(CODEX_FAIL)).toBeNull();
    expect(parseTitleFromOutput(OPENCODE_FAIL)).toBeNull();
  });

  // The other half of the contract, and the one a regression would be silent
  // about: nothing about the plain-text path may have moved.
  describe("plain text is untouched", () => {
    test("a title still comes off the last non-empty line", () => {
      expect(parseTitleFromOutput("banner\nAdd usage capture\n")).toBe("Add usage capture");
      expect(parseTitleFromOutput('  "Add usage capture."  ')).toBe("Add usage capture");
      expect(parseTitleFromOutput("Title: Add usage capture")).toBe("Add usage capture");
      expect(parseTitleFromOutput("")).toBeNull();
      expect(parseTitleFromOutput("a ".repeat(40))).toBeNull();
    });

    test("a decision is still found inside prose", () => {
      const out = parseDecisionFromOutput(`Here you go: ${JSON.stringify(DECISION)} — hope that helps!`);
      expect(out.decision).toEqual(DECISION as never);
    });

    // Bare JSON starting with `{` takes the envelope path far enough to attempt
    // a parse, and must come out the other side identical.
    test("a bare JSON answer parses exactly as before", () => {
      expect(parseDecisionFromOutput(JSON.stringify(DECISION)).decision).toEqual(DECISION as never);
      expect(parseDecisionFromOutput("{not json").error).toBe("no JSON object found in output");
    });
  });

  describe("a malformed envelope costs the numbers and nothing else", () => {
    // Truncated mid-object: the exact shape a killed process leaves behind.
    const truncated = CLAUDE_OK.slice(0, 400);
    // The shape changed under us — same flag, keys we have never seen.
    const drifted = '{"type":"result","outcome":{"answer":"Add usage capture"},"tally":{"in":5}}';

    test("a truncated envelope falls back to the raw output", () => {
      expect(unwrapEnvelope(truncated)).toBeNull();
      expect(readClaudeCodeUsage(truncated)).toBeNull();
      // The raw line is far past the title bound, so naming reports failed
      // rather than naming a session after a JSON fragment.
      expect(parseTitleFromOutput(truncated)).toBeNull();
    });

    test("an envelope in an unmeasured shape yields no usage and changes no parse", () => {
      expect(readClaudeCodeUsage(drifted)?.usage).toBeUndefined();
      // Not recognised as an envelope, so the scan runs on the raw text and
      // reaches exactly the object it would have reached before any of this
      // existed — here the drifted object itself, under the unchanged
      // first-balanced-object rule.
      const answer = `${drifted} ${JSON.stringify(DECISION)}`;
      expect(extractJsonObject(answer)).toEqual(JSON.parse(drifted));
      expect(parseDecisionFromOutput(answer).decision).toBeNull();
    });
  });
});

// ---------------------------------------------------------- the spawn path

describe("runHeadless with a usage descriptor", () => {
  /** Replays one stdout, recording the argv it was spawned with. A `writeFile`
   *  step stands in for the vendor writing its own side file. */
  function stubSpawn(opts: { stdout: string; sideFile?: string; exitCode?: number }) {
    const calls: string[][] = [];
    const spawn = ((cmd: string[]) => {
      calls.push(cmd);
      const at = cmd.indexOf("--usage-output-file");
      if (opts.sideFile !== undefined && at !== -1) writeFileSync(cmd[at + 1]!, opts.sideFile, "utf8");
      return {
        stdout: new Response(opts.stdout).body,
        exited: Promise.resolve(opts.exitCode ?? 0),
        kill() { /* nothing to kill */ },
      };
    }) as unknown as typeof Bun.spawn;
    return { spawn, calls };
  }

  const call = (over: Partial<ModelCallContext> = {}): ModelCallContext => ({
    callId: "call-1", purpose: "title", attempt: 1,
    requestedTool: "claude-code", actualTool: "claude-code", reach: "readonly",
    ...over,
  });
  const endEvent = () => modelwatch.snapshot().find((e) => e.phase === "end");

  const claude = AGENTS["claude-code"].headless!.readonly!;
  const codex = AGENTS.codex.headless!.readonly!;
  const opencode = AGENTS.opencode.headless!.transcript!;
  const copilot = AGENTS["github-copilot"].headless!.readonly!;

  const run = (
    command: typeof claude, stdout: string,
    over: { sideFile?: string; usage?: typeof claude.usage } = {},
  ) => {
    const { spawn, calls } = stubSpawn({ stdout, sideFile: over.sideFile });
    return runHeadless(command.cmd("name this", undefined), {
      cwd: process.cwd(), timeoutMs: 5_000, spawn,
      env: command.env, scratchEnv: command.scratchEnv,
      usage: "usage" in over ? over.usage : command.usage,
      call: call(),
    }).then((result) => ({ result, argv: calls[0]! }));
  };

  // The positions are part of what was verified, not a detail: claude's prompt
  // must stay ahead of the variadic --allowedTools, and codex and opencode take
  // their prompt as the last element, so a flag appended past it is an argv
  // nobody has ever run.
  test("each vendor's flag lands where the run that measured it put it", async () => {
    expect((await run(claude, CLAUDE_OK)).argv.slice(-2)).toEqual(["--output-format", "json"]);
    const codexArgv = (await run(codex, CODEX_OK)).argv;
    expect(codexArgv.slice(-2)).toEqual(["--json", "name this"]);
    const opencodeArgv = (await run(opencode, OPENCODE_OK)).argv;
    expect(opencodeArgv.slice(-3)).toEqual(["--format", "json", "name this"]);
    // Copilot's is a side channel: a path we pick, and stdout untouched.
    expect((await run(copilot, "ok\n", { sideFile: COPILOT_OK })).argv.slice(-2)[0])
      .toBe("--usage-output-file");
  });

  test("the numbers reach the result and the record", async () => {
    const { result } = await run(claude, CLAUDE_OK);
    expect(result!.stdout).toBe(CLAUDE_OK);
    expect(result!.usage?.inputTokens).toBe(901);
    expect(result!.actualModel).toBe("claude-opus-5[1m]");
    expect(endEvent()!.usage?.outputTokens).toBe(12);
    expect(endEvent()!.actualModel).toBe("claude-opus-5[1m]");
    expect(endEvent()!.apiMs).toBe(2666);
  });

  // The channel, not the answer: what the process wrote is what the record
  // measures and what the caller is handed, so nobody is ever reading our
  // reconstruction of a CLI's output instead of the output.
  test("stdout comes back verbatim, envelope and all", async () => {
    const { result } = await run(codex, CODEX_OK);
    expect(result!.stdout).toBe(CODEX_OK);
    expect(endEvent()!.stdoutChars).toBe(CODEX_OK.length);
  });

  test("a side file is read, then removed", async () => {
    const { result, argv } = await run(copilot, "ok\n", { sideFile: COPILOT_OK });
    expect(result!.stdout).toBe("ok\n");
    expect(result!.usage?.inputTokens).toBe(13663);
    expect(result!.actualModel).toBe("mai-code-1.1-flash");
    expect(existsSync(argv[argv.indexOf("--usage-output-file") + 1]!)).toBe(false);
  });

  test("each spawn gets its own side file, so two in flight cannot cross", async () => {
    const a = await run(copilot, "ok\n", { sideFile: COPILOT_OK });
    const b = await run(copilot, "ok\n", { sideFile: COPILOT_OK });
    const pathOf = (argv: string[]) => argv[argv.indexOf("--usage-output-file") + 1];
    expect(pathOf(a.argv)).not.toBe(pathOf(b.argv));
  });

  // Everything below is the same property from a different direction: the call
  // survives, with its stdout, and only the numbers are lost.
  test("a side file the CLI never wrote is as harmless as an unparseable one", async () => {
    const { result } = await run(copilot, "ok\n"); // no sideFile: nothing is written
    expect(result!.stdout).toBe("ok\n");
    expect(result!.usage).toBeUndefined();
    expect(parseTitleFromOutput(result!.stdout)).toBe("ok");
  });

  test("a side file holding junk is as harmless as a missing one", async () => {
    const { result } = await run(copilot, "ok\n", { sideFile: "not json at all" });
    expect(result!.usage).toBeUndefined();
    expect(result!.stdout).toBe("ok\n");
  });

  test("an envelope in a shape nobody measured costs the numbers only", async () => {
    const drifted = '{"type":"result","answer":"ok","tally":{"in":5}}\n';
    const { result } = await run(claude, drifted);
    expect(result!.stdout).toBe(drifted);
    expect(result!.usage).toBeUndefined();
    expect(endEvent()!.usage).toBeUndefined();
    expect(endEvent()!.stdoutChars).toBe(drifted.length);
  });

  test("a reader that throws does not fail the call", async () => {
    const { result } = await run(claude, CLAUDE_OK, {
      usage: {
        from: "stdout",
        argv: (cmd) => [...cmd],
        read: () => { throw new Error("reader is broken"); },
      },
    });
    expect(result!.stdout).toBe(CLAUDE_OK);
    expect(result!.usage).toBeUndefined();
  });

  test("an argv builder that throws leaves the command exactly as it was", async () => {
    const { spawn, calls } = stubSpawn({ stdout: CLAUDE_OK });
    const cmd = claude.cmd("name this", undefined);
    const result = await runHeadless(cmd, {
      cwd: process.cwd(), timeoutMs: 5_000, spawn,
      usage: {
        from: "stdout",
        argv: () => { throw new Error("argv builder is broken"); },
        read: readClaudeCodeUsage,
      },
    });
    expect(calls[0]).toEqual(cmd);
    expect(result!.stdout).toBe(CLAUDE_OK);
  });

  // The sibling of the throwing builder above, and the failure the guard names:
  // an empty argv spawns nothing at all, so a descriptor that returns one has to
  // cost the numbers rather than the call.
  test("an argv builder that returns nothing leaves the command exactly as it was", async () => {
    const { spawn, calls } = stubSpawn({ stdout: CLAUDE_OK });
    const cmd = claude.cmd("name this", undefined);
    const result = await runHeadless(cmd, {
      cwd: process.cwd(), timeoutMs: 5_000, spawn,
      usage: { from: "stdout", argv: () => [], read: readClaudeCodeUsage },
    });
    expect(calls[0]).toEqual(cmd);
    expect(result!.stdout).toBe(CLAUDE_OK);
  });

  // The default, and what every vendor with no descriptor gets: today's argv,
  // today's stdout, a record with timings and no numbers.
  test("a command with no descriptor is spawned and recorded exactly as before", async () => {
    const { result, argv } = await run(claude, "Add usage capture\n", { usage: undefined });
    expect(argv).toEqual(claude.cmd("name this", undefined));
    expect(result!.usage).toBeUndefined();
    expect(result!.actualModel).toBeUndefined();
    expect(result!.vendorFailed).toBeUndefined();
    expect(endEvent()!.usage).toBeUndefined();
    expect(endEvent()!.wallMs).toBeGreaterThanOrEqual(0);
    expect(parseTitleFromOutput(result!.stdout)).toBe("Add usage capture");
  });

  // The switch a user whose vendor moved underneath them can reach without a
  // new build: a CLI that does not recognise its own flag exits before it ever
  // reads the prompt, and no reader can parse its way out of that.
  test("ANTGRID_MODELWATCH_USAGE=0 restores the argv the CLI had before any of this", async () => {
    const prior = process.env.ANTGRID_MODELWATCH_USAGE;
    process.env.ANTGRID_MODELWATCH_USAGE = "0";
    try {
      const { result, argv } = await run(claude, CLAUDE_OK);
      expect(argv).toEqual(claude.cmd("name this", undefined));
      expect(result!.usage).toBeUndefined();
    } finally {
      if (prior === undefined) delete process.env.ANTGRID_MODELWATCH_USAGE;
      else process.env.ANTGRID_MODELWATCH_USAGE = prior;
    }
  });

  test("the vendor's own failure verdict reaches the caller", async () => {
    const { result } = await run(claude, CLAUDE_FAIL);
    expect(result!.vendorFailed).toBe(true);
    // The refusal text is on stdout as always; naming rejects it on the verdict.
    expect(parseTitleFromOutput(result!.stdout)).toBeNull();
  });

  // The prompt is an element of the argv, and it never reaches the ring.
  test("the argv is still never recorded", async () => {
    await run(claude, CLAUDE_OK);
    expect(JSON.stringify(modelwatch.snapshot())).not.toContain("name this");
  });
});

// -------------------------------------------------- verdicts that may not veto

describe("a failure verdict is what the vendor stated, not what a reader missed", () => {
  const codexStream = (terminal: string) => [
    '{"type":"thread.started","thread_id":"t1"}',
    '{"type":"turn.started"}',
    '{"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"Add usage capture"}}',
    terminal,
  ].filter(Boolean).join("\n");

  // The answer arrives on its own line, so a terminal event this reader has
  // never seen must cost the token counts and not the answer already read off
  // the stream — the exit code still speaks for the run.
  test("a codex terminal event nobody has seen before does not veto the answer", () => {
    const renamed = codexStream('{"type":"turn.finished","usage":{"input_tokens":10,"output_tokens":2}}');
    expect(readCodexUsage(renamed)!.failed).toBe(false);
    expect(readCodexUsage(renamed)!.usage).toBeUndefined();
    expect(parseTitleFromOutput(renamed)).toBe("Add usage capture");
    // Same for a stream that ended before any terminal event at all.
    expect(parseTitleFromOutput(codexStream(""))).toBe("Add usage capture");
  });

  test("a codex failure the stream states IS honoured", () => {
    expect(parseTitleFromOutput(codexStream('{"type":"turn.failed","error":{"message":"nope"}}'))).toBeNull();
    // The top-level error line that precedes turn.failed makes the same claim.
    expect(parseTitleFromOutput(codexStream('{"type":"error","message":"nope"}'))).toBeNull();
  });
});

describe("an envelope the readers recognise but that carries no answer", () => {
  // `reading.text ?? stdout` would hand the parsers the wrapper here, which is
  // the one input the unwrapper exists to keep away from them: the schema error
  // then describes the envelope and sends the next debugger after the wrong file.
  test("yields nothing to parse rather than the envelope itself", () => {
    const claudeEmpty = JSON.stringify({ type: "result", is_error: false, result: "", modelUsage: {} });
    expect(unwrapEnvelope(claudeEmpty)!.text).toBe("");
    expect(parseDecisionFromOutput(claudeEmpty).error).toBe("no JSON object found in output");

    const codexNoMessage = [
      '{"type":"thread.started","thread_id":"t1"}',
      '{"type":"item.completed","item":{"id":"i0","type":"reasoning","text":"thinking"}}',
      '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}',
    ].join("\n");
    expect(unwrapEnvelope(codexNoMessage)!.text).toBe("");
    expect(parseDecisionFromOutput(codexNoMessage).error).toBe("no JSON object found in output");
  });
});

describe("a stream that does not open with a brace", () => {
  const opencodeStream = (answer: string) => [
    '{"type":"step_start","timestamp":1,"sessionID":"ses_1","part":{"type":"step-start"}}',
    JSON.stringify({ type: "text", timestamp: 2, sessionID: "ses_1", part: { type: "text", text: answer } }),
    '{"type":"step_finish","timestamp":3,"sessionID":"ses_1","part":{"type":"step-finish","tokens":{"input":7,"output":2,"reasoning":0,"cache":{"read":0,"write":0}},"cost":0}}',
  ].join("\n");
  // opencode writes this line itself, as plain text, into its own JSON stream —
  // the shipped binary's permission handler is not gated on the format flag.
  const noisy = (stream: string) => `! permission requested: edit (**); auto-rejecting\n${stream}`;

  test("costs neither the title nor the decision", () => {
    const decision = { decision: "continue", confidence: 0.9, reason: "the agent is working" };
    expect(parseTitleFromOutput(noisy(opencodeStream("Add usage capture")))).toBe("Add usage capture");
    const out = parseDecisionFromOutput(noisy(opencodeStream(JSON.stringify(decision))));
    expect(out.decision).toEqual(decision as never);
    expect(out.error).toBeUndefined();
    // The observation itself was never in doubt — the readers skip what they
    // cannot parse. It was the observed that a whole-stdout brace check broke.
    expect(readOpencodeUsage(noisy(opencodeStream("x")))!.usage?.inputTokens).toBe(7);
  });
});

describe("unwrapEnvelope's reader guard", () => {
  // Every reader written so far swallows its own parse errors, so nothing that
  // exists today can reach that catch. The guard is for the reader nobody has
  // written yet, and this is the only way to show it still works.
  test("skips a reader that throws instead of losing the answer", () => {
    const boom = () => { throw new Error("reader is broken"); };
    expect(unwrapEnvelope(CLAUDE_OK, [boom, readClaudeCodeUsage])).toEqual({ text: "ok", failed: false });
  });
});

// SYNTHETIC, and labelled so it is never mistaken for a capture: every real
// envelope except claude's reported zero cache traffic, so nothing above can
// tell a cache read from a cache write. They are separately priced — creating an
// entry costs more per token than reading one — so the two are not interchangeable.
describe("cache reads and writes land in the fields they are labelled with (synthetic)", () => {
  test("codex", () => {
    const r = readCodexUsage([
      '{"type":"thread.started","thread_id":"t1"}',
      '{"type":"turn.completed","usage":{"input_tokens":5,"cached_input_tokens":11,"cache_write_input_tokens":22,"output_tokens":3,"reasoning_output_tokens":44}}',
    ].join("\n"))!;
    expect(r.usage).toEqual({
      inputTokens: 5, cacheReadTokens: 11, cacheWriteTokens: 22, outputTokens: 3,
      // Reported beside output for this vendor, so it is spend the `out` cell
      // does not contain.
      reasoningTokens: 44,
    });
  });

  test("opencode", () => {
    const r = readOpencodeUsage(
      '{"type":"step_finish","timestamp":1,"sessionID":"ses_1","part":{"type":"step-finish","tokens":{"input":5,"output":3,"reasoning":44,"cache":{"read":11,"write":22}},"cost":0}}',
    )!;
    expect(r.usage).toEqual({
      inputTokens: 5, cacheReadTokens: 11, cacheWriteTokens: 22, outputTokens: 3, reasoningTokens: 44,
    });
  });

  test("github-copilot", () => {
    const r = readCopilotUsage(JSON.stringify({
      totalUserRequests: 1,
      tokenDetails: {
        input: { tokenCount: 5 }, cache_read: { tokenCount: 11 },
        cache_write: { tokenCount: 22 }, output: { tokenCount: 3 },
      },
      modelMetrics: {
        "model-a": { usage: { reasoningTokens: 40 } },
        "model-b": { usage: { reasoningTokens: 4 } },
      },
    }))!;
    expect(r.usage).toEqual({
      inputTokens: 5, cacheReadTokens: 11, cacheWriteTokens: 22, outputTokens: 3,
      reasoningTokens: 44,
      // Two models against one `tokenDetails` block and one `currentModel`: the
      // same disclosure claude's cross-model sum needs.
      modelsBilled: 2,
    });
  });

  test("claude-code", () => {
    const r = readClaudeCodeUsage(JSON.stringify({
      type: "result", is_error: false, result: "ok",
      modelUsage: {
        "model-a": {
          inputTokens: 5, cacheReadInputTokens: 11, cacheCreationInputTokens: 22,
          outputTokens: 3, thinkingTokens: 2, costUSD: 0.5,
        },
      },
    }))!;
    expect(r.usage).toMatchObject({
      inputTokens: 5, cacheReadTokens: 11, cacheWriteTokens: 22, outputTokens: 3,
      // Inside the 3 above, not beside it: this vendor reports thinking as a
      // breakdown of its output count.
      reasoningTokens: 2,
    });
    // One model, so there is no disclosure to make.
    expect(r.usage?.modelsBilled).toBeUndefined();
  });
});

// ------------------------------------------- the callers that spend the calls

describe("the production call sites ask for the numbers", () => {
  /** Replays one stdout per spawn, recording every argv. */
  function replay(outputs: string[], sideFile?: string) {
    const calls: string[][] = [];
    const spawn = ((cmd: string[]) => {
      calls.push(cmd);
      const at = cmd.indexOf("--usage-output-file");
      if (sideFile !== undefined && at !== -1) writeFileSync(cmd[at + 1]!, sideFile, "utf8");
      const out = outputs[Math.min(calls.length - 1, outputs.length - 1)]!;
      return { stdout: new Response(out).body, exited: Promise.resolve(0), kill() { /* nothing to kill */ } };
    }) as unknown as typeof Bun.spawn;
    return { spawn, calls };
  }

  const claudeEnvelope = (result: string, inputTokens: number) => JSON.stringify({
    type: "result", is_error: false, result, total_cost_usd: 0.01,
    modelUsage: { "claude-opus-5": { inputTokens, outputTokens: 1, costUSD: 0.01 } },
  });

  const ends = () => modelwatch.snapshot().filter((e) => e.phase === "end");

  // One line in each of the two call sites, and nothing else on the machine
  // would report it missing: the flag simply stops being asked for and every row
  // goes back to timings with no numbers.
  test("a naming call carries claude's flag and records what the call billed", async () => {
    const { spawn, calls } = replay([claudeEnvelope("Add usage capture", 901)]);
    const gen = await generateTitleFromContext("do the thing", {
      tool: "claude-code", spawn, installedTools: ["claude-code"],
    });
    expect(gen).toMatchObject({ ok: true, title: "Add usage capture" });
    expect(calls[0]!.slice(-2)).toEqual(["--output-format", "json"]);
    expect(ends()[0]!.usage?.inputTokens).toBe(901);
    expect(ends()[0]!.actualModel).toBe("claude-opus-5");
  });

  test("a naming call points github-copilot at a side file without touching its stdout", async () => {
    const { spawn, calls } = replay(["Add usage capture\n"], COPILOT_OK);
    const gen = await generateTitleFromContext("do the thing", {
      tool: "github-copilot", spawn, installedTools: ["github-copilot"],
    });
    expect(gen).toMatchObject({ ok: true, title: "Add usage capture" });
    expect(calls[0]).toContain("--usage-output-file");
    expect(ends()[0]!.usage?.inputTokens).toBe(13663);
    expect(ends()[0]!.actualModel).toBe("mai-code-1.1-flash");
  });

  // The only path by which a side-file verdict can reach a naming decision:
  // copilot's stdout is byte-identical with the flag and without it, so the
  // parser never sees a verdict and `HeadlessResult.vendorFailed` is the whole
  // of the check. Kept for the direction it errs in — a rejected title is a
  // retryable `failed`, while a refusal accepted as a title outranks the
  // first-message name and is the session's name for good.
  test("a copilot usage file reporting no billed request rejects the title on its stdout", async () => {
    const { spawn } = replay(["Add usage capture\n"], COPILOT_FAIL);
    const gen = await generateTitleFromContext("do the thing", {
      tool: "github-copilot", spawn, installedTools: ["github-copilot"],
    });
    expect(gen).toMatchObject({ ok: false, reason: "failed", actualTool: "github-copilot" });
  });

  test("the judge carries the flag, and each attempt records its OWN numbers", async () => {
    const decision = { decision: "continue", confidence: 0.9, reason: "the agent is working" };
    const { spawn, calls } = replay([
      claudeEnvelope("not a decision at all", 11),
      claudeEnvelope(JSON.stringify(decision), 22),
    ]);
    const d = await runDecision({
      tool: "claude-code", goal: "migrate the auth module", backlogText: "",
      context: "C", cwd: ".", spawn,
    });
    expect(d?.decision).toBe("continue");
    expect(calls[0]!.slice(-2)).toEqual(["--output-format", "json"]);
    // A retry that inherited the first attempt's numbers would make the pair
    // read as one call costing twice what it did.
    expect(ends().map((e) => e.usage?.inputTokens)).toEqual([11, 22]);
  });
});

describe("what the capture arms hold once a flag rewrites stdout", () => {
  test("the ring holds the answer under `answer`, and the count still measures the channel", async () => {
    armPromptCapture(true, 60_000);
    armContextCapture(true, 60_000);
    const spawn = (() => ({
      stdout: new Response(CLAUDE_OK).body,
      exited: Promise.resolve(0),
      kill() { /* nothing to kill */ },
    })) as unknown as typeof Bun.spawn;
    const command = AGENTS["claude-code"].headless!.readonly!;
    const result = await runHeadless(command.cmd("name this", undefined), {
      cwd: process.cwd(), timeoutMs: 5_000, spawn, usage: command.usage,
      call: {
        callId: "call-1", purpose: "title", attempt: 1,
        requestedTool: "claude-code", actualTool: "claude-code", reach: "readonly",
      },
    });
    const end = modelwatch.snapshot().find((e) => e.phase === "end")!;
    // Not the 2000-character envelope: `antgrid calls` prints this field under a
    // column labelled "answer", and the reply itself would have been pushed past
    // the capture cap by the vendor's session ids and per-model tallies.
    expect(end.stdout).toBe("ok");
    expect(end.stdoutChars).toBe(CLAUDE_OK.length);
    // And the caller is still handed exactly what the process wrote.
    expect(result!.stdout).toBe(CLAUDE_OK);
  });
});
