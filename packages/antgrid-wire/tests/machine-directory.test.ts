import { describe, expect, test } from "bun:test";
import {
  BusKeyRegistrationSchema,
  MAX_ACCOUNT_MACHINES,
  MachineDirectorySchema,
  RawKey32Schema,
  SessionBusGrantsPatchSchema,
  SessionBusGrantsSchema,
} from "../src/machine-directory";

const KEY = Buffer.alloc(32, 7).toString("base64");
const UUID = "6f1c1c3e-8a52-4b0e-9a57-2b9f4c1d7e10";

function entry(i: number, busPublicKey: string | null = KEY) {
  return {
    deviceId: `6f1c1c3e-8a52-4b0e-9a57-${String(i).padStart(12, "0")}`,
    displayName: `Machine ${i}`,
    machineName: null,
    ed25519Pub: KEY,
    busPublicKey,
    orchestrator: false,
    busControl: false,
  };
}

function directory(machines: unknown[] = [entry(1)]) {
  return {
    accountId: "acct",
    deviceId: UUID,
    allowed: true,
    self: { busPublicKey: KEY, orchestrator: false, busControl: false },
    machines,
  };
}

describe("MachineDirectorySchema", () => {
  test("parses with a null bus key on an entry and on self", () => {
    const d = directory([entry(1, null)]);
    d.self.busPublicKey = null as unknown as string;
    const parsed = MachineDirectorySchema.parse(d);
    expect(parsed.machines[0]!.busPublicKey).toBeNull();
    expect(parsed.self.busPublicKey).toBeNull();
  });

  test("rejects a 31-byte key", () => {
    const short = Buffer.alloc(31, 7).toString("base64");
    expect(RawKey32Schema.safeParse(short).success).toBe(false);
    expect(MachineDirectorySchema.safeParse(directory([entry(1, short)])).success).toBe(false);
  });

  test("rejects a non-UUID deviceId", () => {
    const bad = { ...entry(1), deviceId: "not-a-uuid" };
    expect(MachineDirectorySchema.safeParse(directory([bad])).success).toBe(false);
  });

  test("rejects more machines than the cap", () => {
    const many = Array.from({ length: MAX_ACCOUNT_MACHINES + 1 }, (_, i) => entry(i));
    expect(MachineDirectorySchema.safeParse(directory(many)).success).toBe(false);
    expect(MachineDirectorySchema.safeParse(directory(many.slice(0, MAX_ACCOUNT_MACHINES))).success).toBe(true);
  });

  test("requires busControl on entries and self", () => {
    const { busControl: _b, ...noControl } = entry(1);
    expect(MachineDirectorySchema.safeParse(directory([noControl])).success).toBe(false);
    const d = directory();
    d.self = { busPublicKey: KEY, orchestrator: false } as typeof d.self;
    expect(MachineDirectorySchema.safeParse(d).success).toBe(false);
  });

  test("strips unknown keys", () => {
    const d = { ...directory([{ ...entry(1), future: 1 }]), extra: true };
    const parsed = MachineDirectorySchema.parse(d) as Record<string, unknown>;
    expect(parsed.extra).toBeUndefined();
    expect((parsed.machines as Record<string, unknown>[])[0]!.future).toBeUndefined();
  });
});

describe("BusKeyRegistrationSchema", () => {
  test("accepts one key and rejects extra fields", () => {
    expect(BusKeyRegistrationSchema.safeParse({ busPublicKey: KEY }).success).toBe(true);
    expect(BusKeyRegistrationSchema.safeParse({ busPublicKey: KEY, x: 1 }).success).toBe(false);
  });
});

describe("session-bus grants schemas", () => {
  test("grants require both booleans and refuse extra keys", () => {
    expect(SessionBusGrantsSchema.safeParse({ orchestrator: true, busControl: false }).success).toBe(true);
    expect(SessionBusGrantsSchema.safeParse({ orchestrator: true }).success).toBe(false);
    expect(SessionBusGrantsSchema.safeParse({ orchestrator: true, busControl: false, x: 1 }).success).toBe(false);
  });

  test("a patch needs at least one key and refuses extras", () => {
    expect(SessionBusGrantsPatchSchema.safeParse({}).success).toBe(false);
    expect(SessionBusGrantsPatchSchema.safeParse({ busControl: false }).success).toBe(true);
    expect(SessionBusGrantsPatchSchema.safeParse({ orchestrator: true, busControl: true }).success).toBe(true);
    expect(SessionBusGrantsPatchSchema.safeParse({ orchestrator: "yes" }).success).toBe(false);
    expect(SessionBusGrantsPatchSchema.safeParse({ busControl: true, x: 1 }).success).toBe(false);
  });
});
