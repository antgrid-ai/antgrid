import 'dart:io';

import 'package:antgrid/launcher/host_discovery.dart';
import 'package:antgrid/util/log_location.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('android and iOS keep logs in app support; desktop does not', () {
    expect(logsLiveInAppSupport(TargetPlatform.android), isTrue);
    expect(logsLiveInAppSupport(TargetPlatform.iOS), isTrue);
    for (final p in [
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
      TargetPlatform.fuchsia,
    ]) {
      expect(logsLiveInAppSupport(p), isFalse, reason: '$p');
    }
  });

  test('desktop log dir is hostDir unchanged', () {
    for (final p in [
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    ]) {
      expect(syncLogDir(platform: p), hostDir(), reason: '$p');
    }
  });

  test('mobile has no synchronous log dir', () {
    expect(syncLogDir(platform: TargetPlatform.android), isNull);
    expect(syncLogDir(platform: TargetPlatform.iOS), isNull);
  });

  test('mobile log dir mirrors the release/dev/scope split', () {
    expect(mobileLogDir('/s', release: true, scope: 'x'), '/s/logs');
    expect(mobileLogDir('/s', release: false, scope: ''), '/s/logs-dev');
    expect(mobileLogDir('/s', release: false, scope: 'foo'), '/s/logs-dev-foo');
  });

  test('iOS logs go under the cache dir, which is not backed up', () async {
    final support = Directory('/support');
    final cache = Directory('/cache');
    expect(
      await mobileLogBaseDirectory(
        platform: TargetPlatform.iOS,
        support: () async => support,
        cache: () async => cache,
      ),
      cache,
    );
    expect(
      await mobileLogBaseDirectory(
        platform: TargetPlatform.android,
        support: () async => support,
        cache: () async => cache,
      ),
      support,
    );
  });

  test('resolveMobileLogDir uses the injected support dir', () async {
    // kReleaseMode is false under test and storageScopeOverride is empty.
    expect(
      await resolveMobileLogDir(supportDir: () async => Directory('/sup')),
      '/sup/logs-dev',
    );
  });
}
