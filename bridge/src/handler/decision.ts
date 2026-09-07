// bridge/src/handler/decision.ts
import { z } from "zod";
import { agentSpec } from "../agents/registry";
import { pickHeadlessFrom, type HeadlessCommand, type JudgeTier } from "../agents/types";
import type { CapCommand } from "../structured/chat-session";
import { clip, ItemTransitionSchema, oneLine } from "./backlog";
import { extractJsonObject } from "./json-extract";
import { MAX_REPLY_CHARS } from "./reply-shape";
import type { HandlerLens } from "../protocol";

// What the prompt will print of the user's brief. The engine clips to it on the
// way in and this module clips again, so the wire never has to refuse a long
// brief — and refusing one there would drop the arm it rode in on.
export const MAX_BRIEF_CHARS = 500;

/** The brief as the prompt prints it: one line, bounded, or nothing at all.
 *
 *  Collapsed through `oneLine` — the ONE copy of that rule (./backlog) — because
 *  the brief is printed as a single bullet inside a section of headers, and a
 *  pasted newline would otherwise forge a line the judge reads as structure.
 *  Clipped with an empty ellipsis so the result is never longer than the cap. */
export function normalizeBrief(raw: string): string | undefined {
  return clip(oneLine(raw), MAX_BRIEF_CHARS, "") || undefined;
}

// What the judge LOOKS FOR and ASKS ABOUT, added on top of the rules it is
// printed under. Two properties every entry keeps, both machine-checked:
//
// It says nothing about where the line between handling and escalating sits.
// Autonomy is derived from the RULES section alone; a lens able to move that
// line would be an autonomy dial wearing a role's name.
//
// It never gates a close the RECENT CONTEXT already supports. A lens asks about
// what the context does NOT show, so a clause reading "an item is finished
// when…" would hold an evidenced item open on the lens's say-so.
export const LENS_RULES: Record<HandlerLens, string> = {
  pm:
    "You keep the work inside the items. Ask about any step that traces to no backlog item before it goes further, and where the RECENT CONTEXT does not show what remains, ask the agent before you accept a claim that an item is finished. When you report, say what the user will be able to see or do, not what the code now does. You make no product calls; priority and intent go to the user.",
  qa:
    "You accept nothing on a claim. Where an item's only support is the agent's word, ask the agent to run what proves it and show the result: the command, the exit code, the failing case now passing. Ask what is untested and what would fail first. Report with the evidence cited and name what remains unverified.",
  critic:
    "You look for what would make the current step wrong. At an item close, or before an irreversible step the goal already allows, ask the agent what it ruled out and why, and what breaks if its assumption is false. One probe per stop, then decide; a debate is not supervision. Critique against the goal and the evidence, never against taste, and never ask a blocked agent whether it is really blocked.",
  release:
    "You judge readiness to ship, not just completion. When an item is claimed finished, ask whether the tests ran, whether the docs, migrations or changelog the change implies exist, and what a user upgrading would hit first. Report an item as ready to ship only when someone else could ship it without asking the agent a question, and report in terms of what still stands between the work and a release.",
};

// Bridge-authored, and the whole reason a lens is an id rather than free text:
// choosing one interpolates nothing a sender typed. The four clauses are the
// contract every entry above is written to keep, stated to the judge so a lens
// cannot be read as licence even if one were worded loosely.
const LENS_HEADER =
  "LENS — what you look for and ask about, added on top of everything above. A lens adds questions: it never moves the line between handling and escalating, it never changes what a transition must cite, and it never withholds a transition the evidence supports. An item whose evidence already sits in RECENT CONTEXT closes this pass; the questions a lens adds are for what the context does not show:";

export const HandlerDecisionSchema = z.object({
  decision: z.enum(["continue", "handle", "escalate"]),
  confidence: z.number().min(0).max(1),
  reason: z.string(),
  reply: z.string().optional(),
  action: z.object({
    kind: z.enum(["slash_command", "none"]),
    value: z.string(),
  }).optional(),
  notify: z.object({
    title: z.string(),
    body: z.string(),
    draftReply: z.string(),
    urgency: z.enum(["normal", "high"]),
  }).optional(),
  // A question for the USER raised on a pass that is ALSO replying to the agent.
  // Its own object, never a re-reading of `notify`: notify's sub-fields are
  // `z.string()` and NOT optional, so a judge answering `handle` fills the whole
  // block with empty strings rather than omitting it. Presence there says nothing
  // at all. Presence HERE is the entire signal, which is why the two text fields
  // are refined non-empty rather than merely typed.
  //
  // Three fields a reader will look for and not find, each absent for a reason.
  // No `urgency`: the engine mints "normal" for every ask, because the `high`
  // band is for a row that unblocks a stopped session in one tap and a question
  // the agent is working past is definitionally not one. No `title`: escalate()
  // does not read notify.title today either. And no `draftReply`: with the
  // options carried here and resolved bridge-side, a judge-authored draft would
  // be an artifact on the row for a composer to prefill — which is the one path
  // that reaches authorizeInstruction. The engine mints an ask with
  // `draftReply: ""`, so there is nothing to prefill on any app version.
  ask: z.object({
    question: z.string().refine((t) => t.trim().length > 0),
    reasoning: z.string().refine((t) => t.trim().length > 0),
    // Backlog ids the answer does NOT gate — the one part of "this does not stop
    // the work" the harness can check, and it does check it (see raiseAsk) and
    // re-checks it every pass (see reconcileAsks).
    unblocked: z.array(z.string()).min(1).max(10),
    // Optional, and 2..4: one option is a card with no alternative. Absent means a
    // genuinely open question, rendered as a free-text row plus its still-working
    // list — which is a complete ask, not a degraded one. No `choiceId` here: the
    // ids are ENGINE-authored by position, because an id round-trips through the
    // wire and resolves against the persisted row. It is identity, never
    // authority, and nothing the judge writes may become one.
    options: z.array(z.object({
      label: z.string(),
      // What picking this commits to, one clause. It is ALSO the reason line under
      // the recommended row: a recommendation whose reason is not its cost is one
      // the user cannot check.
      cost: z.string(),
      recommended: z.boolean().optional(),
    })).min(2).max(4).optional(),
  }).optional(),
  // Progress is reported as moves against existing ids, never as prose: the same
  // schema applyTransitions re-validates, so what the evaluator may say and what
  // the engine will accept cannot drift apart.
  transitions: z.array(ItemTransitionSchema).optional(),
});
export type HandlerDecision = z.infer<typeof HandlerDecisionSchema>;
// Derived from the schema rather than declared beside it: raiseAsk reads these
// to mint a row, and a hand-written second spelling could describe a shape the
// judge is not actually permitted to send.
export type DecisionAsk = NonNullable<HandlerDecision["ask"]>;
export type DecisionAskOption = NonNullable<DecisionAsk["options"]>[number];

// Re-exported, not redefined: the reaches an agent declares live on
// AgentSpec.headless, and a second spelling here could drift from them.
export type { JudgeTier } from "../agents/types";

// The judge command for an arbitrary tool string, read off the one place a tool
// is described. Tier and command come back together because they are one field
// on the spec — a "readonly" claim and the flags that enforce it can no longer
// drift. Null = no VERIFIED headless judge for this tool, which gates Handler
// off. The COMMAND, not one built argv: a judge run retries with a second
// prompt, and both attempts must come from the same entry.
export function pickJudge(
  tool: string,
): { command: HeadlessCommand; tier: JudgeTier } | null {
  const picked = pickHeadlessFrom(agentSpec(tool)?.headless, "repo");
  // "repo" cannot select a sealed entry; the check is what lets the reach narrow
  // to a JudgeTier without a cast, rather than a case that can actually happen.
  if (!picked || picked.reach === "sealed") return null;
  return { command: picked.command, tier: picked.reach };
}

// The CLI name, not the AgentKey and not the display label: the judge is
// reading a transcript the agent itself wrote, where `claude` appears and
// `claude-code` (our routing key) never does.
function supervisedName(tool: string): string {
  return agentSpec(tool)?.bin ?? tool;
}

// Command names and descriptions come verbatim from filesystem frontmatter and
// can carry newlines that would break the one-entry-per-line rendering.
function promptLine(s: string): string {
  return s.replace(/\s+/g, " ").trim();
}

// The transition rules below restate what applyTransitions enforces. That is
// belt-and-braces, not the guard — a prompt cannot bind the component it is
// addressed to. It earns its place by making well-formed output the likely one:
// an evaluator that answers in prose gets its progress dropped, and the item
// then sits open with nothing explaining why. The refused-transitions
// section is the same bargain one pass later: the harness has already dropped
// those moves, and stating why is what stops the next pass re-citing identically.
export function buildDecidePrompt(opts: {
  goal: string; backlogText: string; context: string; transcriptPath?: string;
  floorWarnings?: string[];
  evidenceRejections?: string[];
  // Consecutive auto-replies left before the guard refuses the next `handle` and
  // raises the refusal itself. A floor rather than a promise: the caller reads it
  // off the guard before the judge runs, and an item this same pass reports
  // `done` restores the whole cap afterwards.
  replyBudget?: number;
  // Questions of the judge's own that the user has not answered yet, and asks the
  // harness refused to raise last pass. Both are derived per pass by the caller,
  // never cached: each section asserts a state that the very next event can end.
  openAsks?: string[];
  askRejections?: string[];
  // The user's answer to a standing question, parked until a `handle` relays it.
  // Projected down to what the judge can act on — the escalationId is routing and
  // the timestamp is bookkeeping, and neither belongs in a prompt.
  askAnswer?: { question: string; answer: string; tapped: boolean };
  // The agent being SUPERVISED, never the judge running this prompt — a
  // per-session judge pick can point at a different CLI entirely.
  agentTool?: string;
  // Non-empty or absent: an empty catalog is indistinguishable from a failed
  // or not-yet-landed discovery, so it is never announced as a complete set.
  commands?: CapCommand[];
  // Absent = the unnamed default, which is the RULES alone: no section prints,
  // so the default is not a fifth text that could drift into a posture.
  role?: HandlerLens;
  // The user's own words for what else to look for. Free text, and the only
  // free text in this prompt the user writes directly — fenced as theirs, and
  // told to the judge as questions rather than as a rule.
  brief?: string;
}): string {
  const budget = opts.replyBudget;
  const answered = opts.askAnswer;
  // A role is one value out of a fixed table, so `!== undefined` is the whole
  // test for it. A brief is tested non-empty AFTER the collapse instead: unlike
  // the user's answer below, where "" is still the user having spoken, a brief
  // of whitespace is nothing to add and a header over it would announce a lens
  // the user never set. Re-normalized here rather than trusted from the caller,
  // so a prompt built by a test or a future call site is bounded too.
  const brief = opts.brief ? normalizeBrief(opts.brief) : undefined;
  return [
    opts.agentTool
      ? `You are a supervisor standing in for the user while the coding agent \`${supervisedName(opts.agentTool)}\` works.`
      : "You are a supervisor standing in for the user while a coding agent works.",
    "Decide whether to let the agent continue, answer it on the user's behalf, or escalate to the user.",
    "`handle` types text at the agent, and it covers two moves: TELL the agent what to do next, or ASK it a question when what you are missing is something it can answer from the work in front of it. A question is a `handle` whose `reply` is the question — there is no separate decision value for one.",
    "",
    "SESSION GOAL (the user's own words):",
    opts.goal || "(none stated)",
    "",
    "BACKLOG — the complete set of items you may report on. Each line starts with its id:",
    opts.backlogText || "(no items)",
    "",
    "REPORTING PROGRESS:",
    "- Report every item whose state changed as one entry in `transitions`.",
    "- Use ONLY the ids listed above, copied exactly. Any other id is discarded, and you cannot create an item — if the agent did something the backlog does not cover, describe it in `reason` instead.",
    "- Statuses: `queued` (waiting its turn — use it to revive a blocked item whose precondition is now met), `active` (being worked on now), `done` (finished), `blocked` (a precondition or dependency is unmet), `skipped` (no longer applicable — its condition turned out false, or a later item supersedes it), `failed` (attempted and could not be completed).",
    "- Every transition to `done`, `skipped` or `failed` MUST carry `evidence`: a short verbatim quote copied character-for-character out of the RECENT CONTEXT block below, at least a phrase long. The harness searches that block for your quote — a paraphrase, a summary, or a quote from anywhere else is discarded and the item stays open. Never quote the item's own wording back; that says nothing about what happened.",
    "- If an item names a slash command, `done` additionally requires a quote showing THAT command being invoked. A quote about some other, similar step does not close it, however real the quote is.",
    "- Report `done` only on evidence the work actually happened (test output, exit codes, a diff), never on intent or belief. `outcome` is your one-line summary for the user and never substitutes for evidence.",
    "- An item the agent has already satisfied on its own is `done` with that evidence — do not drive it again.",
    // The judge reasons over a capped excerpt while the agent holds the live
    // session, so its edge is judgement about WHAT, never a recipe for HOW: a
    // procedure composed from that excerpt is a guess the agent then follows
    // verbatim. The same bound covers `notify.draftReply`, which the app offers
    // the user as a one-tap chip.
    "",
    "ALTITUDE — you decide WHAT should happen next and why; the agent decides HOW.",
    // Placed at the top of ALTITUDE because it scopes everything under it: the
    // judge is picked for cheapness and reads a capped excerpt, so its authority
    // has to rest on what it holds that the agent does not — the user's own
    // words and the backlog — never on knowing the work better.
    "- You are not an expert on the task, and do not need to be. What you hold that the agent does not is the user's stated intent and the backlog: you can judge whether a step serves what the user asked for, and you can decide from what the agent reports whether an item is finished. Technical merit — which approach is better, whether a design is sound — is not yours to settle, and a confident-sounding answer about it is a guess the agent will act on.",
    "- RECENT CONTEXT below is a bounded excerpt of the session, not the whole of it. The agent has the live session, the working tree and write access; assume it knows the file layout, the commands and this project's conventions better than you do.",
    "- Name the outcome you want and what would make it wrong. Do not write the agent's commands, file edits or commit messages for it.",
    "- Keep it to one or two sentences. Length reads as certainty you do not have, and each extra clause is another detail you did not verify. This binds `notify.draftReply` too: the user is offered it as a one-tap chip and it reaches the agent verbatim if they take it.",
    "",
    "RULES:",
    // "recording", not "making": a question IS a `handle` (see the framing line
    // above), so a rule phrased against escalating-versus-progress reads as a rule
    // against asking. Its actual job is narrower — keep `transitions` honest.
    "- Escalating always trumps recording progress: if the next step on an item needs the user, escalate instead of transitioning it. This governs `transitions` only, and it is not a preference for escalating over asking — a question to the agent is a `handle`, and the rules below govern when to spend one. Transitions the evidence supports are recorded on every decision, an `escalate` included, so closing an item never requires a `handle`.",
    "- If you cannot answer with high confidence, escalate. A wrong auto-reply is the expensive failure. Measure that confidence against what you are positioned to know — whether a step serves the stated intent, whether the agent's own report closes an item — never against technical merit. Being unsure which approach is better is not this rule firing: that was never a question you were going to answer, so it is not one you escalate for either.",
    // Ordered against the confidence rule above, never merely beside it: missing
    // information is exactly that rule's trigger, so an unordered "ask the agent"
    // would divert to the agent what only the user can settle.
    "- Missing information is not automatically the user's problem, and the split is by who can answer: ask the AGENT for facts about the work — what it found, what it tried, what it chose and why. Escalate what only the USER can settle: intent, authorization, preference, anything that changes the goal.",
    // Ordered below the confidence floor and the who-can-answer split, never above
    // either: these price the two resources, and a judge that read them first would
    // take "the user is expensive" as licence to answer what only the user can
    // settle. The asymmetry they state is mechanical, not rhetorical — an exhausted
    // auto-reply run self-escalates inside the session, while an unanswered
    // escalation stalls it until a human returns: nothing re-raises one, and a
    // blocked agent emits no further event (see `onUserReply` in engine.ts).
    "- The two costs are not equal. A question to the agent spends one of a bounded run of consecutive auto-replies and is answered in seconds; the harness escalates on its own once that run is exhausted or you repeat yourself, so an unhelpful question is recoverable within this session. An escalation spends the user, who may be asleep, and the session does nothing until they answer — nothing re-raises it, and no further event arrives while the agent sits idle. Neither is free. The escalation is the expensive one. That is why `ask` is the only way to put a question to the user without stopping: it rides a reply that keeps the agent producing the events this supervision runs on.",
    // The harness's side of the contract, stated because a judge that has to
    // infer it infers wrong: observed live, a `handle` whose `reason` said "I
    // escalate" closed the last item, and the session wrapped up over a question
    // the judge believed it had raised. Nothing here is a rule about when to
    // choose; it is what each choice does once made.
    "- What each decision does after this pass, so that `reason` and `reply` are never asked to do a decision's work: `handle` sends `reply` to the agent and nothing to the user. `continue` sends nothing to anyone. `escalate` sends the agent nothing, wakes the user with `notify`, and holds the session for their answer. The user reads an `escalate`, an `ask`, and the wrap-up summary described next — never `reason`, never `reply`. When `transitions` close the last open item on a `handle` or a `continue`, the session ends there: the user gets a summary of the item outcomes and nothing else, and no further pass runs.",
    // Printed directly under the rule that prices the two resources, because it is
    // the only place the price is a live number rather than a standing asymmetry.
    // Tested with `!== undefined` and never for truthiness or `?.length`: the two
    // feedback sections above use the length idiom because an empty list has
    // nothing to say, and an exhausted run is the one value here that says the
    // most. Zero is a separate sentence rather than an interpolated count so the
    // judge is never asked to do arithmetic on the number that decides whether its
    // next `handle` reaches the agent at all.
    ...(budget !== undefined
      ? [budget === 0
        ? "- Concretely, right now: your consecutive auto-reply run is spent. The next `handle` is refused before it reaches the agent and raised to the user as a report you did not write. Decide on what you already hold — let the agent continue, escalate, or wrap up."
        : `- Concretely, right now: ${budget} consecutive auto-repl${budget === 1 ? "y" : "ies"} left before the harness stops sending them and raises the refusal to the user in words you did not choose; sending a reply you already sent spends the whole run in one step. This is planning information and never permission — every rule above reads the same at ${budget} as it does at full budget, and a reply you would not otherwise have sent is not made right by having room for it. Treat it as a floor rather than an allowance: an item reaching \`done\` restores it. If what is left plainly will not carry the work to somewhere the user can act, say so now instead of being cut off mid-run.`]
      : []),
    "- So before you escalate, apply this test: could one read-only question to the agent plausibly dissolve this escalation, or sharpen what you would ask the user? If yes, ask it, and escalate on the next pass if the answer does not settle it. If the escalation stands whatever the agent replies — because what is missing is intent, authorization or preference — escalate now and do not spend the turn.",
    // Printed directly under the escalate-or-ask-the-agent test because it is the
    // one case that test cannot reach: what is missing is intent, authorization or
    // preference — so the agent cannot dissolve it — and yet the work the answer
    // does not gate is still running. Above it the third move would read as a
    // cheaper escalation; here it reads as what it is, the branch of the test where
    // the user is the only one who can answer and the session need not stop.
    "- There is a third move between answering the agent and waking the user, and it is the only one that does both at once: on a `handle`, fill `ask` with a question for the USER while `reply` keeps the agent working. Use it only when both halves hold — the question is one only the user can settle (intent, authorization, preference), AND there is work already on the backlog that their answer does not gate. Name that work in `ask.unblocked` as backlog ids copied exactly from the list above. If everything left waits on the answer there is no such work, and this was an escalation. `ask.options` is optional and holds 2 to 4 things the USER may pick between, each with a `cost` saying what picking it commits to; at most one may carry `recommended`. A tap on one sends the AGENT nothing — the pick comes back to you, and passing it on is yours to do.",
    "- `ask` is read on a `handle` alone. On `continue` or `escalate` it is discarded, because neither of those sends the agent anything: the session would sit behind a question you had told the user was not holding it up, with no further event arriving to raise it again.",
    "- One question at a time. While a question of yours is unanswered it is listed for you below and a second `ask` is discarded rather than queued, so make the one you send the one you most need answered and do not reword it. An `ask` beside a reply that only marks time is worse than the escalation it avoided: the user reads a question over a session going nowhere, and nothing in the harness can check your claim that the rest of the work is independent except the ids you named.",
    // The half a judge would otherwise have to infer from the absence of a rule.
    // Nothing in the harness types an answer at the agent — answerAsk and the
    // ask-answer branch of instruct both park it for the next prompt and stop
    // there — so a judge that reads its own question as delegated leaves the user
    // having answered into silence.
    "- An answer to your question comes back to YOU, never to the agent. Relay it in your own words on a `handle`; the harness will not do it for you, and the agent is told nothing until you do.",
    // The concrete form of the test above for the case it fits worst. A choice
    // between approaches is neither a fact the agent can hand over nor a preference
    // only the user holds, so both halves of the who-can-answer split read as "not
    // mine" and the raw question gets forwarded. Enumerating first is what turns it
    // into something the goal can decide — and failing that, into a choice the user
    // can make without reconstructing the session.
    "- When what stops the agent is a choice between ways of doing something, neither pick on technical grounds nor forward the open question. Ask the agent for the options it sees and what each costs. Then decide against the SESSION GOAL if the goal separates them; escalate if it does not, carrying the options, their costs and the one you would take. Put them in `notify.body`, and make `notify.draftReply` the option you would take, written as the instruction that would send it — the user is offered it as a one-tap chip. A short choice can be answered in seconds; an open engineering question makes the user rebuild the whole session first.",
    // Printed against the safety rule below because it is the same guardrail from
    // the other side: the rule above sends the judge to the agent more often, and
    // the cheapest way for a blocked agent to answer "are you still blocked?" is to
    // stop being blocked. Naming the specific escapes beats a general caution — a
    // judge told only to be careful still writes "can you try again?", which is the
    // prompt that gets a gate skipped.
    "- When that question is about a blocker the agent has reported — a refused tool call, a failing gate, a missing credential — ask only for the state of it: whether it still reproduces, what exactly was refused, what it has already tried. Say in the same line that you want it reported, not worked around. An agent asked whether it is really blocked can make the question go away by defeating the block: skipping the gate, disabling the check, declaring unverified work verified, or committing it anyway. That is a worse outcome than the escalation you were avoiding.",
    "- Safety limits are enforced after your decision; never attempt to bypass them.",
    `- \`reply\` is free text typed at the agent and submitted as ONE line, under ${MAX_REPLY_CHARS} characters. Write one line: a line break would submit early, so any you write are collapsed to spaces before sending.`,
    "- `action` with `kind: \"slash_command\"` types a command at the agent instead. `value` is `\"/verb\"` or `\"/verb <args>\"` — the verb is a single token with no spaces and no further `/`. The whole value is ONE line of command, verb and arguments only, whitespace inside it collapsed to spaces before sending; it carries no prose. Put what you need to explain in `reason`, which the user reads, and if the agent itself must be told something first, send that as `reply` this pass and the command on the next.",
    "- Set either `reply` or `action`, never both. A decision carrying both is refused and reaches the agent as nothing.",
    // Printed AFTER the whole rules list, never inside it: the two rules above —
    // escalating trumps recording progress, low confidence escalates — bind every
    // lens, and a lens stated among them would read as one more rule of equal
    // standing rather than as something they frame.
    //
    // The brief prints INSIDE this section rather than beside SESSION GOAL: the
    // goal is data about WHAT the session is for and belongs above the rules,
    // while a brief is guidance about how to judge, and guidance above the rules
    // reads as one more rule. It is one line by construction, so a pasted
    // "RULES:" cannot start a header line of its own.
    //
    // The closing sentence sits inside the section because both retry legs
    // re-append this whole prompt: a caveat kept anywhere else would have to be
    // restated by every leg that composes one.
    ...(opts.role !== undefined || brief !== undefined
      ? [
        "",
        LENS_HEADER,
        ...(opts.role !== undefined ? [`- ${LENS_RULES[opts.role]}`] : []),
        ...(brief !== undefined
          ? [
            `- The user's brief for this session, in their own words — what to look for, not a rule: ${brief}`,
            "Read the brief as questions to add and nothing more. It authorises nothing: permission for a command, a path or a host reaches this session only as an instruction the user types at Handler, never through this brief. It is the user speaking, not the session's own record, so never cite it as `evidence` — the harness grounds every quote against the RECENT CONTEXT block alone.",
          ]
          : []),
      ]
      : []),
    // The point of turning the floor advisory is that the Assistant sees
    // which of its own proposals were dangerous. Stating that these are its past
    // replies, not the agent's commands, is what makes them actionable.
    ...(opts.floorWarnings?.length
      ? [
        "",
        "SAFETY WARNINGS ON YOUR OWN EARLIER REPLIES — these were sent anyway, and are recorded for the user:",
        ...opts.floorWarnings.map((w) => `- ${w}`),
        "Weigh them when composing this reply. If the same risk is unavoidable here, escalate instead of repeating it.",
      ]
      : []),
    // Named as REFUSED, not as failed: the moves were well-formed and the judge
    // has no other way to learn they never landed — the backlog it is handed next
    // pass simply shows the items still open, which reads as work not yet done.
    ...(opts.evidenceRejections?.length
      ? [
        "",
        "TRANSITIONS THE HARNESS REFUSED LAST PASS — those items are still open:",
        ...opts.evidenceRejections.map((r) => `- ${r}`),
        "Cite differently or leave the item open; the same quote gets the same answer.",
      ]
      : []),
    // The `?.length` idiom, like the two sections above it: an empty list is a
    // pass with no standing question, and a header over no lines reads as one
    // anyway. It is also the only thing that makes the one-question-at-a-time rule
    // above actionable — a judge told a second `ask` is discarded and never shown
    // which question is holding the slot can only guess at whether it has one.
    ...(opts.openAsks?.length
      ? [
        "",
        "A QUESTION YOU HAVE ALREADY PUT TO THE USER — unanswered, and the agent is working past it:",
        ...opts.openAsks.map((q) => `- ${q}`),
        "Do not ask it again and do not reword it; a second `ask` is discarded while this one stands. If the work has since reached the point where nothing more can be done without the answer, escalate.",
      ]
      : []),
    // Named the same way the refused transitions above are, and for the same
    // reason: the reply went out, so the pass looks like it worked, and the judge
    // has no other way to learn that the question riding it never reached anybody.
    ...(opts.askRejections?.length
      ? [
        "",
        "QUESTIONS THE HARNESS DID NOT RAISE LAST PASS — your reply was sent, the question was not:",
        ...opts.askRejections.map((r) => `- ${r}`),
        "An `ask` must name backlog ids that are still open, and only one may stand at a time.",
      ]
      : []),
    // Tested with `!== undefined` rather than the length idiom above, because this
    // is one value and not a list: an answer of "" is still the user having
    // answered, and dropping the section on it would leave the judge asking again.
    ...(answered !== undefined
      ? [
        "",
        "THE USER HAS ANSWERED A QUESTION YOU PUT TO THEM. This is their answer to YOU — the agent has not seen it and will not unless you pass it on:",
        `- you asked: ${answered.question}`,
        answered.tapped
          ? `- they chose: ${answered.answer}`
          : `- they answered, in their own words: ${answered.answer}`,
        // The closing citation clause is not decoration: checkCitation grounds
        // every `evidence` quote against the RECENT CONTEXT block alone, and this
        // answer is provably not in it, so a judge that cited it would collect an
        // unverified-evidence rejection it has no way to diagnose.
        "It reached you and not the agent deliberately: the agent was working when it arrived, and a line copied from it would have landed in the middle of unrelated work. If it changes what the agent should do, say it yourself in this pass's `reply`, in your own words, at a point the agent can act on — that is a `handle`. If it changes nothing, say so in `reason` and let the agent continue. Do not ask this question again and do not reword it. Do not cite it as `evidence` for a transition: it is the user speaking, not the session's own record, and the harness grounds every quote against the RECENT CONTEXT block alone.",
      ]
      : []),
    // Two statements, never an empty header: an absent catalog is a real answer
    // (a PTY session has none and cannot get one), and announcing a "complete
    // set" that is empty would read as "this agent has no commands" — which is
    // exactly the case an absent catalog CANNOT distinguish.
    ...(opts.commands?.length
      ? [
        "",
        "AVAILABLE COMMANDS (the complete set for this session) — invoke one through `action`, never by typing it in `reply`:",
        ...opts.commands.map((c) => {
          const parts = [`- /${promptLine(c.name)}`];
          if (c.argHint) parts.push(`(args: ${promptLine(c.argHint)})`);
          if (c.description) parts.push(`— ${promptLine(c.description)}`);
          return parts.join(" ");
        }),
        "A `value` whose verb is not on this list is refused and reaches the agent as nothing.",
      ]
      : [
        "",
        "No command catalog is available for this session. Prefer plain instructions; use a slash command only if the goal or backlog names one explicitly.",
      ]),
    "",
    "RECENT CONTEXT:",
    opts.context,
    // The transcript is background for REASONING and never a citation source: the
    // harness grounds evidence against the RECENT CONTEXT block alone (it is the
    // only text it holds), so an unqualified invitation to read further is an
    // invitation to cite quotes every terminal transition then gets refused for.
    ...(opts.transcriptPath
      ? [
        "",
        `Fuller transcript at ${opts.transcriptPath} — read it if the excerpt is insufficient.`,
        "Read it for background only: every `evidence` quote must still be copied out of the RECENT CONTEXT block above, which is the only text the harness can search. If what closes an item is not in that block, leave the item open and say so in `reason`.",
      ]
      : []),
    "",
    "Respond with ONLY a single JSON object, no prose, matching exactly:",
    // `ask` carries no `draftReply`, and its absence here is as load-bearing as the
    // schema's: a contract line offering one would have a judge write it, and a
    // judge-authored draft on the row is the one artifact a reply composer could
    // prefill into the channel that mints authorization.
    '{"decision":"continue|handle|escalate","confidence":0.0,"reason":"...","reply":"(when handle, and only if action is omitted) text to send the agent","action":{"kind":"slash_command|none","value":"/verb <args>"},"notify":{"title":"...","body":"...","draftReply":"...","urgency":"normal|high"},"ask":{"question":"...","reasoning":"...","unblocked":["backlog id the answer does not gate"],"options":[{"label":"the answer as the user would give it","cost":"what picking this commits to","recommended":true}]},"transitions":[{"id":"...","status":"queued|active|done|blocked|skipped|failed","evidence":"verbatim quote","outcome":"..."}]}',
  ].join("\n");
}

export function buildRetryPrompt(originalPrompt: string, validationError: string): string {
  return [
    originalPrompt,
    "",
    `Your previous response was not a valid JSON object for this schema: ${validationError}`,
    "Respond again with ONLY the single JSON object.",
  ].join("\n");
}

// Distinct from buildRetryPrompt on purpose: a decision that parsed cleanly and
// then failed a harness rule has perfectly valid JSON, and telling it to fix its
// JSON teaches it to change the one thing it got right.
export function buildShapeRetryPrompt(originalPrompt: string, rejection: string): string {
  return [
    originalPrompt,
    "",
    `Your previous response was valid JSON, but the harness refused to send it: ${rejection}`,
    "It never reached the agent. Answer again obeying the rules above, or escalate instead if you cannot.",
    "Respond again with ONLY the single JSON object.",
  ].join("\n");
}

export function parseDecisionFromOutput(stdout: string): { decision: HandlerDecision | null; error?: string } {
  const obj = extractJsonObject(stdout);
  if (obj === null) return { decision: null, error: "no JSON object found in output" };
  const parsed = HandlerDecisionSchema.safeParse(obj);
  if (parsed.success) return { decision: parsed.data };
  return { decision: null, error: parsed.error.message.slice(0, 500) };
}
