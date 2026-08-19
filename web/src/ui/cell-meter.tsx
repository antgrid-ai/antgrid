/**
 * Capacity drawn as discrete cells — the product's namesake made literal, and
 * the one thing this console can show that the marketing site can only
 * illustrate: the grid field behind its hero, with the reader's real numbers
 * in it.
 *
 * It is also a better read than the fraction it replaces. "2 / 5" has to be
 * subtracted before it means anything; three empty cells IS the headroom, at a
 * glance and without arithmetic.
 *
 * Past `MAX_CELLS` the cells stop being countable and become texture, so the
 * meter degrades to a proportional bar. Enterprise's worker limit is 100. The
 * ceiling is on the CELLS DRAWN, not on the limit: a downgrade leaves `used`
 * far above a small `limit`, and gating on the limit alone drew one amber
 * square per machine over it.
 */

const MAX_CELLS = 12;

export type CellMeterProps = {
  label: string;
  used: number;
  limit: number;
  /** Plural noun for the screen-reader label — "machines", "seats". */
  unit: string;
};

export function CellMeter({ label, used, limit, unit }: CellMeterProps) {
  // A plan downgrade can leave an account above its own cap, so `used > limit`
  // is a real state and not a bug to clamp away. It reads as amber overflow
  // cells rather than a silently truncated row.
  const over = Math.max(0, used - limit);
  const filled = Math.min(used, limit);

  return (
    <div>
      <div class="text-[0.6875rem] font-medium uppercase tracking-[0.12em] text-muted2">
        {label}
      </div>
      <div class="mt-1 font-mono text-2xl leading-none">
        <span class={over > 0 ? "text-amber" : "text-ink"}>{used}</span>
        <span class="text-faint"> / {limit}</span>
      </div>
      <div
        class="mt-2.5"
        role="img"
        aria-label={
          over > 0
            ? `${used} of ${limit} ${unit} in use — ${over} over the limit`
            : `${used} of ${limit} ${unit} in use`
        }
      >
        {limit > 0 && limit <= MAX_CELLS && used <= MAX_CELLS ? (
          <div class="flex flex-wrap gap-1" aria-hidden="true">
            {Array.from({ length: filled }, (_, i) => (
              <span key={`f${i}`} class="h-2.5 w-2.5 rounded-[2px] bg-signal" />
            ))}
            {Array.from({ length: over }, (_, i) => (
              <span key={`o${i}`} class="h-2.5 w-2.5 rounded-[2px] bg-amber" />
            ))}
            {Array.from({ length: Math.max(0, limit - filled) }, (_, i) => (
              <span
                key={`e${i}`}
                class="h-2.5 w-2.5 rounded-[2px] border border-edge bg-chrome"
              />
            ))}
          </div>
        ) : (
          <div class="h-2.5 w-full max-w-40 overflow-hidden rounded-[2px] bg-chrome" aria-hidden="true">
            <div
              class={`h-full ${over > 0 ? "bg-amber" : "bg-signal"}`}
              style={`width:${limit > 0 ? Math.min(100, Math.round((used / limit) * 100)) : 0}%`}
            />
          </div>
        )}
      </div>
    </div>
  );
}
