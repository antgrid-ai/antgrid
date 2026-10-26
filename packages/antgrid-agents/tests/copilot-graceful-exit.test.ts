import { expect, test } from "bun:test";
import { AGENTS } from "../src/agents/registry";
import { ETX } from "../src/agents/types";

test("github-copilot asks to exit with two Ctrl-C presses", () => {
  // The platform default is one press, which Copilot answers with
  // "ctrl+c again to exit" and nothing more, so every stop ran out the grace.
  expect(AGENTS["github-copilot"].gracefulExit?.keystrokes).toEqual([ETX, ETX]);
});
