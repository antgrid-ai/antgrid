# Release build commands

Release builds ship **unobfuscated** so Dart crash traces are human-readable in
errex (our self-hosted Sentry-compatible tracker). `--obfuscate` / `--split-debug-info`
are intentionally omitted; do not add them.

Crash reporting and analytics stay inert unless a `SENTRY_DSN` is provided at
build time (see below). `AppEnvironment.sentryDsn` reads
`String.fromEnvironment('SENTRY_DSN')`; when the define is absent the DSN is an
empty string and the Sentry SDK initialises in no-op mode.

---

## Android

```bash
flutter build appbundle --release
```

## iOS

```bash
flutter build ipa --release
```

---

## Enabling telemetry in a build

Pass `--dart-define=SENTRY_DSN=<dsn>` to activate crash transport:

```bash
flutter build appbundle --release --dart-define=SENTRY_DSN=https://...@errex.example.com/1
flutter build ipa --release --dart-define=SENTRY_DSN=https://...@errex.example.com/1
```

All other build flags and environment overrides (e.g. `RELAY_URL`, `LICENSE_API_URL`)
work the same way via `--dart-define`.

---

## Native symbol upload (unrelated to Dart obfuscation)

Dart being unobfuscated does not remove the need to upload **native** crash
symbols:

- **Android** — upload the `.symbols/` bundle (native debug symbols) to Play
  Console when submitting the AAB.
- **iOS** — upload dSYMs, including Flutter's `App.framework.dSYM`, to App Store
  Connect. Xcode Cloud does this automatically; manual builds require
  `xcrun altool` or the Xcode Organizer.
