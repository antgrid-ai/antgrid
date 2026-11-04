/**
 * `true` when `p` settles within `ms`, `false` once the budget is spent.
 *
 * `Bun.sleep` cannot be cancelled, and these races are normally won by the
 * process exiting — so the loser's timer would go on holding the event loop
 * open for the rest of its budget, which a shutdown then spends waiting on a
 * process that has already gone.
 */
export async function raceTimeout(p: Promise<unknown>, ms: number): Promise<boolean> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      p.then(() => true),
      new Promise<boolean>((resolve) => {
        timer = setTimeout(() => resolve(false), ms);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}
