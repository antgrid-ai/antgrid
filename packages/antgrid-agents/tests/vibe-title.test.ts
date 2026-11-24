import { expect, test } from "bun:test";
import { normalizeVibeOscTitle } from "../src/agents/mistral-vibe/title";

test("Vibe 3 OSC titles keep the session title through every turn state", () => {
  // The sequence a 3.1.4 session publishes across one turn.
  expect(["Vibe", ">> Vibe", "Session Title", ">> Session Title", "? Session Title", "Session Title - Task Complete"].map(normalizeVibeOscTitle))
    .toEqual(["", "", "Session Title", "Session Title", "Session Title", "Session Title"]);
  expect(normalizeVibeOscTitle("Fix >> parsing - Task failed")).toBe("Fix >> parsing");
});
