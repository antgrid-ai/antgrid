// The calls tab added to the capture viewer's one document. What the server
// side does for /modelwatch and modelwatch:arm is already pinned in
// modelwatch-arm.test.ts; this file is about the PAGE — that it offers no way
// to ask for the context arm, that it reads the second feed independently of
// the first, and that the pure folding/formatting logic a malformed or
// merely-absent field runs through cannot throw. Rendering itself needs a DOM
// this suite does not have, so nothing here paints a row — see the bottom
// describe block for exactly which functions are exercised directly instead,
// and why that is the honest substitute rather than skipped coverage.
import { describe, expect, it } from "bun:test";
import { netwatchUiPage } from "../src/netwatch-ui-page";

const NONCE = "deadbeefdeadbeef";

function pageHtml(): string {
  return netwatchUiPage(NONCE).html;
}

function script(): string {
  const html = pageHtml();
  const open = `<script nonce="${NONCE}">`;
  const from = html.indexOf(open);
  expect(from).toBeGreaterThan(-1);
  const to = html.indexOf("</" + "script>", from);
  return html.slice(from + open.length, to);
}

describe("the calls tab, statically", () => {
  it("still ships a script that parses and puts nothing on the page as markup", () => {
    // Restated here rather than trusted to the other file: this suite edits the
    // same PAGE constant, and a regression that broke these two would be this
    // file's to catch just as much as netwatch-ui.test.ts's.
    const body = script();
    expect(() => new Function(body)).not.toThrow();
    for (const escape of ["innerHTML", "outerHTML", "insertAdjacentHTML", "document.write"]) {
      expect(body).not.toContain(escape);
    }
  });

  it("is one document with a tab, not a second page", () => {
    const html = pageHtml();
    expect(html).toContain('id="feedtabs"');
    expect(html).toContain('id="nwPane"');
    expect(html).toContain('id="mcPane"');
    // Exactly one <script> and one <style>: a second document would need its
    // own, and the CSP only nonces the two this page already has.
    expect((html.match(/<script /g) ?? []).length).toBe(1);
    expect((html.match(/<style /g) ?? []).length).toBe(1);
  });

  it("reads /modelwatch, independently of the netwatch stream", () => {
    const body = script();
    expect(body).toContain('"/modelwatch?');
    expect(body).toContain('"/netwatch?');
    // Two reconnect loops, not one shared: mcRun/mcReadStream must exist as
    // their own functions rather than a parameterised call into run/readStream,
    // because a stall in one must never pause the other.
    expect(body).toContain("function mcReadStream(");
    expect(body).toContain("function mcRun(");
    expect(body).toContain("function readStream(");
    expect(body).toContain("function run(");
  });

  it("never asks for the context arm", () => {
    const body = script();
    // The one request shape the calls tab is allowed to build. If a future
    // edit ever adds a context toggle, this is the line that has to change —
    // and this test is what makes that change visible.
    const armsLiterals = body.match(/arms:\s*\[[^\]]*\]/g) ?? [];
    expect(armsLiterals.length).toBeGreaterThan(0);
    for (const literal of armsLiterals) {
      expect(literal.replace(/\s/g, "")).toBe('arms:["prompts"]');
    }
    // No control anywhere in the markup offers it either.
    const html = pageHtml();
    expect(html).not.toContain('id="mccontext"');
    expect(html).not.toMatch(/data-p="context"/);
  });

  it("names the CLI-only refusal in words an operator reads, not just a code", () => {
    const body = script();
    expect(body).toContain("CONTEXT_ARM_FORBIDDEN");
    // The failure path must produce a sentence, not just forward the host's
    // message unlabeled — see mcToggleArm's special case.
    expect(body).toContain("prompts capture is unavailable");
    // The proactive note shown while armed says the same boundary up front.
    expect(body).toContain("cannot be armed from this page");
  });

  it("carries an attempt-joins-by-callId comment trail, not a callId column", () => {
    // callId is the join key, not a rendered column — showing it again would
    // just repeat the grouping the attempt marker already carries.
    const body = script();
    expect(body).toContain("function mcAttemptKey(");
    expect(body).toContain("function mcFoldInto(");
    expect(body).toContain("function mcFoldAll(");
  });

  it("launches both reconnect loops from boot without awaiting either", () => {
    // The string checks above prove only that the two loops exist, not that
    // boot() actually races them: `await run(); mcRun();` contains every
    // string they look for, and would leave the calls tab permanently dead
    // behind netwatch's endless reconnect loop.
    const body = script();
    const bootStart = body.indexOf("(async function boot(){");
    expect(bootStart).toBeGreaterThan(-1);
    const boot = body.slice(bootStart);
    expect(boot).toMatch(/\brun\(\);\s*\n\s*mcRun\(\);/);
    expect(boot).not.toContain("await run()");
    expect(boot).not.toContain("await mcRun()");
  });

  it("marks prompts capture as a hazard toggle like netwatch's own bodies arm", () => {
    const html = pageHtml();
    expect(html).toMatch(/<button class="tog warn" id="mcprompts"/);
  });

  it("discloses the CLI-only transcript/answer boundary before anything is armed, not only after", () => {
    // The viewer who most needs this boundary is the one deciding whether to
    // arm anything, so it cannot be text that only mcSetArm(on) writes: a
    // #mcnote shipped hidden and empty says nothing to someone who never
    // touches the toggle.
    const html = pageHtml();
    expect(html).not.toMatch(/<div id="mcnote"[^>]*hidden/);
    const body = script();
    expect(body).toMatch(/mcNoteEl\.textContent\s*=\s*MC_NOTE_BASE/);
  });

  it("keeps a reconnect/shed notice in a strip mcRebuild never wipes", () => {
    // mcRebuild() replaceChildren()s #mcrows on every paint (fold-in-place),
    // so a notice appended into that same container is erased by the very
    // next arriving record — sometimes before it is ever seen. #mcmarks sits
    // outside that container: mcMark() targets it and mcRebuild's own source
    // never names it, so nothing rebuilding rows can touch it.
    const html = pageHtml();
    expect(html).toContain('id="mcmarks"');
    const body = script();
    const mcMarkFn = extractFn(body, "mcMark");
    expect(mcMarkFn).not.toContain("mcRows");
    expect(mcMarkFn).toContain("mcMarksEl");
    const mcRebuildFn = extractFn(body, "mcRebuild");
    expect(mcRebuildFn).not.toContain("mcMarksEl");
    expect(mcRebuildFn).not.toContain("mcmarks");
  });

  it("restores scroll position on the pane a tab switch reveals", () => {
    // [hidden]{display:none!important} gives a hidden pane no layout box, so a
    // scrollTop write made while it was hidden is a no-op — without a restore
    // on reveal, switching tabs opens on the oldest rows, not the newest.
    const body = script();
    const handler = extractListener(body, 'el("feedtabs")', "click");
    expect(handler).toContain("scroll.scrollTop = scroll.scrollHeight");
    expect(handler).toContain("mcScrollEl.scrollTop = mcScrollEl.scrollHeight");
  });

  it("surfaces a dead calls feed on the tab itself, not only inside the hidden pane", () => {
    // #mcdot and #mcerr both live inside #mcPane, invisible while the
    // netwatch tab is showing — without a signal on the tab itself, a failing
    // feed is a silent hole until the operator happens to switch over.
    const html = pageHtml();
    expect(html).toContain("#feedtabs button.err");
    const body = script();
    const mcSetStatusFn = extractFn(body, "mcSetStatus");
    expect(mcSetStatusFn).toContain("mcTabBtn");
    expect(mcSetStatusFn).toContain('"err"');
  });

  it("offers to jump only for calls that actually arrived", () => {
    // Netwatch keeps this apart structurally — its append() raises the button
    // and its rebuild() never touches it. This feed has ONE paint path, which a
    // filter keystroke, a purpose tab and an unpause all reach, so the arrival
    // has to be carried as a flag or a scrolled-up reader is told about a
    // backlog that does not exist. Pinned at the source because raising it at
    // all needs a DOM this suite does not have.
    const body = script();
    const rebuild = extractFn(body, "mcRebuild");
    expect(rebuild).toContain("else if (mcArrived) mcJumpEl.hidden = false;");
    // Consumed by the paint it belongs to, or every later repaint inherits it.
    expect(rebuild).toContain("mcArrived = false;");
    // One writer, and it is a record landing. A second one anywhere else is the
    // bug back under another name.
    expect(extractFn(body, "mcIngest")).toContain("mcArrived = true;");
    expect((body.match(/mcArrived = true;/g) ?? []).length).toBe(1);
    expect((body.match(/mcJumpEl\.hidden = false/g) ?? []).length).toBe(1);
  });
});

describe("prompts arm scheduling and retention, pinned at the source level", () => {
  it("does not reschedule a renewal, or reschedule at all, once the arm has been turned off", () => {
    // The renewal timer's own success/failure handlers must check mcArms
    // .prompts.on before doing anything further — a disarm racing an
    // in-flight renewal must not leave an orphan timer re-arming a capture
    // the toggle shows as off.
    const body = script();
    const mcScheduleFn = extractFn(body, "mcSchedule");
    expect(mcScheduleFn).toContain("a.timer = null;");
    expect((mcScheduleFn.match(/if \(!a\.on\) return;/g) ?? []).length).toBeGreaterThanOrEqual(3);
  });

  it("does not blame a CONTEXT_ARM_FORBIDDEN renewal refusal on this page's own prompts arm having lapsed", () => {
    // A refusal that names the context arm means the CLI is holding it up —
    // this page's own grant has not lapsed. Disarming here blames the wrong
    // arm, misreports an active capture as stopped, and skips the pagehide
    // purge (mcSetArm's disarm branch gates on mcArms.prompts.on).
    const body = script();
    const mcScheduleFn = extractFn(body, "mcSchedule");
    const idxCode = mcScheduleFn.indexOf("CONTEXT_ARM_FORBIDDEN");
    const idxDisarm = mcScheduleFn.indexOf("mcSetArm(false)");
    expect(idxCode).toBeGreaterThan(-1);
    expect(idxDisarm).toBeGreaterThan(-1);
    expect(idxCode).toBeLessThan(idxDisarm);
  });

  it("purges captured prompt/answer text from held records once prompts capture is disarmed", () => {
    const h = loadHelpers();
    h.setRecords([
      { seq: 1, at: 1, prompt: { scaffold: "s", contextText: "secret" }, stdout: "answer" },
      { seq: 2, at: 2, requestedModel: "sonnet" },
    ]);
    h.mcForgetCapturedText();
    const recs = h.getRecords();
    expect(recs[0].prompt).toBeUndefined();
    expect(recs[0].stdout).toBeUndefined();
    // Metadata untouched — the purge is scoped to text fields alone.
    expect(recs[0].seq).toBe(1);
    expect(recs[1].requestedModel).toBe("sonnet");
  });

  it("wires the disarm branch to the purge, not just the disclosure text", () => {
    const body = script();
    const mcSetArmFn = extractFn(body, "mcSetArm");
    expect(mcSetArmFn).toContain("mcForgetCapturedText();");
  });

  it("states the retention boundary in the armed banner, matching netwatch's own disclosure", () => {
    const body = script();
    const mcSetArmFn = extractFn(body, "mcSetArm");
    expect(mcSetArmFn).toContain("stay in this window");
    expect(mcSetArmFn).toContain("disarmed.");
  });

  it("preserves the selection and refreshes the open detail pane across a fold-in-place rebuild", () => {
    // Every row is discarded and rebuilt from scratch on every paint, so a
    // selection tracked by DOM node identity is lost the instant a new record
    // arrives — the selection has to be re-attached by mcAttemptKey instead.
    const body = script();
    const mcRebuildFn = extractFn(body, "mcRebuild");
    expect(mcRebuildFn).toContain("mcAttemptKey(mcSelected.__attempt)");
    expect(mcRebuildFn).toContain("mcAttemptKey(keep[j])");
    expect(mcRebuildFn).toContain("mcShowDetail(reselected.__attempt)");
  });

  it("does not tear down the whole page when only the calls feed's session dies", () => {
    // A netwatch stream can still be delivering frames on its own still-valid
    // connection when /modelwatch alone returns 401 — showExpired() hides
    // #page entirely, taking a working feed down with a dead one.
    const body = script();
    const mcRunFn = extractFn(body, "mcRun");
    expect(mcRunFn).not.toContain("showExpired();");
  });
});

/**
 * Extracts one `function name(...) { ... }` declaration from the page's
 * script by brace-counting from its first `{`. Throws loudly (via the
 * `expect` inside) rather than returning something wrong if the page's shape
 * ever changes out from under these tests.
 */
function extractFn(src: string, name: string): string {
  const marker = "function " + name + "(";
  const start = src.indexOf(marker);
  expect(start).toBeGreaterThan(-1);
  const braceStart = src.indexOf("{", start);
  let depth = 0;
  let i = braceStart;
  for (; i < src.length; i++) {
    if (src[i] === "{") depth++;
    else if (src[i] === "}") {
      depth--;
      if (depth === 0) {
        i++;
        break;
      }
    }
  }
  return src.slice(start, i);
}

/** Extracts a `var NAME = ...;` statement verbatim. */
function extractVar(src: string, name: string): string {
  const marker = "var " + name + " ";
  const start = src.indexOf(marker);
  expect(start).toBeGreaterThan(-1);
  const end = src.indexOf(";", start);
  expect(end).toBeGreaterThan(start);
  return src.slice(start, end + 1);
}

/**
 * Builds the pure calls-feed helpers by pulling their real source out of the
 * shipped page and evaluating them together — the same functions a browser
 * runs, with no DOM underneath them because none of these touch one. What
 * mcRowFor/mcRebuild/mcShowDetail do with a document is NOT covered here:
 * that needs an actual DOM, which this suite does not have, and pretending a
 * text-level check of those functions proved anything would be worse than
 * saying so.
 */
function loadHelpers() {
  const src = script();
  const pieces = [
    extractVar(src, "MAX_EVENTS"),
    extractVar(src, "STRIP ="),
    extractFn(src, "clean"),
    extractFn(src, "shallowCopy"),
    extractFn(src, "mcAttemptKey"),
    extractVar(src, "MC_FOLD_FIELDS"),
    extractFn(src, "mcFoldInto"),
    extractVar(src, "MC_UNUSABLE_RE"),
    extractFn(src, "mcAnswerWasUsable"),
    extractFn(src, "mcRetryWasMoot"),
    extractFn(src, "mcOutcomeCell"),
    extractVar(src, "MC_RETRY_FLOOR_MS"),
    extractFn(src, "mcDuration"),
    extractFn(src, "mcRetryBudgetNote"),
    extractFn(src, "mcTokens"),
    extractFn(src, "mcUsageNote"),
    extractFn(src, "mcToolCell"),
    extractFn(src, "mcModelCell"),
    extractFn(src, "mcHaystack"),
    "var mcView = { purpose: \"all\", query: \"\" };",
    extractFn(src, "mcMatches"),
    // The real state mcFresh/mcIngest/mcForgetCapturedText close over, plus a
    // no-op stand-in for the one thing mcIngest calls that needs a browser
    // (requestAnimationFrame, inside mcSchedulePaint) — mcIngest's own
    // try/catch already treats a throw there as harmless, so a stub that does
    // nothing is the honest substitute rather than a mock asserting on it.
    "var mcRecordsList = []; var mcSeen = Object.create(null);",
    "function mcSchedulePaint(){}",
    extractFn(src, "mcFresh"),
    extractFn(src, "mcIngest"),
    extractFn(src, "mcForgetCapturedText"),
  ];
  const body =
    pieces.join("\n") +
    "\nreturn { clean:clean, mcAttemptKey:mcAttemptKey, mcFoldInto:mcFoldInto, " +
    "mcAnswerWasUsable:mcAnswerWasUsable, mcOutcomeCell:mcOutcomeCell, " +
    "mcRetryBudgetNote:mcRetryBudgetNote, mcDuration:mcDuration, mcTokens:mcTokens, " +
    "mcUsageNote:mcUsageNote, mcToolCell:mcToolCell, mcModelCell:mcModelCell, " +
    "mcHaystack:mcHaystack, mcMatches:mcMatches, mcView:mcView, mcFresh:mcFresh, " +
    "mcIngest:mcIngest, mcForgetCapturedText:mcForgetCapturedText, MAX_EVENTS:MAX_EVENTS, " +
    "getRecords:function(){ return mcRecordsList; }, " +
    "setRecords:function(v){ mcRecordsList = v; } };";
  // eslint-disable-next-line no-new-func
  return new Function(body)() as {
    clean: (v: unknown, max?: number) => string;
    mcAttemptKey: (ev: any) => string;
    mcFoldInto: (base: any, ev: any) => any;
    mcAnswerWasUsable: (outcome: string) => boolean;
    mcOutcomeCell: (a: any) => { text: string; cls: string };
    mcRetryBudgetNote: (a: any) => { text: string; cls: string } | null;
    mcDuration: (ms: unknown) => string;
    mcTokens: (n: unknown) => string | null;
    mcUsageNote: (a: any) => string | null;
    mcToolCell: (a: any) => string;
    mcModelCell: (a: any) => string;
    mcHaystack: (a: any) => string;
    mcMatches: (a: any) => boolean;
    mcView: { purpose: string; query: string };
    mcFresh: (ev: any) => boolean;
    mcIngest: (ev: any) => void;
    mcForgetCapturedText: () => void;
    MAX_EVENTS: number;
    getRecords: () => any[];
    setRecords: (v: any[]) => void;
  };
}

/**
 * Extracts an anonymous listener passed to `<id>.addEventListener("<event>",
 * function(...){ ... })` — the feedtabs handler has no name of its own to hand
 * `extractFn`. Same brace-counting approach, anchored on the call site instead
 * of a `function name(` marker.
 */
function extractListener(src: string, elExpr: string, event: string): string {
  const marker = elExpr + '.addEventListener("' + event + '", function';
  const start = src.indexOf(marker);
  expect(start).toBeGreaterThan(-1);
  const braceStart = src.indexOf("{", start);
  let depth = 0;
  let i = braceStart;
  for (; i < src.length; i++) {
    if (src[i] === "{") depth++;
    else if (src[i] === "}") {
      depth--;
      if (depth === 0) {
        i++;
        break;
      }
    }
  }
  return src.slice(start, i);
}

describe("model-call folding and formatting, run for real off the shipped source", () => {
  it("keys an attempt by callId and attempt, and never merges two malformed records into one bucket", () => {
    const h = loadHelpers();
    expect(h.mcAttemptKey({ callId: "c1", attempt: 1, seq: 1 })).toBe("c1#1");
    expect(h.mcAttemptKey({ callId: "c1", attempt: 2, seq: 2 })).toBe("c1#2");
    // A missing or wrongly-typed callId falls back to this record's own seq —
    // two such events must still land in two different buckets, not one.
    const a = h.mcAttemptKey({ callId: 42, attempt: 1, seq: 7 });
    const b = h.mcAttemptKey({ seq: 8 });
    expect(a).not.toBe(b);
    expect(a).toBe("seq:7#1");
    expect(b).toBe("seq:8#1");
  });

  it("folds a start with no end into a live record, not a broken one", () => {
    const h = loadHelpers();
    const start = h.mcFoldInto(null, {
      callId: "c1",
      attempt: 1,
      phase: "start",
      purpose: "decision",
      at: 1000,
      requestedTool: "claude-code",
      actualTool: "claude-code",
      reach: "repo",
    });
    expect(start.ended).toBe(false);
    expect(start.purpose).toBe("decision");
    expect(start.wallMs).toBeUndefined();
  });

  it("never lets an absent field on a later record erase one a start already set", () => {
    const h = loadHelpers();
    const start = h.mcFoldInto(null, {
      callId: "c1",
      attempt: 1,
      phase: "start",
      purpose: "title",
      at: 1000,
      requestedTool: "claude-code",
      actualTool: "claude-code",
      reach: "repo",
      requestedModel: "sonnet",
    });
    // An end record that says nothing about the model must not blank it.
    const ended = h.mcFoldInto(start, { phase: "end", wallMs: 500 });
    expect(ended.ended).toBe(true);
    expect(ended.wallMs).toBe(500);
    expect(ended.requestedModel).toBe("sonnet");
    expect(ended.purpose).toBe("title");
  });

  it("matches outcome vocabulary on words, so a caller can name a new one without this page hard-coding it", () => {
    const h = loadHelpers();
    expect(h.mcAnswerWasUsable("named")).toBe(true);
    expect(h.mcAnswerWasUsable("parsed")).toBe(true);
    expect(h.mcAnswerWasUsable("timeout")).toBe(false);
    expect(h.mcAnswerWasUsable("budget-exhausted")).toBe(false);
    // A vocabulary word this page has never seen before still classifies
    // correctly, because the test is on the WORD, not a closed enum.
    expect(h.mcAnswerWasUsable("quarantined-pending-review")).toBe(true);
  });

  it("prefers the caller's own outcome text over the exit code, and marks a live call as in flight", () => {
    const h = loadHelpers();
    expect(h.mcOutcomeCell({ outcome: "named", ended: true, exitCode: 1 }).text).toBe("named");
    expect(h.mcOutcomeCell({ ended: false }).text).toBe("in flight");
    expect(h.mcOutcomeCell({ ended: true, timedOut: true }).text).toBe("timed out");
    expect(h.mcOutcomeCell({ ended: true, exitCode: 3 }).text).toBe("exit 3");
    expect(h.mcOutcomeCell({ ended: true, exitCode: 0 }).text).toBe("ran");
  });

  it("never breaks on a malformed or hostile attempt object", () => {
    const h = loadHelpers();
    const hostile = [
      {},
      { outcome: 123, ended: "yes", exitCode: "oops" },
      { usage: "not an object" },
      { usage: { inputTokens: "lots", money: "free" } },
      { requestedTool: 5, actualTool: {}, requestedModel: null },
      { prompt: "should be an object" },
    ];
    for (const a of hostile) {
      expect(() => h.mcOutcomeCell(a)).not.toThrow();
      expect(() => h.mcUsageNote(a)).not.toThrow();
      expect(() => h.mcToolCell(a)).not.toThrow();
      expect(() => h.mcModelCell(a)).not.toThrow();
      expect(() => h.mcHaystack(a)).not.toThrow();
      expect(() => h.mcMatches(a)).not.toThrow();
      expect(() => h.mcRetryBudgetNote(a)).not.toThrow();
    }
  });

  it("agrees with the CLI's usageNote: separate cache read/write, reasoning only when nonzero, money tagged and never summed", () => {
    const h = loadHelpers();
    const full = h.mcUsageNote({
      usage: {
        inputTokens: 1200,
        cacheReadTokens: 4000,
        cacheWriteTokens: 900,
        outputTokens: 300,
        reasoningTokens: 0,
        money: { unit: "usd", amount: 0.42 },
        modelsBilled: 2,
      },
    });
    expect(full).toContain("cache r 4.0k");
    expect(full).toContain("cache w 900");
    // Zero reasoning is not reported, matching the CLI's own "only when
    // nonzero" — the CLI leaves a zero out rather than implying it double-
    // counted into `out`.
    expect(full).not.toContain("reasoning");
    expect(full).toContain("0.42 usd");
    expect(full).toContain("2 models");

    const withReasoning = h.mcUsageNote({ usage: { outputTokens: 10, reasoningTokens: 50 } });
    expect(withReasoning).toContain("reasoning 50");
    // Reasoning is disclosed on its own token, never folded into `out`.
    expect(withReasoning).not.toMatch(/out 60\b/);

    expect(h.mcUsageNote({})).toBeNull();
    expect(h.mcUsageNote({ usage: null })).toBeNull();
  });

  it("shows a borrow and a model swap distinctly from an unremarkable match", () => {
    const h = loadHelpers();
    expect(h.mcToolCell({ requestedTool: "claude-code", actualTool: "claude-code" })).toBe("claude-code");
    expect(h.mcToolCell({ requestedTool: "claude-code", actualTool: "codex" })).toBe("claude-code→codex");
    expect(h.mcModelCell({ requestedModel: undefined, actualModel: undefined })).toBe("default");
    expect(h.mcModelCell({ requestedModel: "sonnet", actualModel: "sonnet" })).toBe("sonnet");
    expect(h.mcModelCell({ requestedModel: "sonnet", actualModel: "haiku" })).toBe("sonnet→haiku");
  });

  it("never throws formatting a duration or a token count off the wrong type", () => {
    const h = loadHelpers();
    for (const bad of [undefined, null, "12", NaN, Infinity, {}]) {
      expect(() => h.mcDuration(bad)).not.toThrow();
      expect(() => h.mcTokens(bad)).not.toThrow();
    }
    expect(h.mcDuration(500)).toBe("500ms");
    expect(h.mcDuration(1500)).toBe("1.5s");
    expect(h.mcTokens(999)).toBe("999");
    expect(h.mcTokens(1500)).toBe("1.5k");
  });

  it("filters by purpose and free text without throwing on a record missing both", () => {
    const h = loadHelpers();
    h.mcView.purpose = "title";
    h.mcView.query = "";
    expect(h.mcMatches({ purpose: "title" })).toBe(true);
    expect(h.mcMatches({ purpose: "decision" })).toBe(false);
    expect(h.mcMatches({})).toBe(false);
    h.mcView.purpose = "all";
    h.mcView.query = "sonnet";
    expect(h.mcMatches({ requestedModel: "sonnet" })).toBe(true);
    expect(h.mcMatches({ requestedModel: "haiku" })).toBe(false);
    expect(h.mcMatches({})).toBe(false);
  });

  it("strips control characters and bidi overrides, and truncates with a marker", () => {
    // The page's own header names this as the reason peer text — a model's
    // stdout, an outcomeDetail — is safe to render: control characters cannot
    // execute here, but a bidi override can silently reorder a line so it
    // reads as a different frame than the one recorded.
    const h = loadHelpers();
    expect(h.clean("a\u0000b\u202Ec")).toBe("abc");
    expect(h.clean("")).toBe("");
    expect(h.clean("abcdef", 3)).toBe("abc…");
  });

  it("folds every field a later record may fill in, not just the two the fold tests exercise", () => {
    // MC_FOLD_FIELDS can be cut down to any subset and the two fold tests
    // above — which each check a couple of named fields — stay green. Assert
    // the whole set independently of what MC_FOLD_FIELDS itself currently
    // says, so shrinking that array is what this test is for.
    const h = loadHelpers();
    const start = h.mcFoldInto(null, {
      callId: "c1", attempt: 1, phase: "start", purpose: "decision", at: 1000,
      requestedTool: "claude-code", actualTool: "claude-code", reach: "repo",
    });
    const end = h.mcFoldInto(start, {
      phase: "end",
      requestedModel: "sonnet", actualModel: "haiku", terminalId: "t1", conversationId: "conv1",
      projectId: "proj1", wallMs: 500, apiMs: 300, budgetMs: 9000, remainingMs: 8000,
      exitCode: 0, timedOut: false, outcome: "named", outcomeDetail: "detail text",
      promptChars: 42, stdoutChars: 99, prompt: { scaffold: "s" }, stdout: "out",
      usage: { inputTokens: 1 },
    });
    expect(end).toMatchObject({
      requestedModel: "sonnet", actualModel: "haiku", terminalId: "t1", conversationId: "conv1",
      projectId: "proj1", wallMs: 500, apiMs: 300, budgetMs: 9000, remainingMs: 8000,
      exitCode: 0, timedOut: false, outcome: "named", outcomeDetail: "detail text",
      promptChars: 42, stdoutChars: 99, prompt: { scaffold: "s" }, stdout: "out",
      usage: { inputTokens: 1 },
    });
  });

  it("dedups records by (seq, at), and admits a differing at for the same seq", () => {
    const h = loadHelpers();
    expect(h.mcFresh({ seq: 1, at: 1000 })).toBe(true);
    expect(h.mcFresh({ seq: 1, at: 1000 })).toBe(false);
    expect(h.mcFresh({ seq: 1, at: 1001 })).toBe(true);
    expect(h.mcFresh({ seq: 2, at: 1000 })).toBe(true);
  });

  it("caps the raw records held at MAX_EVENTS", () => {
    const h = loadHelpers();
    expect(h.MAX_EVENTS).toBe(16384);
    for (let i = 0; i < h.MAX_EVENTS + 500; i++) h.mcIngest({ seq: i, at: i });
    expect(h.getRecords().length).toBe(h.MAX_EVENTS);
    // The cap keeps the NEWEST records, not an arbitrary subset.
    const last = h.getRecords()[h.getRecords().length - 1];
    expect(last.seq).toBe(h.MAX_EVENTS + 499);
  });

  it("returns null, not a guess, for a call with nothing left to say about a retry", () => {
    const h = loadHelpers();
    expect(h.mcRetryBudgetNote({})).toBeNull();
    expect(h.mcRetryBudgetNote({ remainingMs: "soon" })).toBeNull();
    // "moot" — the answer was usable, so a retry budget is nobody's concern.
    expect(h.mcRetryBudgetNote({ remainingMs: 1000, outcome: "named" })).toBeNull();
  });

  it("names the three retry-budget verdicts and their thresholds exactly", () => {
    const h = loadHelpers();
    expect(h.mcRetryBudgetNote({ remainingMs: 0 })).toEqual({ text: "nothing left for a retry", cls: "oc-bad" });
    expect(h.mcRetryBudgetNote({ remainingMs: -5 })).toEqual({ text: "nothing left for a retry", cls: "oc-bad" });
    const belowFloor = h.mcRetryBudgetNote({ remainingMs: 4999 })!;
    expect(belowFloor.cls).toBe("oc-bad");
    expect(belowFloor.text).toContain("unreachable");
    const aboveFloor = h.mcRetryBudgetNote({ remainingMs: 5001 })!;
    expect(aboveFloor.cls).toBe("dim");
    expect(aboveFloor.text).not.toContain("unreachable");
  });

  it("keeps its retry floor in lockstep with the CLI's own RETRY_FLOOR_MS", async () => {
    // A hand-mirrored constant with nothing checking the mirror — this is the
    // check.
    const { RETRY_FLOOR_MS } = await import("../src/cli/modelwatch");
    const h = loadHelpers();
    const floor = Number(extractVar(script(), "MC_RETRY_FLOOR_MS").match(/=\s*(\d+)/)![1]);
    expect(floor).toBe(RETRY_FLOOR_MS);
    expect(h.mcRetryBudgetNote({ remainingMs: RETRY_FLOOR_MS - 1 })!.text).toContain("unreachable");
  });

  it("keeps its unusable-outcome pattern in lockstep with the CLI's", async () => {
    // Hand-mirrored, and the two disagreeing is invisible in both: the CLI
    // would paint a verdict red while the browser painted the same one green.
    const { UNUSABLE_OUTCOME_RE } = await import("../src/cli/modelwatch");
    const mirrored = extractVar(script(), "MC_UNUSABLE_RE").match(/=\s*(\/.*\/)\s*;/)![1];
    expect(mirrored).toBe(UNUSABLE_OUTCOME_RE.toString());
    // And the newest verb the pair has to classify — a naming call refused
    // before the spawn because the vendor bills per call — lands on the
    // unusable side of both, rather than reading as a title that worked.
    expect(UNUSABLE_OUTCOME_RE.test("skipped")).toBe(true);
    expect(loadHelpers().mcAnswerWasUsable("skipped")).toBe(false);
  });
});
