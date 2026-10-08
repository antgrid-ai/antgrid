// Variables a developer's own shell may set that change what opencode and kilo
// launch with; a test that describes the bridge's behavior must not inherit them.
const USER_ENV = ["OPENCODE_CONFIG", "OPENCODE_CONFIG_CONTENT", "KILO_CONFIG_CONTENT"] as const;

/** Runs `fn` with only `env` set among the user-owned variables, then restores them. */
export function withUserEnv<T>(env: Partial<Record<(typeof USER_ENV)[number], string>>, fn: () => T): T {
  const prev = USER_ENV.map((k) => [k, process.env[k]] as const);
  for (const k of USER_ENV) delete process.env[k];
  Object.assign(process.env, env);
  try {
    return fn();
  } finally {
    for (const [k, v] of prev) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}
