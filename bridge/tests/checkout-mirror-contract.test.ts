// The cross-language half of the checkout contract, deliberately living in the
// BRIDGE workspace: `app/test/project/checkout_contract_test.dart` pins the same
// mirror, but the only workflow that runs `flutter test` is path-filtered to
// `app/**`, so a bridge-only PR editing CHECKOUT_VARIABLE_MESSAGE_TYPES ships
// drift with a green required check. This suite runs inside `bun run --filter
// antgrid-bridge test`, which ci.yml runs unfiltered on every PR.
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { CHECKOUT_VARIABLE_MESSAGE_TYPES } from "../src/protocol";
import { CHECKOUT_REPLAY_TYPES } from "../src/message-bus";
import {
  CHECKOUT_KINDS,
  isIsolatedCheckoutKind,
  isManagedCheckoutKind,
  type CheckoutKind,
} from "../src/worktrees/checkout-types";

const DART_MIRROR = "app/lib/project/project_message_classification.dart";

const DRIFT_REASON =
  "bridge/src/protocol.ts CHECKOUT_VARIABLE_MESSAGE_TYPES and "
  + `${DART_MIRROR} kCheckoutVariableMessageTypes have drifted — a type missing `
  + "from the Dart set is never stamped with a checkoutId and is served from "
  + "main's working tree.";

/** Collect the members of one of the Dart mirror's flat single-quoted literal
 *  blocks, named by its `<const> = <String>{` marker. */
function dartSetLiteral(source: string, name: string): Set<string> {
  const marker = `${name} = <String>{`;
  const start = source.indexOf(marker);
  if (start < 0) throw new Error(`${marker} not found in the Dart mirror`);
  const end = source.indexOf("};", start);
  if (end < 0) throw new Error(`${marker} has no closing brace in the Dart mirror`);
  const block = source.slice(start + marker.length, end);
  return new Set([...block.matchAll(/'([^']+)'/g)].map((match) => match[1]!));
}

function dartCheckoutVariableTypes(source: string): Set<string> {
  return dartSetLiteral(source, "kCheckoutVariableMessageTypes");
}

function readDartSource(): string {
  return readFileSync(join(import.meta.dir, "../..", DART_MIRROR), "utf8");
}

function readDartMirror(): Set<string> {
  return dartCheckoutVariableTypes(readDartSource());
}

function readDartReplayMirror(): Set<string> {
  return dartSetLiteral(readDartSource(), "kCheckoutDurableReplayTypes");
}

const REPLAY_DRIFT_REASON =
  "the checkout-scoped slice of REPLAY_TYPES in bridge/src/message-bus.ts and "
  + `${DART_MIRROR} kCheckoutDurableReplayTypes have drifted — a type missing `
  + "from the Dart set is never retained per checkout, so a bundle built after "
  + "the connect-time replay never sees it and nothing re-sends it.";

function replayDrift(from: Iterable<string>, to: Set<string>): string[] {
  const missing = [...from].filter((type) => !to.has(type)).sort();
  return missing.length === 0 ? [] : [REPLAY_DRIFT_REASON, ...missing];
}

/** Bun prints only the compared values, so the reason has to ride inside them. */
function drift(from: Iterable<string>, to: Set<string>): string[] {
  const missing = [...from].filter((type) => !to.has(type)).sort();
  return missing.length === 0 ? [] : [DRIFT_REASON, ...missing];
}

describe("checkout mirror contract", () => {
  test("the Dart scraper reads a flat literal set and nothing around it", () => {
    // Proven against a fixture rather than the real file, so the vacuity guard
    // below is meaningful without ever mutating a source the app slice owns.
    const fixture = [
      "const Set<String> kUnrelatedBefore = <String>{ 'before:type' };",
      "",
      "const Set<String> kCheckoutVariableMessageTypes = <String>{",
      "  'alpha:one', 'alpha:two',",
      "  'beta:three',",
      "};",
      "",
      "const Set<String> kUnrelatedAfter = <String>{ 'after:type' };",
    ].join("\n");
    expect([...dartCheckoutVariableTypes(fixture)].sort())
      .toEqual(["alpha:one", "alpha:two", "beta:three"]);
  });

  test("the scrape of the real Dart mirror found a plausible set", () => {
    // A broken scrape would make both drift tests pass with an empty set.
    const dart = readDartMirror();
    expect(dart.size).toBeGreaterThan(40);
    expect(dart).toContain("file:read");
  });

  test("every bridge checkout-variable type is mirrored in Dart", () => {
    expect(drift(CHECKOUT_VARIABLE_MESSAGE_TYPES, readDartMirror())).toEqual([]);
  });

  test("every Dart checkout-variable type exists on the bridge", () => {
    expect(drift(readDartMirror(), CHECKOUT_VARIABLE_MESSAGE_TYPES)).toEqual([]);
  });

  test("the scrape of the Dart durable-replay mirror found a plausible set", () => {
    const dart = readDartReplayMirror();
    expect(dart.size).toBeGreaterThan(0);
    expect(dart).toContain("agent:status");
  });

  test("every checkout-scoped bridge replay type is mirrored in Dart", () => {
    expect(replayDrift(CHECKOUT_REPLAY_TYPES, readDartReplayMirror())).toEqual([]);
  });

  test("every Dart durable-replay type is a checkout-scoped bridge replay type", () => {
    expect(replayDrift(readDartReplayMirror(), new Set(CHECKOUT_REPLAY_TYPES))).toEqual([]);
  });

  test("every checkout kind answers both predicates deliberately", () => {
    // The two predicates in checkout-types.ts are the only sanctioned place the
    // kind vocabulary is interrogated, and they ask different questions:
    // ownership decides whether a delete must reclaim the directory, isolation
    // decides whether checkout-scoped routing is required (and whether an app
    // without the `checkoutRouting` capability may be admitted). Adding a kind
    // without answering both is how one gets silently degraded to shared
    // handling, so the tuple assertion below fails this suite until the table
    // is extended.
    const expected: Record<CheckoutKind, { managed: boolean; isolated: boolean }> = {
      "main": { managed: false, isolated: false },
      "managed-worktree": { managed: true, isolated: true },
      "external-worktree": { managed: false, isolated: true },
    };
    expect([...CHECKOUT_KINDS]).toEqual(["main", "managed-worktree", "external-worktree"]);
    for (const kind of CHECKOUT_KINDS) {
      expect({ kind, managed: isManagedCheckoutKind(kind), isolated: isIsolatedCheckoutKind(kind) })
        .toEqual({ kind, ...expected[kind] });
    }
  });
});
