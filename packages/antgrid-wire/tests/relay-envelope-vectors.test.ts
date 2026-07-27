// Cross-language pin for the relay control envelopes: every entry in
// evals/fixtures/relay-envelope-vectors.json must parse through the Zod
// unions, and every union variant / ErrorCode must have an entry. The Dart
// side (packages/antgrid_relay_client/test/relay_envelope_vectors_test.dart)
// runs the same fixture through the hand-mirrored schemas. Adding a wire
// variant without regenerating the fixture fails HERE; regenerating without
// updating the Dart mirror fails THERE.
import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { ClientMessage, ErrorCode, ServerMessage } from "../src/relay-protocol";

type Vector = { name: string; json: Record<string, unknown> };

const fixture = JSON.parse(
  readFileSync(resolve(import.meta.dir, "../../../evals/fixtures/relay-envelope-vectors.json"), "utf8"),
) as { server: Vector[]; client: Vector[] };

test("every server vector parses through ServerMessage", () => {
  for (const v of fixture.server) {
    expect(() => ServerMessage.parse(v.json), v.name).not.toThrow();
  }
});

test("every client vector parses through ClientMessage", () => {
  for (const v of fixture.client) {
    expect(() => ClientMessage.parse(v.json), v.name).not.toThrow();
  }
});

test("every ServerMessage variant has a vector", () => {
  const variants = ServerMessage.options.map((o) => o.shape.type.value as string);
  const covered = new Set(fixture.server.map((v) => v.json.type));
  expect([...covered].sort()).toEqual([...new Set(variants)].sort());
});

test("every ClientMessage variant has a vector", () => {
  const variants = ClientMessage.options.map((o) => o.shape.type.value as string);
  const covered = new Set(fixture.client.map((v) => v.json.type));
  expect([...covered].sort()).toEqual([...new Set(variants)].sort());
});

test("every ErrorCode has an error vector", () => {
  const covered = fixture.server
    .filter((v) => v.json.type === "error")
    .map((v) => v.json.code as string);
  expect(covered.sort()).toEqual([...ErrorCode.options].sort());
});
