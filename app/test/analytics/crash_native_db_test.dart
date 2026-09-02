import 'dart:io';

import 'package:antgrid/analytics/crash_reporting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  // The failure this guards is silent by construction: `sentry_flutter` leaves
  // `nativeDatabasePath` null, sentry-native then uses `.sentry-native`
  // relative to the CWD, and a Store-launched MSIX has an unwritable one — so
  // `sentry_init` fails and Windows ships with no native crash capture at all,
  // with no handler process and no release-health session to reveal it. An
  // ABSOLUTE path under the app's own support directory is the entire fix, so
  // that is what is asserted rather than any particular spelling of it.
  test('native crash database resolves under the given support directory', () {
    final supportDir = Directory.systemTemp.path;
    final dbPath = nativeCrashDatabasePath(supportDir);

    expect(p.isAbsolute(dbPath), isTrue);
    expect(p.dirname(dbPath), supportDir);
    expect(p.basename(dbPath), '.sentry-native');
    // The cwd-relative default is the bug; anything relative is a regression.
    expect(dbPath, isNot('.sentry-native'));
  });

  // Only the sentry-native C SDK reads the option. Asserting the getter against
  // the same expression would be a tautology, so pin the contract that actually
  // matters: the platforms we ship a C-SDK build for are covered.
  test('the C-SDK desktop platforms are the ones that get a database path', () {
    if (Platform.isWindows || Platform.isLinux) {
      expect(usesNativeCrashDatabase, isTrue);
    } else {
      expect(usesNativeCrashDatabase, isFalse);
    }
  });

  test('init stays inert without consent and still runs the app', () async {
    var ran = false;
    await initCrashReporting(
      enabled: false,
      dsn: 'https://key@example.invalid/1',
      runApp: () async => ran = true,
    );
    expect(ran, isTrue);
  });

  test('init stays inert without a DSN and still runs the app', () async {
    var ran = false;
    await initCrashReporting(
      enabled: true,
      dsn: '',
      runApp: () async => ran = true,
    );
    expect(ran, isTrue);
  });
}
