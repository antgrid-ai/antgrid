// bridge/tests/handler/json-extract.test.ts
import { test, expect } from "bun:test";
import { extractJsonObject } from "../../src/handler/json-extract";
import { parseDecisionFromOutput } from "../../src/handler/decision";

test("extracts a bare object", () => {
  expect(extractJsonObject('{"a":1}')).toEqual({ a: 1 });
});

test("stops at the object's own closing brace, not a later stray one", () => {
  // The greedy /\{[\s\S]*\}/ this replaced spanned to the LAST "}" in the output,
  // swallowing the trailing sentence and making JSON.parse fail.
  expect(extractJsonObject('Decision:\n{"a":1}\nUse {braces} carefully.')).toEqual({ a: 1 });
});

test("keeps nested objects intact", () => {
  expect(extractJsonObject('noise {"a":{"b":{"c":1}},"d":2} noise')).toEqual({ a: { b: { c: 1 } }, d: 2 });
});

test("ignores braces inside string values", () => {
  expect(extractJsonObject('{"reason":"use } and { carefully","ok":true}'))
    .toEqual({ reason: "use } and { carefully", ok: true });
});

test("ignores escaped quotes when tracking string state", () => {
  expect(extractJsonObject('{"reason":"he said \\"}\\" loudly","ok":true}'))
    .toEqual({ reason: 'he said "}" loudly', ok: true });
});

test("skips an unterminated leading brace and finds the next complete object", () => {
  expect(extractJsonObject('{ oops unterminated\n{"a":1}')).toEqual({ a: 1 });
});

test("skips a balanced-but-unparseable candidate and keeps scanning", () => {
  expect(extractJsonObject('{not json at all}\n{"a":1}')).toEqual({ a: 1 });
});

test("returns null when no object is present", () => {
  expect(extractJsonObject("no json here")).toBeNull();
});

test("a real decision survives trailing prose containing braces", () => {
  const stdout = [
    "Here is my decision:",
    '{"decision":"continue","confidence":0.9,"reason":"tests still running"}',
    "Let me know if {anything} else is needed.",
  ].join("\n");
  const r = parseDecisionFromOutput(stdout);
  expect(r.decision?.decision).toBe("continue");
  expect(r.error).toBeUndefined();
});

test("a decision reporting transitions survives trailing prose containing braces", () => {
  const stdout = [
    "Here is my decision:",
    '{"decision":"continue","confidence":0.9,"reason":"tests passed","transitions":[{"id":"i1","status":"done","evidence":"3 passed"}]}',
    "Adjust {as needed}.",
  ].join("\n");
  expect(parseDecisionFromOutput(stdout).decision?.transitions?.[0].id).toBe("i1");
});
