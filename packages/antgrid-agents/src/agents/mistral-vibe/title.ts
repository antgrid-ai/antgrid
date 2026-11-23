// Vibe 3's OSC 0 title carries turn state: ">> " while working, "? " while
// blocked, and " - Task Complete" / " - Action Required" / " - Task failed"
// once settled. "Vibe" alone is the title before the session has one.
const STATE_PREFIX = /^(?:>> |\? )/;
const STATE_SUFFIX = / - (?:Task Complete|Action Required|Task failed)$/;

export function normalizeVibeOscTitle(raw: string): string {
  const title = raw.replace(STATE_PREFIX, "").replace(STATE_SUFFIX, "").trim();
  return title === "Vibe" ? "" : title;
}
