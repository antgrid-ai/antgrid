import { z } from "zod";

// Standard base64 of exactly 32 raw bytes.
export const RawKey32Schema = z.string().regex(/^[A-Za-z0-9+/]{43}=$/);

export const MAX_ACCOUNT_MACHINES = 64;

// The directory schemas are non-strict z.object on purpose: they strip unknown
// keys, so a field added later never strands an older bridge.
export const MachineEntrySchema = z.object({
  deviceId: z.string().uuid(),
  displayName: z.string().min(1).max(120),
  machineName: z.string().min(1).max(120).nullable(),
  ed25519Pub: RawKey32Schema,
  busPublicKey: RawKey32Schema.nullable(),
  orchestrator: z.boolean(),
  busControl: z.boolean(),
});
export type MachineEntry = z.infer<typeof MachineEntrySchema>;

export const MachineDirectorySchema = z.object({
  accountId: z.string().min(1).max(256),
  deviceId: z.string().uuid(),
  allowed: z.boolean(),
  self: z.object({
    busPublicKey: RawKey32Schema.nullable(),
    orchestrator: z.boolean(),
    busControl: z.boolean(),
  }),
  machines: z.array(MachineEntrySchema).max(MAX_ACCOUNT_MACHINES),
});
export type MachineDirectory = z.infer<typeof MachineDirectorySchema>;

export const BusKeyRegistrationSchema = z.strictObject({ busPublicKey: RawKey32Schema });
export type BusKeyRegistration = z.infer<typeof BusKeyRegistrationSchema>;

export const SessionBusGrantsSchema = z.strictObject({ orchestrator: z.boolean(), busControl: z.boolean() });
export type SessionBusGrants = z.infer<typeof SessionBusGrantsSchema>;

export const SessionBusGrantsPatchSchema = z.strictObject({
  orchestrator: z.boolean().optional(),
  busControl: z.boolean().optional(),
}).refine((patch) => patch.orchestrator !== undefined || patch.busControl !== undefined,
  { message: "at least one grant is required" });
export type SessionBusGrantsPatch = z.infer<typeof SessionBusGrantsPatchSchema>;
