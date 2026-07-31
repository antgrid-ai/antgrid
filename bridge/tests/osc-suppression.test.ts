// Muting a terminal's OSC scanner takes two signals that must agree: the spec's
// static notificationSource/titleSource (INTENT — "this agent reports through an
// injected plugin") and the spawn's LaunchAugmentation.notificationsInjected
// (OUTCOME — "the injection actually landed"). Getting the combination wrong is
// invisible: too eager and the session goes silent, too shy and every event
// arrives twice.
import { describe, expect, test } from "bun:test";
import { suppressesOscNotifications, suppressesOscTitle } from "../src/known-agents";

/** Expected suppression for outcome [true, false, absent], in that order. */
type ByOutcome = [boolean, boolean, boolean];
const OUTCOMES: Array<boolean | undefined> = [true, false, undefined];

const EXPECTED: Record<string, { notifications: ByOutcome; title: ByOutcome }> = {
  "claude-code": { notifications: [true, false, true], title: [true, false, true] },
  codex: { notifications: [true, false, true], title: [true, false, true] },
  opencode: { notifications: [true, false, true], title: [true, false, true] },
  // Plugin notifications, but no structured title source — gating its OSC title
  // would kill auto-naming outright.
  "cursor-agent": { notifications: [true, false, true], title: [false, false, false] },
  // The mirror case: OSC notifications, structured title from the materialized
  // sessionStart hook.
  "github-copilot": { notifications: [false, false, false], title: [true, false, true] },
  kilo: { notifications: [false, false, false], title: [false, false, false] },
  kimi: { notifications: [false, false, false], title: [false, false, false] },
  "mistral-vibe": { notifications: [false, false, false], title: [false, false, false] },
  // An antgrid.yaml `agent.name` the registry has never heard of: no intent, so
  // no outcome can mute it.
  "some-future-agent": { notifications: [false, false, false], title: [false, false, false] },
};

describe("osc suppression is intent AND outcome", () => {
  for (const [tool, expected] of Object.entries(EXPECTED)) {
    test(tool, () => {
      OUTCOMES.forEach((outcome, i) => {
        expect(suppressesOscNotifications(tool, outcome)).toBe(expected.notifications[i]!);
        expect(suppressesOscTitle(tool, outcome)).toBe(expected.title[i]!);
      });
    });
  }

  test("intent alone does not suppress once the injection reports failure", () => {
    // cursor-agent's hooks.json write is the live case: intent says plugin, the
    // outcome says the file never landed, so the scanner has to stay live.
    expect(suppressesOscNotifications("cursor-agent", true)).toBe(true);
    expect(suppressesOscNotifications("cursor-agent", false)).toBe(false);
  });

  test("outcome alone does not suppress without the matching intent", () => {
    // A successful injection on an osc-sourced agent still leaves the scanner
    // running: github-copilot's plugin supplies a title, never notifications.
    expect(suppressesOscNotifications("github-copilot", true)).toBe(false);
    expect(suppressesOscTitle("github-copilot", true)).toBe(true);
  });

  test("an absent outcome is 'nothing could fail here', not 'assume failure'", () => {
    // codex builds its injection out of argv alone — no file to write, so it
    // reports no outcome and its intent stands on its own. Only an explicit
    // false, from an injection we tried and could not complete, re-opens the
    // scanner; treating undefined as failure would un-mute codex and opencode
    // and double every notification they send.
    expect(suppressesOscNotifications("codex", undefined)).toBe(true);
    expect(suppressesOscTitle("codex", undefined)).toBe(true);
  });
});
