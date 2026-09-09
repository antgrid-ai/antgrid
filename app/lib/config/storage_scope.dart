import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_foundation/shared_preferences_foundation.dart';
import 'package:shared_preferences_linux/shared_preferences_linux.dart';
import 'package:shared_preferences_windows/shared_preferences_windows.dart';

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
/// app on a dev machine) gets `dev.` — but the prefix ALONE does not achieve
/// the isolation this doc used to claim. See [desktopSharedPreferencesOptions]:
/// on desktop, every process sharing that file also shares one plugin-side
/// write path, and a key prefix cannot stop that.
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

/// [storageScopePrefix] with its trailing `.` stripped, for building a
/// filename/suite-name fragment (`dev`, or the `ANTGRID_STORAGE_SCOPE`
/// override) rather than a key prefix. Empty wherever the prefix is.
String get _scopeFragment => storageScopePrefix.isEmpty
    ? ''
    : storageScopePrefix.substring(0, storageScopePrefix.length - 1);

/// The [SharedPreferencesOptions] every prefs accessor in this app must be
/// constructed with — [openScopedPrefs] and every bare `SharedPreferencesAsync()`
/// alike, with no exceptions, for the reason below.
///
/// On desktop, Windows/Linux/macOS resolve their preferences store from the
/// OS app identity alone (Company/Product name on Windows and Linux, the
/// bundle id on macOS) — the same for every build configuration, since Flutter
/// does not vary it per config. A [scopedStorageKey] prefix therefore does NOT
/// give a debug/profile build its own storage: it still shares one physical
/// file with any release install on the same machine (this project's normal
/// dev setup — see `docs`/CLAUDE.md on running the real app alongside a dev
/// checkout). That would be a non-issue if a shared file merely interleaved
/// writes, but the Windows and Linux plugins (`SharedPreferencesAsyncWindows`/
/// `Linux`, see their `_cachedPreferences`) read the WHOLE file into memory
/// ONCE per process and, on every subsequent write, re-serialize that entire
/// cached map back to disk — never re-reading first. Two live processes (the
/// always-running release app and a `flutter run` debug build) each hold their
/// own stale snapshot, so whichever one writes ANY key next — for any reason,
/// unrelated to what the other just changed — silently overwrites the other's
/// recent edits with its own stale copy of every other key. This is how a
/// project or session deleted in a debug build reappeared: the delete landed
/// on disk, then the still-running release app's own next unrelated prefs
/// write flushed its stale in-memory copy of that same key straight back.
///
/// The fix is a build genuinely writing its OWN file (Windows/Linux) or its
/// OWN `NSUserDefaults` suite (macOS/iOS, which has no such single-writer
/// hazard — its API is inherently per-suite and safe to share, but a distinct
/// suite is used anyway for the same clean isolation), never merely a
/// differently-prefixed key inside a shared one. Release keeps the exact
/// default (`SharedPreferencesOptions()`) — this must never change shipped
/// behavior. Every accessor MUST pass this because the platform plugin caches
/// its ENTIRE preferences map keyed by nothing but "the first options it saw
/// this process" (`_cachedPreferences ??= ...`): one accessor using a custom
/// file/suite while another on the same platform singleton uses the default
/// would have the second silently inherit whichever file the FIRST caller in
/// the process happened to open, not the one it asked for.
SharedPreferencesOptions get desktopSharedPreferencesOptions {
  final fragment = _scopeFragment;
  if (fragment.isEmpty) return const SharedPreferencesOptions();
  if (Platform.isWindows) {
    return SharedPreferencesWindowsOptions(
      fileName: 'shared_preferences_$fragment',
    );
  }
  if (Platform.isLinux) {
    return SharedPreferencesLinuxOptions(
      fileName: 'shared_preferences_$fragment',
    );
  }
  if (Platform.isMacOS) {
    return SharedPreferencesAsyncFoundationOptions(
      suiteName: 'ai.antgrid.prefs.$fragment',
    );
  }
  // Android/iOS/web: each debug/release variant is already a distinct OS-level
  // install (different application id / bundle id per build config, or an
  // origin-scoped web storage), so there is no shared-file hazard to guard
  // against here — the key prefix alone is sufficient, same as release.
  return const SharedPreferencesOptions();
}
