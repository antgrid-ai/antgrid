---
title: "Your coding agent has a plan. Who runs the sequence?"
description: "Hand over the follow-ups on a long-running coding task. Handler checks the agent's responses, asks for evidence and notifies you when it needs your input."
publishedAt: 2026-09-18
topic: proof
author: "Bharath Mohan"
draft: false
featured: true
claimsVerifiedAt: "583e988"
---

The hard part of a long-running agent task is staying available for every pause.

Your coding agent says the implementation is finished. You read the response, check whether it did what you asked, and write the next prompt: "review the code, then run the tests". Sometimes you have to go back first: "you haven't checked the thing I asked you to check". Then you wait, and do it again.

For a quick task, you can reply yourself and move on. When the work stretches over hours, those occasional follow-ups keep you tied to the session. A good plan says what comes next, but you still have to be there to prompt it, read the answer and decide whether it counts.

We built Antgrid for working with coding agents across long-running tasks. Its Handler feature takes on the follow-ups when you're ready to step away.

Start the task with your coding agent and do as much as you want together. Then tell Handler what's left, how to proceed and when to ask you. It checks the agent's responses against your instructions, asks for missing evidence and guides the remaining work. It notifies you when it needs your input or reaches a checkpoint you've set.

[Antgrid's desktop beta](https://antgrid.ai/download) is available for Windows, macOS and Linux, with Handler included free during the beta. The companion phone app is [available by invite](mailto:contact@radhaai.com?subject=Antgrid%20mobile%20invite), through TestFlight and Play internal testing.

## A real run: checking before closing

The useful question is what happens when the agent says it's finished and the evidence isn't there. This run shows Handler asking for that evidence before closing an item. It doesn't show a separate checkpoint between every phase: the agent did the implementation, tests and documentation check in one turn.

The task is a small TypeScript module with two known pieces of drift: `cartTotal` counts cart lines instead of summing money, and `checkout` throws bare `Error`s where the README promises a typed `CartError` naming the offending field.

I started the session, then armed Handler before typing anything, and wrote the rest as one instruction:

> Next: make `checkout()` raise a `CartError` naming the offending field instead of a bare `Error`, then cover both refusals with tests, then bring `README.md` in line with what the code actually does. Don't call an item done until you have run `bun test` and `bunx tsc --noEmit` and shown me both outputs. Ask me before you change anything outside `src/`, `tests/` and `README.md`.

Handler turned that into five tracked entries: three steps and two conditions covering evidence and permission. I selected "Proof it works" as the lens and Claude Code as the judge.

Then I gave the agent the first task. Handler didn't pick up the remaining sequence at the first pause. I sent one follow-up to produce another pause; Handler then sent the remaining instructions to the agent. I didn't type again. That extra nudge is a limitation of this run, not the handoff experience we're aiming for.

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

The agent's original claim about the README turned out to be true; it was refused for being unevidenced, not for being wrong. Handler closed the item on the quoted lines:

> Agent quoted README lines 5-7 which match the CartError/field behavior in `src/checkout.ts`, satisfying the review request.
>
> Confirmed, the README quote matches the implementation. Please commit these changes with a clear message.

The commit request needs scrutiny too. The instruction quoted above didn't ask Handler to commit, yet it requested a commit and the agent made one. The context shown here doesn't establish permission for that extra action, so we don't count it as a successful handoff. Checking evidence and staying within the requested scope are separate responsibilities.

The activity record shows five entries closed over three minutes, including one judge timeout followed by a retry thirty seconds later. After my initial task and follow-up, no further input was needed. That demonstrates an evidence check and a wrap-up, with rough edges visible. It isn't proof of a clean, phase-by-phase handoff.

## The workflow doesn't run itself

You may already use plan mode, spec files, skills or a sequence of prompts. Those give the work a shape. Tests and hooks can check specific outcomes. Keep using them.

If you review the work between steps, there are two different questions:

1. Did the agent produce a response?
2. Did it show what you required before the next step?

A notification answers the first question. The second one is the job.

You can put the whole sequence in your agent's prompt. Handler adds a separate judgement of what the agent reports against your instructions, with a record of the evidence it used. That judgement can be wrong too. The point is to make the follow-up check explicit and inspectable, not to replace your judgement with a guarantee.

## Tell Handler what's left

Antgrid brings your coding-agent sessions across your machines into one app. You choose when to hand over: after research, after planning, partway through implementation, or wherever you want to stop writing the follow-ups yourself. Arm Handler on that running session.

Write the remaining steps in plain text, including how you want the agent to proceed, the evidence needed for each step, when to ask you and where to stop. Handler turns those instructions into an ordered list you can inspect and edit. It supervises the existing session; it doesn't launch a new job.

<figure>
  <img src="./assets/who-runs-the-sequence/arm-handler-sheet.png" alt="The Arm Handler sheet. Under the heading What to do while you're away, it repeats the goal the session already started with, then a plain-text box holding the instruction for the rest of the work, listing the steps in order and the evidence required before any of them counts as done. Claude Code is picked as the judge below the box. Under What Handler weighs, six lens chips with Proof it works selected, above a line explaining that the lens asks the agent to run what proves an item and show the result, and names what is still unverified." />
  <figcaption>The instruction is the one quoted earlier, typed as prose. The judge and the lens are the only two choices on the sheet.</figcaption>
</figure>

You choose which installed agent CLI does the judging. When the working agent pauses or asks a question, Handler reads the recent context and decides whether to let it continue, reply, or ask you.

Handler can ask both sides. It asks the agent for missing facts, evidence or options. It notifies you when it needs information only you can provide, a decision or permission. You can also set checkpoints of your own, such as "ask me before starting the security review". Instructions like that can only make Handler stricter, never looser. Work that depends on your answer waits; Handler can keep the agent working on other listed steps that don't depend on it.

With the companion phone app, you can respond away from the desk. Terminal output, prompts and file contents sent through the relay are end-to-end encrypted between your machine and connected devices. The relay forwards them without the keys to read them.

When a phase closes, Handler tells the same running agent what's needed next. When every item is resolved and no question is waiting on you, it records a wrap-up and disarms.

## What makes a phase done?

Handler must cite evidence from the session context before closing an item. That might be test output, an exit code or a diff. Antgrid checks that the quotation appears in the context Handler was shown. An unsupported citation is rejected and the item stays open.

This check has a specific limit: a real quotation can still be about the wrong thing. Handler can misinterpret evidence or make the wrong call about continuing. Its decisions and the evidence it cited remain visible for you to review.

That's why we'd start with one bounded task and watch the first handoff. You should be able to compare its judgement with the call you would have made.

Handler also limits consecutive replies without human input and escalates when that limit is reached or it repeats a reply. It doesn't have an unlimited conversation with the agent.

You can inspect the [Handler implementation](https://github.com/antgrid-ai/antgrid/tree/583e988/bridge/src/handler). The [licensing guide](https://github.com/antgrid-ai/antgrid/blob/583e988/LICENSING.md) explains the MPL-2.0 and ELv2 split.

## Try one handoff

Choose a small feature and start working on it with your agent in Antgrid. Do as much as you want before handing over. For example, finish the research and agree on a plan, then ask Handler to guide the agent through implementation and review.

Here's an example to adapt to your repository:

> 1. Implement the agreed plan. Show the changed files and passing test output before moving on.
> 2. Review the code against the plan. Report findings with file references, fix issues within scope and rerun the relevant tests.
> 3. Ask me before starting the security review. Apply the same reporting, fixing and testing requirements to that review.
> 4. Smoke-test the feature and show the steps and results.
> 5. Stop with a summary of the changes, checks and anything unresolved. Don't commit or deploy.
>
> Between phases, compact context while preserving the plan, progress and remaining instructions. Ask me before making decisions outside the plan.

Adapt the steps and checks to your task and the commands your agent supports. Watch the first transition: does Handler ask for missing evidence, stay within your instructions and send the next instruction at the right point? Review the final record for anything left unresolved.

[Download Antgrid for Windows, macOS or Linux](https://antgrid.ai/download). Handler is included free during the beta, with no card required. The [getting-started guide](https://antgrid.ai/get-started) covers setup.

Handler uses an installed agent CLI to judge the session on your own provider account. Your provider's usage charges or limits still apply. Handler will be a Pro feature once paid plans are live; see the [beta and pricing terms](https://antgrid.ai/pricing).

We built Handler because the gap between phases kept bringing us back to the desk. Try one bounded handoff, inspect the evidence, and [tell us where its judgement held up or failed](https://antgrid.ai/support). The instruction you gave and the decision Handler made are the most useful things to share.
