// Screens are codex-cli 0.164.0's own render snapshots (codex-rs/tui at
// rust-v0.164.0), matched the way bridge/src/submit-gate.ts matches them: any
// declared prompt as a substring of one visible row.
import { describe, expect, it } from "bun:test";
import { agentSpec } from "../src/agents/registry";

const prompts = agentSpec("codex")?.startupPrompts ?? [];
const showsStartupPrompt = (screen: string) =>
  screen.split("\n").some((row) => prompts.some((prompt) => row.includes(prompt)));

const TRUST = `
  Folder access
  /workspace/project

  Trust this folder? Codex can read, edit, and run files here,
  subject to your permission settings. Folder settings can run code
  automatically, even without a model request. Continue only if you
  trust these files. Your trust decision will be saved.

› 1. Trust and continue
  2. Quit

  enter continue and create sandbox · esc quit`;

// Paste events are ignored on this screen and Enter takes the highlighted
// "Update now", so a submit updates the CLI and exits it.
const UPDATE = `
  Update available · 0.0.0 → 9.9.9
  Release notes: https://github.com/openai/codex/releases/latest

› 1. Update now (runs \`npm install -g @openai/codex\`)
  2. Skip
  3. Skip until next version

  enter continue · esc skip`;

const UPDATE_NARROW = `
  Update available · 0.0.0
  → 9.9.9
  Release notes:
  https://github.com/opena
  i/codex/releases/latest
↑
› 3. Skip until next version

  enter continue · esc
  skip`;

const HOOKS_REVIEW = `
  Hooks need review
  2 hooks are new or changed.
  Hooks can run outside the sandbox after you trust them.

› 1. Review hooks
  2. Trust all and continue
  3. Continue without trusting (hooks won't run)

  enter confirm · esc skip`;

// The in-session notice is history, not a choice: holding submits behind it
// would stall every session started while an update is pending.
const UPDATE_NOTICE = `
╭──────────────────────────────────────────────────────────────────╮
│ ✨ Update available! 0.0.0 -> 9.9.9                              │
│ Run npm install -g @openai/codex to update.                      │
│                                                                  │
│ See full release notes:                                          │
│ https://github.com/openai/codex/releases/latest                  │
╰──────────────────────────────────────────────────────────────────╯

›  Ask Codex to do anything`;

describe("codex startup prompts", () => {
  it.each([
    ["folder trust", TRUST],
    ["update prompt", UPDATE],
    ["update prompt at a narrow width", UPDATE_NARROW],
    ["hooks review", HOOKS_REVIEW],
  ])("holds submits behind the %s", (_name, screen) => {
    expect(showsStartupPrompt(screen)).toBe(true);
  });

  it("does not hold submits behind the in-session update notice", () => {
    expect(showsStartupPrompt(UPDATE_NOTICE)).toBe(false);
  });
});
