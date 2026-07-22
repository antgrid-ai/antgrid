/// Riverpod 3 introduced automatic retry-on-error for provider builds: a build
/// that throws a plain `Exception` no longer surfaces the error to
/// `provider.future` — it enters a backoff retry loop (up to 10 attempts,
/// `ProviderContainer.defaultRetry`) and keeps `.future` PENDING meanwhile. That
/// silently changes the semantics our async chain relies on: consumers that
/// `await ref.watch(p.future)` inside a try/catch (offline transport handling,
/// best-effort provisioning) would hang instead of catching the error, and only
/// reject with a `StateError` at container dispose.
///
/// Passing this as a provider's `retry:` restores Riverpod 2 semantics — a build
/// error propagates to `.future` immediately, so error handling still trips.
/// Apply it to the async providers whose errors must SURFACE to an awaiting
/// consumer rather than be retried behind its back.
Duration? noProviderRetry(int retryCount, Object error) => null;
