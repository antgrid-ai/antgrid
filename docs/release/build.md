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
- **Desktop (Windows/macOS/Linux)** — nowhere to upload to. errex implements the
  ingest API but not the symbol-upload one: `sentry-cli` posts to
  `/api/0/organizations/<org>/chunk-upload/` (or the legacy
  `/api/0/projects/<org>/<project>/files/dsyms/`), and errex answers **404** on
  both while answering **401** on routes it does implement, such as
  `/api/<project>/envelope/`. So do not add a `sentry-cli upload-dif` step to the
  desktop workflows expecting it to work. Desktop NATIVE frames therefore arrive
  as module + offset, and hand-symbolicating one needs the matching PDBs/dSYMs —
  which `build-desktop.yml` does not archive, so they die with the runner and a
  native desktop report is unreadable today. Rebuilding the tag does not recover
  them: the toolchains are not bit-reproducible, so the build ids would not match
  the shipped binary. Uploading the symbol files as a build artifact is the fix.
  DART frames stay readable because releases ship unobfuscated (see the top of
  this file). Re-check this if errex gains the endpoint.
