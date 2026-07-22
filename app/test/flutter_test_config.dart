import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/prefs_test_mock.dart';

/// Auto-loaded by `flutter test` for every test in this tree.
///
/// Installs a fresh empty in-memory prefs platform before EVERY test. The app's
/// prefs APIs (`SharedPreferencesWithCache`/`SharedPreferencesAsync`) route
/// through the static `SharedPreferencesAsyncPlatform.instance`; without this a
/// test that forgets to call [useInMemoryPrefs] would silently inherit the
/// previous test's seeded data (order-dependent flake) or throw `StateError`
/// for a missing platform. Tests that need seed data still call
/// `useInMemoryPrefs({...})` in their own setUp/body — that runs after this root
/// setUp and overrides the empty default.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(useInMemoryPrefs);
  await testMain();
}
