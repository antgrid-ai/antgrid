export type EndpointState = "stopped" | "starting" | "ready" | "backoff" | "blocked";

export class EndpointFailure extends Error {
  constructor(readonly code: string, readonly terminal = false) { super(code); }
}

export interface EndpointLifecycleDetail {
  attemptGeneration: number;
  retryReason?: string;
  retryDelayMs?: number;
  teardownReason?: string;
  teardownOutcome?: "not-owned" | "complete" | "failed";
}

export interface EndpointLifecycleOptions<T> {
  create: () => Promise<T>;
  listen: (endpoint: T) => Promise<void>;
  retire: (endpoint: T) => Promise<void>;
  terminal: (error: unknown) => boolean;
  changed?: (state: EndpointState, reason?: string, detail?: EndpointLifecycleDetail) => void;
  now?: () => number;
  random?: () => number;
  schedule?: (callback: () => void, ms: number) => () => void;
}

/** Retired native operations retain ownership until settled; retries cannot overlap them. */
export class EndpointLifecycle<T> {
  state: EndpointState = "stopped";
  private generation = 0;
  private wanted = false;
  private running: Promise<void> | null = null;
  private endpoint: T | null = null;
  private cancelRetry: (() => void) | null = null;
  private backoff = 1_000;
  private readyAt = 0;
  private retiring: Promise<void> | null = null;
  private stopping: Promise<void> | null = null;
  private restartRequested = false;

  constructor(private readonly options: EndpointLifecycleOptions<T>) {}

  start(): void {
    if (this.wanted) return;
    this.wanted = true;
    this.launch();
  }

  restart(): void {
    if (!this.wanted) return;
    this.generation++;
    this.cancelRetry?.();
    this.cancelRetry = null;
    this.restartRequested = true;
    void this.retire("restart").then(() => this.launch()).catch(() => {});
  }

  block(reason: string): void {
    this.generation++;
    this.cancelRetry?.();
    this.cancelRetry = null;
    this.restartRequested = false;
    this.setState("blocked", reason);
    void this.retire("blocked").catch(() => {});
  }

  retry(): void {
    if (!this.wanted) return;
    this.restartRequested = true;
    this.setState("backoff");
    this.restart();
  }

  stop(): Promise<void> {
    if (this.stopping) return this.stopping;
    this.wanted = false;
    this.generation++;
    this.restartRequested = false;
    this.cancelRetry?.();
    this.cancelRetry = null;
    this.setState("stopped");
    const running = this.running;
    this.stopping = Promise.all([
      this.retire("endpoint-stop"),
      running ?? Promise.resolve(),
    ]).then(
      () => { this.observe({ teardownReason: "lifecycle-stop", teardownOutcome: "complete" }); },
      (error) => {
        this.observe({ teardownReason: "lifecycle-stop", teardownOutcome: "failed" });
        throw error;
      },
    );
    return this.stopping;
  }

  private setState(state: EndpointState, reason?: string, detail?: Partial<EndpointLifecycleDetail>): void {
    this.state = state;
    this.observe(detail, reason);
  }

  private observe(detail: Partial<EndpointLifecycleDetail> = {}, reason?: string): void {
    try {
      this.options.changed?.(this.state, reason, {
        attemptGeneration: this.generation,
        ...detail,
      });
    } catch { /* Diagnostics are observational. */ }
  }

  private retire(reason = "retire"): Promise<void> {
    if (this.retiring) return this.retiring;
    const endpoint = this.endpoint;
    if (endpoint === null) {
      this.observe({ teardownReason: reason, teardownOutcome: "not-owned" });
      return Promise.resolve();
    }
    this.endpoint = null;
    this.retiring = this.options.retire(endpoint).then(
      () => { this.observe({ teardownReason: reason, teardownOutcome: "complete" }); },
      (error) => {
        this.observe({ teardownReason: reason, teardownOutcome: "failed" });
        throw error;
      },
    ).finally(() => { this.retiring = null; });
    // A failed close cannot safely authorize another native endpoint.
    this.retiring.catch(() => this.block("ENDPOINT_CLOSE_FAILED"));
    return this.retiring;
  }

  private launch(): void {
    if (!this.wanted || this.running || this.retiring || this.cancelRetry || this.state === "blocked") return;
    this.restartRequested = false;
    const generation = ++this.generation;
    this.setState("starting");
    this.running = this.run(generation).finally(() => {
      this.running = null;
      if (this.restartRequested) this.launch();
    });
  }

  private async run(generation: number): Promise<void> {
    try {
      const endpoint = await this.options.create();
      this.endpoint = endpoint;
      if (!this.wanted || generation !== this.generation) { await this.retire("stale-attempt"); return; }
      this.readyAt = (this.options.now ?? performance.now.bind(performance))();
      this.setState("ready");
      await this.options.listen(endpoint);
      throw new EndpointFailure("LISTENER_ENDED");
    } catch (error) {
      await this.retire("attempt-failed").catch(() => {});
      if (!this.wanted || generation !== this.generation || this.state === "blocked") return;
      if (this.options.terminal(error)) { this.setState("blocked", error instanceof EndpointFailure ? error.code : "ENDPOINT_DENIED"); return; }
      const now = (this.options.now ?? performance.now.bind(performance))();
      if (this.state === "ready" && now - this.readyAt >= 30_000) this.backoff = 1_000;
      const delay = this.backoff / 2 + (this.options.random ?? Math.random)() * this.backoff / 2;
      this.backoff = Math.min(this.backoff * 2, 30_000);
      const retryReason = error instanceof EndpointFailure ? error.code : "ENDPOINT_UNAVAILABLE";
      this.setState("backoff", retryReason, {
        retryReason,
        retryDelayMs: delay,
      });
      const schedule = this.options.schedule ?? ((callback: () => void, ms: number) => {
        const timer = setTimeout(callback, ms); timer.unref?.(); return () => clearTimeout(timer);
      });
      this.cancelRetry = schedule(() => { this.cancelRetry = null; this.launch(); }, delay);
    }
  }
}
