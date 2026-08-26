/**
 * Serializes async work per key: two operations sharing a key never overlap,
 * and operations under different keys never wait on each other.
 *
 * The shape `WorktreeManager.withProjectLock` and `CheckoutStore.mutate` already
 * use, extracted because the checkout-runtime lifecycle needs it too — see
 * `withCheckoutRuntimeLock` in agent-core.ts, where building a runtime and
 * tearing one down both suspend repeatedly while holding a directory open.
 *
 * A lock rather than a checked flag whenever the hazard is a suspension window:
 * a flag has to be re-tested after EVERY `await`, so each one added later is a
 * fresh hole, and an await that rejects skips its own check. Serializing makes
 * the interleave impossible rather than merely detectable.
 */
export type KeyedLock = <T>(key: string, fn: () => Promise<T>) => Promise<T>;

export function createKeyedLock(): KeyedLock {
  const chains = new Map<string, Promise<unknown>>();
  return function withLock<T>(key: string, fn: () => Promise<T>): Promise<T> {
    const previous = chains.get(key) ?? Promise.resolve();
    // Both arms are the same function: an earlier operation that FAILED still
    // ran, so the next one must still be serialized behind it rather than
    // starting early — and the caller's rejection is delivered to the caller,
    // never to whoever queues next.
    const run = previous.then(fn, fn);
    const settled = run.then(() => undefined, () => undefined);
    chains.set(key, settled);
    void settled.then(() => {
      // Only when still the tail. A later caller has already chained onto this
      // promise and replaced the entry; deleting it then would let the caller
      // after THAT one skip the queue entirely.
      if (chains.get(key) === settled) chains.delete(key);
    });
    return run;
  };
}
