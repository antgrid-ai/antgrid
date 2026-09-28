export interface AdmissionReservation {
  readonly generation: number;
  readonly current: boolean;
  release(): void;
}

/** Counts anonymous native work until it actually settles. Retiring a
 * generation fences its completions without freeing capacity prematurely. */
export class AdmissionRegistry {
  private generation = 0;
  private owned = 0;

  constructor(private readonly limit: number) {
    if (!Number.isInteger(limit) || limit < 1) throw new RangeError("Admission limit must be positive");
  }

  get size(): number { return this.owned; }
  get currentGeneration(): number { return this.generation; }

  reserve(): AdmissionReservation | null {
    if (this.owned >= this.limit) return null;
    this.owned++;
    const generation = this.generation;
    const registry = this;
    let released = false;
    return {
      generation,
      get current() { return !released && generation === registry.generation; },
      release: () => {
        if (released) return;
        released = true;
        this.owned--;
      },
    };
  }

  retireGeneration(): void { this.generation++; }
}
