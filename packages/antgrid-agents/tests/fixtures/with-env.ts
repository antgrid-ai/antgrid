/** Points an agent's store variable at a synthetic store for one call, so a
 * test that expects the real-store guard to refuse would find the session if the
 * guard were removed. */
export async function withEnv<T>(name: string, value: string, run: () => Promise<T>): Promise<T> {
  const previous = process.env[name];
  process.env[name] = value;
  try {
    return await run();
  } finally {
    if (previous === undefined) delete process.env[name];
    else process.env[name] = previous;
  }
}
