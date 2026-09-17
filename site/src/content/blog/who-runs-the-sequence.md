---
title: "Your coding agent has a plan. Who runs the sequence?"
description: "Start with your coding agent, then tell Handler what's left and when to ask you. It checks what the agent reports and asks for evidence before moving on."
publishedAt: 2026-09-18
topic: proof
author: "Bharath Mohan"
draft: false
featured: true
claimsVerifiedAt: "583e988"
---

Your coding agent says the implementation is finished. You read the response, check whether it did what you asked, and write the next prompt: "review the code, then run the tests". Sometimes you have to go back first: "you haven't checked the thing I asked you to check".

If you check each step before letting the agent continue, deciding what happens next is still your job. A good plan helps you make the call. You still have to be there to make it.

We built Handler in Antgrid to take on those follow-ups. Start a task with your coding agent. When you're ready, tell Handler what's left, how to proceed and when to ask you. It checks what the agent reports against your instructions and asks for evidence before moving on. It notifies you when it needs your input or you've told it to check with you.

[Antgrid's desktop beta](https://antgrid.ai/download) is available for Windows, macOS and Linux, with Handler included free during the beta. The companion phone app is [available by invite](mailto:contact@radhaai.com?subject=Antgrid%20mobile%20invite), through TestFlight and Play internal testing.

## One handoff, end to end

The useful question is what happens when the agent says it's finished and the evidence isn't there.

The task is a small TypeScript module with two known pieces of drift: `cartTotal` counts cart lines instead of summing money, and `checkout` throws bare `Error`s where the README promises a typed `CartError` naming the offending field.

I started the session, then armed Handler before typing anything, and wrote the rest as one instruction:

> Next: make `checkout()` raise a `CartError` naming the offending field instead of a bare `Error`, then cover both refusals with tests, then bring `README.md` in line with what the code actually does. Don't call an item done until you have run `bun test` and `bunx tsc --noEmit` and shown me both outputs. Ask me before you change anything outside `src/`, `tests/` and `README.md`.

Handler turned that into an ordered backlog of five entries and ran with the "Proof it works" lens and Claude Code as judge. Three of the entries are phases; two are the conditions — the evidence rule, and the checkpoint asking to be consulted before anything outside those three directories changes.

Then I gave the agent the first task. Handler runs at the agent's pauses, so its first pass came at the end of that turn, found nothing in the backlog it could close, and let the agent continue — which, with the task finished, meant nothing happened. It took one more line from me to produce the next pause. On that one Handler sent the whole sequence on to the agent itself, and I stopped typing.

<figure>
  <img src="./assets/who-runs-the-sequence/handoff-activity.png" alt="The Handler tab beside the agent's terminal at the end of the run. In the terminal, the agent reports that README.md already described the new behaviour, Handler replies asking it to quote the specific lines, the agent quotes README lines 5 to 7, Handler confirms the quote matches the implementation and asks for a commit, and the commit lands. The activity feed beside it lists the run newest first: wrapped up, the README item closed on the quote, the request for that quote, three more items closed with the evidence for each, a judge timeout and its retry, the instruction that started the work, and armed." />
  <figcaption>The run described above, as it happened: the agent's turn on the left, Handler's decisions on the right. The account address in the sidebar is masked; nothing else is edited.</figcaption>
</figure>

Keep an eye on the condition for moving on. A confident answer and a satisfied condition can look very different.

The agent did all three phases in one turn, ran both commands, and reported:

> `README.md` — already described this exact behavior, so no change was needed.

Handler closed the two phases the test and type-check output covered, and held the third:

> CartError throw and refusal tests are backed by concrete test/tsc output, but the README item rests solely on the agent's unverified claim that no change was needed — asking for the actual matching excerpt before closing it, per the verify-before-trusting rule.

What it sent back:

> Before marking the README item done, quote the specific lines in `README.md` that already describe `checkout()` raising a `CartError` naming the offending field, so we can confirm the doc genuinely matches the new implementation rather than relying on your assessment alone.

The agent went and looked:

> Quoting directly from `README.md`:
>
> ```
> 5:- `cartTotal(lines)` returns the total payable for a cart.
> 6:- `checkout(email, lines)` refuses an empty cart and a malformed email,
> 7:  raising a `CartError` that names the offending field.
> ```

Handler closed the item on that, and said what to do next:

> Agent quoted README lines 5-7 which match the CartError/field behavior in `src/checkout.ts`, satisfying the review request.
>
> Confirmed, the README quote matches the implementation. Please commit these changes with a clear message.

From that point Handler ran the sequence through to the wrap-up without me: five entries closed over three minutes, one judge call that timed out and retried thirty seconds later, and no question that needed answering. Two lines of mine started it — the task, and the nudge that produced the pause Handler acted on — and none after. The agent's original claim about the README turned out to be true; it was refused for being unevidenced, not for being wrong.

That is the handoff we want to make easier to leave with Handler. You set the condition in advance, then inspect how it was applied.

## The workflow doesn't run itself

You may already use plan mode, spec files, skills or a sequence of prompts. Those give the work a shape. Tests and hooks can check specific outcomes. Keep using them.

The remaining job, when your workflow includes human review between phases, is deciding what the response means for the next step. Is the research sufficient to plan a change? Did the validation actually test the assumption? Does the result justify moving on?

There are two questions at each boundary:

1. Did the agent produce a response?
2. Did that response satisfy the phase condition?

A notification answers the first question. The second one is the job.

In that workflow, you're the sequencer: you judge the result and decide what comes next. If the agent is waiting for your next instruction while you're in a meeting, the work waits too. Handler gives you a way to delegate those routine decisions while keeping calls about your intent or permission with you.

## Tell Handler what's left

Antgrid brings your coding-agent sessions across your machines into one app. You choose when to hand over: after research, after planning, partway through implementation, or wherever you want to stop writing the follow-ups yourself. Arm Handler on that running session.

Write the remaining steps in plain text, including how you want the agent to proceed, the evidence needed for each step, when to ask you and where to stop. Handler turns those instructions into an ordered list you can inspect and edit. It supervises the existing session; it doesn't launch a new job.

<figure>
  <img src="./assets/who-runs-the-sequence/arm-handler-sheet.png" alt="The Arm Handler sheet. Under the heading What to do while you're away, it repeats the goal the session already started with, then a plain-text box holding the instruction for the rest of the work, listing the steps in order and the evidence required before any of them counts as done. Claude Code is picked as the judge below the box. Under What Handler weighs, six lens chips with Proof it works selected, above a line explaining that the lens asks the agent to run what proves an item and show the result, and names what is still unverified." />
  <figcaption>The instruction is the one quoted earlier, typed as prose. The judge and the lens are the only two choices on the sheet.</figcaption>
</figure>

You choose which installed agent CLI does the judging. When the working agent pauses or asks a question, Handler reads the recent context and decides whether to let it continue, reply, or ask you.

Handler can ask both sides. It asks the agent for missing facts, evidence or options. It notifies you when it needs information only you can provide, a decision or permission. You can also set checkpoints of your own, such as "ask me before starting the security review". Instructions like that can only make Handler stricter, never looser. Work that depends on your answer waits; Handler can keep the agent working on other listed steps that don't depend on it.

With the companion phone app, you can respond away from the desk. Everything between your devices is end-to-end encrypted, and the relay forwards ciphertext and holds no keys.

When a phase closes, Handler tells the same running agent what's needed next. When every item is resolved and no question is waiting on you, it records a wrap-up and disarms.

## What makes a phase done?

Handler must cite evidence from the session context before closing an item. That might be test output, an exit code or a diff. Antgrid checks that the quotation appears in the context Handler was shown. An unsupported citation is rejected and the item stays open.

This check has a specific limit: a real quotation can still be about the wrong thing. Handler can misinterpret evidence or make the wrong call about continuing. Its decisions and the evidence it cited remain visible for you to review.

That's why we'd start with one bounded task and watch the first handoff. You should be able to compare its judgement with the call you would have made.

Handler's judgement is a call to an agent CLI already on your machine, on your own provider account. There's no Antgrid model service judging your session, and the free beta doesn't make those calls free.

Handler also limits consecutive replies without human input and escalates when that limit is reached or it repeats a reply. It doesn't have an unlimited conversation with the agent.

An isolated session can give the work its own checkout and branch. It still uses the same machine, shell and credentials, so treat it as a separate workspace rather than a security sandbox.

The [Handler implementation](https://github.com/antgrid-ai/antgrid/tree/583e988/bridge/src/handler) is available to inspect. The app, bridge, site and shared packages are MPL-2.0; the hosted relay and web service are ELv2.

## Try one handoff

Choose a small feature and start working on it with your agent in Antgrid. Do as much as you want before handing over. For example, finish the research and agree on a plan, then ask Handler to guide the agent through implementation and review.

Here's an example to adapt to your repository:

> Implement the agreed plan. Show the changed files and passing test output before moving on. Then review the code against the plan, followed by a security review. For each review, report findings with file references, fix issues within scope and rerun the relevant tests. Compact context between phases, preserving the plan, progress and remaining instructions. Finally, smoke-test the feature and show the steps and results. Ask me before starting the security review or making decisions outside the plan. Stop with a summary of the changes, checks and anything unresolved; don't commit or deploy.

Planning is just the handoff point in this example, not a requirement. Adapt the sequence and checks to your task and the commands your agent supports. Watch the first transition: does Handler ask for missing evidence and send the next instruction at the right point? Review the final record for the evidence behind each completed step and anything left unresolved.

[Download Antgrid for Windows, macOS or Linux](https://antgrid.ai/download). Handler is included free during the beta, with no card required. The [getting-started guide](https://antgrid.ai/get-started) covers setup.

Handler will be a Pro feature once paid plans are live. Nothing switches off without warning, Pro starts with a free trial, and the free plan stays free. The current terms are on the [pricing page](https://antgrid.ai/pricing).

We're still learning how well Handler's judgement holds up across other people's tasks. After your first run, [tell us how the handoff went](https://antgrid.ai/support). If it made the wrong call, the condition you set and the decision it made are the most useful things to share.

We built Handler because the gap between phases kept bringing us back to the desk. Try it on one of those gaps in your own workflow.

