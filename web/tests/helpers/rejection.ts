/**
 * Await a promise that is expected to reject and hand back the error, instead of
 * asserting through `expect(...).rejects`.
 *
 * `.rejects` cannot be used on anything Prisma returns. Given a `PrismaPromise`
 * — a custom thenable, not a native promise — it fails outright with "Expected
 * promise". Wrapping the call in an `async` helper hands it a native promise,
 * which gets past that check and is worse: the assertion never settles, the test
 * dies on the runner's timeout, and every hook after it in the file times out
 * too, so one bad assertion reads as a whole suite hanging. The query itself is
 * fine — it errors in single-digit milliseconds, Postgres goes idle, and nothing
 * holds a lock.
 *
 * Bun 1.3.14. `.rejects` is fine on rejections from ordinary application code
 * (see the billing suites) — it is Prisma's promises specifically that break it.
 */
export function rejection(promise: PromiseLike<unknown>): Promise<unknown> {
  return Promise.resolve(promise).then(
    () => {
      throw new Error("expected the query to be rejected, but it succeeded");
    },
    (err: unknown) => err
  );
}
