/**
 * Fractional indexing for `Task.sortKey`: a key is a string, and there is
 * always a string strictly between any two distinct keys. That is what makes a
 * drag reorder one row write instead of a renumber of everything below it.
 *
 * The alphabet is deliberately single-case alphanumeric. The published
 * fractional-index implementations use mixed case and depend on ASCII byte
 * ordering, which a Postgres database created under a `en_US.UTF-8` collation
 * does NOT reproduce — `'a' < 'B'` there and `'B' < 'a'` in C — so `ORDER BY
 * sort_key` and a JavaScript string compare would disagree about the list the
 * user just dragged. Over `[0-9a-z]` every collation in play agrees.
 *
 * One invariant runs through all of it: no key ends in the smallest digit.
 * `"a0"` would sit between `"a"` and every `"a"`-prefixed key, leaving no room
 * below it, and `midpoint` would recurse forever looking for some.
 */

const DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz";
const SMALLEST = DIGITS[0]!;

/** Where an account's very first task lands. Mid-alphabet on purpose: the
 *  digits below it are the room a prepend needs. */
const FIRST_KEY = "a";

export class SortKeyError extends Error {}

export function isSortKey(value: string): boolean {
  if (value.length === 0) return false;
  if (value.endsWith(SMALLEST)) return false;
  for (const ch of value) if (!DIGITS.includes(ch)) return false;
  return true;
}

function requireKey(value: string, label: string): string {
  if (!isSortKey(value)) throw new SortKeyError(`${label} is not a sort key: ${JSON.stringify(value)}`);
  return value;
}

/**
 * A key ordering strictly between its two neighbours; `null` on either side
 * means "nothing there". Total: any two distinct keys have a midpoint, so a
 * reorder can never fail for want of room.
 */
export function keyBetween(before: string | null, after: string | null): string {
  if (before !== null) requireKey(before, "before");
  if (after !== null) requireKey(after, "after");
  if (before !== null && after !== null && before >= after) {
    throw new SortKeyError(`sort keys out of order: ${before} >= ${after}`);
  }
  if (before === null && after === null) return FIRST_KEY;
  // Appending is the common case (every create), so it gets the compact answer
  // rather than a midpoint: `midpoint` jumps halfway to the end of the alphabet
  // and a few hundred appends would leave keys hundreds of characters long.
  if (after === null) return increment(before!);
  return midpoint(before ?? "", after);
}

/** The key after `before` with nothing following it. */
function increment(before: string): string {
  const last = DIGITS.indexOf(before[before.length - 1]!);
  if (last < DIGITS.length - 1) return before.slice(0, -1) + DIGITS[last + 1];
  // Out of room at this length. Extending with the smallest digit would break
  // the trailing-digit invariant, so start one above it.
  return before + DIGITS[1];
}

/**
 * A string strictly between `a` and `b`, where `""` means unbounded below and
 * `null` unbounded above.
 *
 * Digit-at-a-time rather than arithmetic: keys are unbounded in length, so
 * there is no number to take the mean of.
 */
function midpoint(a: string, b: string | null): string {
  if (b !== null && a >= b) throw new SortKeyError(`midpoint out of order: ${a} >= ${b}`);
  if (b !== null) {
    // A shared prefix contributes nothing to the comparison; recurse on the
    // tails so the answer stays as short as the difference between the two.
    let n = 0;
    while ((a[n] ?? SMALLEST) === b[n]) n++;
    if (n > 0) return b.slice(0, n) + midpoint(a.slice(n), b.slice(n));
  }

  const digitA = a.length > 0 ? DIGITS.indexOf(a[0]!) : 0;
  const digitB = b !== null ? DIGITS.indexOf(b[0]!) : DIGITS.length;
  if (digitB - digitA > 1) return DIGITS[Math.round(0.5 * (digitA + digitB))]!;

  // The two first digits are adjacent, so the answer has to be longer than one
  // of them: either `b`'s first digit alone (already below the rest of `b`), or
  // `a`'s first digit followed by something above `a`'s tail.
  if (b !== null && b.length > 1) return b.slice(0, 1);
  return DIGITS[digitA]! + midpoint(a.slice(1), null);
}
