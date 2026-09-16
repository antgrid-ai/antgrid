import { z } from "zod";

const RegistryName = z.string().min(1).refine((name) => name.trim() === name, "Registry names cannot contain surrounding whitespace");

export function snapshotDefinition<T>(value: T): T {
  if (Array.isArray(value)) return Object.freeze(value.map(snapshotDefinition)) as T;
  if (value && typeof value === "object") {
    return Object.freeze(Object.fromEntries(Object.entries(value).map(([key, member]) => [key, snapshotDefinition(member)]))) as T;
  }
  return value;
}

export interface AgentRegistry<Key extends string, Spec> {
  readonly agents: Readonly<Record<Key, Spec>>;
  readonly byHookName: Readonly<Record<string, Key>>;
  get(id: string): Spec | undefined;
}

/** Registers trusted local definitions; remote requests only select an existing id. */
export function createAgentRegistry<const Key extends string, Spec extends { hookName: string | null }>(
  entries: readonly (readonly [Key, Spec])[],
): AgentRegistry<Key, Spec> {
  const agents = Object.create(null) as Record<Key, Spec>;
  const byHookName = Object.create(null) as Record<string, Key>;
  for (const [id, spec] of entries) {
    RegistryName.parse(id);
    if (Object.hasOwn(agents, id)) throw new Error(`Duplicate agent id: ${id}`);
    if (spec.hookName !== null) {
      RegistryName.parse(spec.hookName);
      if (Object.hasOwn(byHookName, spec.hookName)) throw new Error(`Duplicate agent hook alias: ${spec.hookName}`);
      byHookName[spec.hookName] = id;
    }
    agents[id] = snapshotDefinition(spec);
  }
  Object.freeze(agents);
  Object.freeze(byHookName);
  return Object.freeze({
    agents,
    byHookName,
    get: (id: string) => Object.hasOwn(agents, id) ? agents[id as Key] : undefined,
  });
}
