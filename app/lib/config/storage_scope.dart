import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kReleaseMode;

/// Compile-time override to run multiple isolated non-release instances side by
/// side (e.g. two dev checkouts): `--dart-define=ANTGRID_STORAGE_SCOPE=foo`
/// prefixes every local-storage key with `foo.`. Never applies to a release
/// build (see [_resolveScopePrefix]) regardless of this being set.
///
/// Exposed (not just consumed internally) so `host_discovery.dart`'s
/// `hostDir()` can fold the same value into the spawned host's directory name
/// — otherwise two side-by-side scoped instances would isolate their app
/// storage but still share one host (pairing, relay-epoch, sessions).
const String storageScopeOverride = String.fromEnvironment(
  'ANTGRID_STORAGE_SCOPE',
);

/// Key prefix that isolates THIS build's local storage — SharedPreferences and
/// `flutter_secure_storage` — from other builds that share the same OS app
/// identity (the `%APPDATA%`/keychain namespace, derived from the bundle id,
/// which we deliberately do NOT change).
///
/// Empty for release builds and under `flutter test`, so shipped apps and the
/// test suite read/write exactly the keys they always have — no migration, no
/// behaviour change, and no broken raw-key-literal assertions in tests. A local
/// debug/profile build (a `flutter run` sitting next to an installed release
/// app on a dev machine) gets `dev.` so the two never read or clobber each
/// other's device-identity, pairing, or session state.
///
/// This is the app-layer half of dev/prod isolation. The host's on-disk
/// `~/.antgrid` tree is isolated separately via `ANTGRID_DIR` — see
/// `host_discovery.dart`'s `hostDir()`.
final String storageScopePrefix = _resolveScopePrefix();

String _resolveScopePrefix() {
  // Release always wins, even if a stray ANTGRID_STORAGE_SCOPE dart-define
  // leaked into the build config — a shipped app must never rescope its
  // users' keys.
  if (kReleaseMode) return '';
  if (storageScopeOverride.isNotEmpty) return '$storageScopeOverride.';
  // flutter_test sets FLUTTER_TEST=true; the suite must stay on the bare keys
  // so fixtures that seed/assert raw key literals keep working.
  if (Platform.environment.containsKey('FLUTTER_TEST')) return '';
  return 'dev.';
}

/// Namespaces a persisted-storage [base] key with [storageScopePrefix].
/// A no-op (returns [base] unchanged) in release builds and under tests.
String scopedStorageKey(String base) => '$storageScopePrefix$base';
