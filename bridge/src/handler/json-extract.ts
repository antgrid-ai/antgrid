// bridge/src/handler/json-extract.ts

// Judges are told to reply with ONLY a JSON object, but models routinely wrap it
// in prose ("Here's my decision: {...}. Let me know if {anything} else!"). A
// greedy /\{[\s\S]*\}/ spans from the first "{" to the LAST "}" anywhere in the
// output, so one stray brace in a trailing sentence swallows it and JSON.parse
// fails — discarding a perfectly good decision and forcing a retry, then a
// fail-closed escalation. Scan brace-balanced candidates instead (skipping
// braces inside string literals) and return the first one JSON.parse accepts,
// so a balanced-but-invalid candidate can't shadow a real object after it.
export function extractJsonObject(text: string): unknown | null {
  for (let start = text.indexOf("{"); start !== -1; start = text.indexOf("{", start + 1)) {
    let depth = 0;
    let inString = false;
    let escaped = false;
    for (let i = start; i < text.length; i++) {
      const ch = text[i];
      if (inString) {
        if (escaped) escaped = false;
        else if (ch === "\\") escaped = true;
        else if (ch === '"') inString = false;
        continue;
      }
      if (ch === '"') inString = true;
      else if (ch === "{") depth++;
      else if (ch === "}" && --depth === 0) {
        try { return JSON.parse(text.slice(start, i + 1)); } catch { break; }
      }
    }
    // Unterminated or unparseable from this "{" — a later one may still open a
    // complete object.
  }
  return null;
}
