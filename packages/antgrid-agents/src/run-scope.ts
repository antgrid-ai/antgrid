export interface AgentRunScope<Event = unknown> {
  readonly runId: string;
  readonly signal: AbortSignal;
  emit(event: Event): void;
  registerCleanup(cleanup: () => void | Promise<void>): void;
}

export interface OwnedAgentRunScope<Event> extends AgentRunScope<Event> {
  cancel(reason?: unknown): void;
  dispose(): Promise<void>;
  track<T>(operation: Promise<T>): Promise<T>;
}

/** Resource release waits for tracked acquisition, including allocations arriving after cancellation. */
export function createAgentRunScope<Event>(options: {
  runId: string;
  isCurrent(): boolean;
  emit(event: Event): void;
}): OwnedAgentRunScope<Event> {
  const controller = new AbortController();
  const cleanups: Array<() => void | Promise<void>> = [];
  const registered = new Set<() => void | Promise<void>>();
  const pending = new Set<Promise<unknown>>();
  const failures: unknown[] = [];
  let disposal: Promise<void> | undefined;
  const observe = <T>(promise: Promise<T>): Promise<T> => {
    pending.add(promise);
    void promise.finally(() => pending.delete(promise)).catch(() => {});
    return promise;
  };
  const release = (cleanup: () => void | Promise<void>) => {
    try {
      observe(Promise.resolve(cleanup()).catch((error) => { failures.push(error); }));
    } catch (error) { failures.push(error); }
  };
  const cancel = (reason?: unknown) => {
    if (controller.signal.aborted) return;
    controller.abort(reason);
    for (const cleanup of cleanups.splice(0).reverse()) release(cleanup);
  };
  return {
    runId: options.runId,
    signal: controller.signal,
    emit(event) {
      if (!controller.signal.aborted && options.isCurrent()) options.emit(event);
    },
    registerCleanup(cleanup) {
      if (registered.has(cleanup)) return;
      registered.add(cleanup);
      let called = false;
      const once = () => { if (!called) { called = true; return cleanup(); } };
      if (controller.signal.aborted) release(once);
      else cleanups.push(once);
    },
    track: observe,
    cancel,
    dispose() {
      if (disposal) return disposal;
      let resolve!: () => void;
      let reject!: (error: unknown) => void;
      disposal = new Promise<void>((yes, no) => { resolve = yes; reject = no; });
      cancel();
      void (async () => {
        // A cleanup can reenter dispose while cancel is still registering releases.
        await Promise.resolve();
        while (pending.size) await Promise.allSettled([...pending]);
        if (failures.length) throw new AggregateError(failures, `Agent resource release failed: ${failures.map((error) => error instanceof Error ? error.message : String(error)).join("; ")}`);
      })().then(resolve, reject);
      return disposal;
    },
  };
}
