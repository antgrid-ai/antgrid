import { CheckoutStore } from "./checkout-store";
import type { CheckoutRecord } from "./checkout-types";

/**
 * Bridge-local index of checkout runtimes. It deliberately owns no wire state:
 * callers address it by id and receive only host-local paths/config data.
 *
 * Runtime services are added incrementally by AgentCore; keeping record lookup
 * here makes restart/resume safe even before an expensive watcher is rebuilt.
 */
export class CheckoutRuntimeRegistry<TConfig, TAgentSpec, TRuntime = unknown> {
  private readonly records = new Map<string, CheckoutRecord>();
  private readonly configs = new Map<string, TConfig>();
  private readonly specs = new Map<string, TAgentSpec>();
  private readonly runtimes = new Map<string, TRuntime>();

  constructor(
    private readonly store: CheckoutStore,
    main: CheckoutRecord,
  ) {
    this.records.set(main.id, main);
  }

  async prepare(
    record: CheckoutRecord,
    config: TConfig,
    agentSpec: TAgentSpec,
    runtime?: TRuntime,
  ): Promise<void> {
    this.records.set(record.id, record);
    this.configs.set(record.id, config);
    this.specs.set(record.id, agentSpec);
    if (runtime !== undefined) this.runtimes.set(record.id, runtime);
  }

  async resolve(checkoutId: string): Promise<CheckoutRecord | undefined> {
    const cached = this.records.get(checkoutId);
    if (cached) return cached;
    const persisted = await this.store.get(checkoutId);
    if (persisted) this.records.set(checkoutId, persisted);
    return persisted;
  }

  agentSpec(checkoutId: string): TAgentSpec | undefined {
    return this.specs.get(checkoutId);
  }

  config(checkoutId: string): TConfig | undefined {
    return this.configs.get(checkoutId);
  }

  runtime(checkoutId: string): TRuntime | undefined {
    return this.runtimes.get(checkoutId);
  }

  setRuntime(checkoutId: string, runtime: TRuntime): void {
    this.runtimes.set(checkoutId, runtime);
  }

  values(): IterableIterator<TRuntime> {
    return this.runtimes.values();
  }

  async remove(checkoutId: string): Promise<void> {
    if (checkoutId === "main") return;
    this.records.delete(checkoutId);
    this.configs.delete(checkoutId);
    this.specs.delete(checkoutId);
    this.runtimes.delete(checkoutId);
  }
}
