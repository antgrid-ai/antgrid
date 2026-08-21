---
name: dart-async-correctness
description: >-
  Use for ANY Dart or Flutter work that touches a Future, async/await, .then(), or data loading — writing, fixing, refactoring, speeding up, or reviewing it. This is the default skill the moment async appears in Dart code. Concretely, reach for it when the task involves: marking a function async or chasing an "analyzer says missing await"; a slow screen that awaits independent loads one-by-one (wants Future.wait); loading data when a screen opens, or a FutureBuilder that re-fetches/flickers on rebuild; converting .then() chains to async/await; fire-and-forget calls in initState/dispose/handlers; using context/setState/Navigator/ScaffoldMessenger after an await; or reviewing a Dart diff that adds awaits, async functions, or unawaited calls. These bugs rarely throw — they leak widgets, swallow errors, rebuild with stale data, or add hidden latency, and flutter_lints catches almost none. Apply even when it "just adds one await." Dart/Flutter only — never TypeScript or other languages.
---

# Dart Async Correctness

Async bugs in Dart are quiet. A missing `await`, a `BuildContext` used after a gap, a `.then()` that drops an error — none of these crash loudly or trip `flutter analyze` under this project's `flutter_lints` config. They surface later as leaked widgets, "setState after dispose", swallowed exceptions, UI flicker, or latency nobody can explain. So the discipline has to come from how the code is written, not from a tool catching it after the fact.

This project (`app/`, `packages/antgrid_relay_client/`, `packages/antgrid_eval_client/`) already uses the right idioms: `unawaited(...)` for deliberate fire-and-forget, `mounted` / `context.mounted` guards after awaits, `Future.wait([...])` for concurrency, and Riverpod `AsyncValue` instead of `FutureBuilder`. Match those. The patterns below explain *why* each one matters so you can apply the judgment, not just the rule.

## The one question to ask every time

**"This call returns a Future — what happens to it?"** Every Future has exactly three honest destinies:

1. **Awaited** — you need its result or its completion before continuing.
2. **`unawaited(...)`** — you deliberately don't wait, and you've made sure its errors can't vanish.
3. **Returned** — you hand it to your caller to await.

A Future that is none of these (a bare `doThing();` where `doThing` is async) is a bug in waiting: its errors become unhandled, its ordering is undefined, and the analyzer won't warn you. If you find yourself writing one, stop and pick a destiny.

---

## Correctness traps (these cause real bugs)

### 1. Fire-and-forget Futures that aren't marked as such

The trap: calling an async function in a sync context (`initState`, a button `onPressed`, a `dispose`) without awaiting or marking it.

```dart
// ✗ ordering undefined, errors unhandled, looks intentional but isn't
void initState() {
  super.initState();
  _loadProfile();
}
```

Why it bites: if `_loadProfile` throws, the error is unhandled (may crash in some zones, silently vanish in others). And a reader can't tell whether you *meant* to not wait or simply forgot — `flutter_lints` doesn't flag this, so there's no signal at all.

The fix — make the intent explicit. If you truly want fire-and-forget, say so with `unawaited` and guarantee the error has somewhere to go:

```dart
// ✓ intent is explicit; errors can't silently disappear
unawaited(_loadProfile().catchError(_reportLoadError));
```

If you actually need the result, delegate to an async helper with a guard (see trap 2). When the work belongs to widget lifecycle, prefer a Riverpod `FutureProvider` / `AsyncNotifier` so the framework owns cancellation and error surfacing instead of hand-rolling it in `initState`.

### 2. Using `BuildContext` (or `setState`) across an async gap

The trap: touching `context` — `Navigator`, `ScaffoldMessenger`, `Theme.of`, `setState` — after an `await`. By the time the Future resolves, the widget may be gone.

```dart
// ✗ the widget might be disposed by the time we get here
Future<void> _save() async {
  await service.save(data);
  Navigator.of(context).pop();          // stale context
  setState(() => _saved = true);        // "setState after dispose"
}
```

Why it bites: this is the one async trap `flutter_lints` *does* catch (`use_build_context_synchronously`), so heed the warning rather than suppressing it — it's pointing at a genuine lifecycle hazard, not noise.

The fix — guard with `mounted` after every gap, matching the existing code:

```dart
// ✓
Future<void> _save() async {
  await service.save(data);
  if (!mounted) return;                 // State.mounted
  Navigator.of(context).pop();
  setState(() => _saved = true);
}
```

For a `BuildContext` that isn't a `State`'s own (e.g. captured in a builder), check `context.mounted`. Note there can be *several* gaps in one method — guard after each, not just the first.

### 3. `.then()` chains that drop errors or nest into a pyramid

The trap: deep `.then().then().then()` callback chains, or relying on `.then(onError:)` which only catches the *previous* step — not errors thrown inside a Future returned by the callback.

Why it bites: nested `.then()` is hard to read and harder to reason about for error boundaries, and the `onError` parameter's narrow scope means inner failures slip through unhandled.

The fix — prefer `async`/`await` with `try/catch`; the control flow and error scope become obvious:

```dart
// ✗ pyramid, fragile error handling
fetchUser().then((u) => fetchOrders(u.id).then((o) => render(u, o)));

// ✓ linear, one error boundary
try {
  final u = await fetchUser();
  final o = await fetchOrders(u.id);
  render(u, o);
} catch (e) { handle(e); }
```

`.then()` is fine for a *single* transform on a Future you're handing off — the project uses it that way inside `unawaited(...)` (e.g. `unawaited(proc.exitCode.then((_) => exited = true))`). Keep it shallow and pair it with `.catchError` if it can fail. Reach for `try/catch` the moment there's a second step.

### 4. Unhandled errors on Futures you don't await

The trap: an `unawaited(...)` or `.then()`-only Future that can throw, with no `.catchError`.

Why it bites: `unawaited()` documents intent but does **not** suppress or route errors — an error on an unawaited Future is an unhandled async error. Same for a `.then()` with no error branch.

The fix: whenever a fire-and-forget Future can fail, attach `.catchError` (or wrap the helper in `try/catch` before calling `unawaited`). If it genuinely cannot fail, that's worth a one-line comment so the next reader doesn't assume an oversight.

### 5. Recreating the Future on every build (`FutureBuilder`)

The trap: `FutureBuilder(future: fetchData(), ...)` — `fetchData()` re-runs on every rebuild, re-hitting the network and flickering the UI.

This project uses Riverpod `AsyncValue` (`ref.watch(someFutureProvider)`), which caches and dedupes for you — **prefer that path**; it sidesteps the trap entirely. If you must use `FutureBuilder`, the future has to be created once and stored (in `initState` or a memoized provider), never inline in `build`:

```dart
// ✗ new Future every rebuild
FutureBuilder(future: fetchData(), builder: ...)

// ✓ created once
late final Future<Data> _data = fetchData();   // then future: _data
```

---

## Performance & latency traps

### 6. Awaiting independent Futures sequentially

The trap: `await a(); await b(); await c();` when none depends on the others. Latencies add up instead of overlapping.

The fix — run them concurrently with `Future.wait`, exactly as the project already does (`Future.wait([svc.read(), svc.detectTools()])`):

```dart
// ✗ 2s + 1.5s + 1s = 4.5s
final user = await fetchUser();
final prefs = await fetchPrefs();
final feed = await fetchFeed();

// ✓ max(2s, 1.5s, 1s) = 2s
final [user, prefs, feed] = await Future.wait([fetchUser(), fetchPrefs(), fetchFeed()]);
```

Keep sequential awaits only when a later call genuinely needs an earlier result. Don't over-apply: `Future.wait` with a single element is just noise.

### 7. Redundant `async`/`await`

The trap: marking a function `async` when it awaits nothing, or `return await x;` as the last statement.

Why it bites: each unnecessary `async` schedules an extra microtask and wraps the return in another Future layer — small, but it's pure overhead on the event loop and it muddies whether the function is actually doing async work.

The fix:

```dart
// ✗
Future<int> id() async => await cache.read();
// ✓ just forward the Future
Future<int> id() => cache.read();
```

Keep the `await` when you need it inside a `try/catch` (a bare `return future;` inside `try` won't catch the rejection) — that's a real reason, not redundancy.

### 8. Creating Futures for no reason

The trap: an `async` function that only ever returns a ready value (`Future.value(...)`) or throws synchronously wrapped as `Future.error(...)`, when the work is actually synchronous.

The fix: make it synchronous. If the signature must return a `Future` (interface contract), return the value directly and let the caller's `await` wrap it — don't add `async` just to satisfy the type. Use `FutureOr<T>` when a function is sometimes sync, sometimes async (see trap 9).

---

## Subtle / debugging traps

### 9. Blindly awaiting `FutureOr<T>`

The trap: `await someFutureOr` when the value may already be synchronous. Awaiting a plain value forces an unnecessary microtask gap and an artificial reorder of execution.

The fix: branch on the type when the synchronous path matters for ordering or latency:

```dart
final v = x is Future<T> ? await x : x;
```

### 10. Printing or interpolating a Future

The trap: `print('user: $userFuture')` or `'$nameFuture'` in a log — you get `Instance of '_Future<String>'`, not the value, and waste debugging time chasing a non-bug.

The fix: `await` first, then log the resolved value.

---

## Quick self-check before finishing async Dart

Run through this when you've written or edited anything async — it's the cheapest place to catch these, since the analyzer won't:

- Every Future is **awaited, `unawaited(...)`, or returned** — no bare async calls.
- Every fire-and-forget that can fail has a **`.catchError`** (or a try/catch around it).
- After every `await`, any `context` / `setState` / `Navigator` / `ScaffoldMessenger` use is **`mounted`-guarded** (`if (!mounted) return;` / `context.mounted`).
- Independent awaits are batched with **`Future.wait`**; sequential only when truly dependent.
- No `async` without an `await`; no `return await x;` outside a `try`.
- `.then()` chains are shallow and have an error branch — multi-step logic is `async`/`await` + `try/catch`.
- New UI data uses Riverpod `AsyncValue`, not a `Future` created inline in `build`.

If a fire-and-forget or unguarded gap is genuinely intentional, leave a one-line comment saying why — so the next reader (and the next agent) doesn't "fix" a deliberate choice or trust an accidental one.
