import 'package:antgrid/update/github_release_update_service.dart';
import 'package:antgrid/update/in_app_update_service.dart';
import 'package:antgrid/update/ios_app_store_update_service.dart';
import 'package:antgrid/update/macos_appcast_update_service.dart';
import 'package:antgrid/update/update_strategy.dart';
import 'package:antgrid/update/windows_store_update_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeStore extends WindowsStoreUpdateService {
  _FakeStore(this.reply);
  final StoreUpdateCheck reply;
  int checks = 0;
  int installs = 0;

  @override
  Future<StoreUpdateCheck> checkForUpdates() async {
    checks++;
    return reply;
  }

  @override
  Future<void> requestDownloadAndInstall() async {
    installs++;
  }
}

class _FakeReleases extends GithubReleaseUpdateService {
  _FakeReleases(this.result);
  final bool result;
  int calls = 0;

  @override
  Future<bool> isUpdateAvailable() async {
    calls++;
    return result;
  }
}

class _FakeAppcast extends MacosAppcastUpdateService {
  _FakeAppcast(this.result);
  final bool result;
  int calls = 0;

  @override
  Future<bool> isUpdateAvailable() async {
    calls++;
    return result;
  }
}

class _FakeAppStore extends IosAppStoreUpdateService {
  _FakeAppStore(this.result);
  final bool result;
  int calls = 0;

  @override
  Future<bool> isUpdateAvailable() async {
    calls++;
    return result;
  }
}

class _FakePlay extends InAppUpdateService {
  const _FakePlay(this.decision);
  final UpdateDecision decision;

  @override
  Future<UpdateDecision> checkAndStart() async => decision;
}

void main() {
  test('the provider table covers every platform with an update path', () {
    // The provider is THE per-platform matrix — UpdateGate and UpdateRow
    // both resolve it, so a strategy existing here proves the platform
    // carries detection, row copy, and an install route together.
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    for (final platform in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = platform;
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final strategy = container.read(updateStrategyProvider);
      if (platform == TargetPlatform.fuchsia) {
        expect(strategy, isNull);
      } else {
        expect(strategy, isNotNull, reason: '$platform must carry a strategy');
      }
    }
  });

  group('WindowsStoreStrategy', () {
    test(
      'mandatory: lights the row QUIETLY, auto-launches once, then goes quiet',
      () async {
        final store = _FakeStore(StoreUpdateCheck.mandatory);
        final s = WindowsStoreStrategy(service: store);

        // Quiet outcome: the auto-launched Store dialog IS the announcement —
        // an updateAvailable here would stack the gate's toast on top of it.
        expect(
          await s.check(rowAlreadyLit: false),
          UpdateCheckOutcome.updateAvailableQuiet,
        );
        expect(store.installs, 1);

        // Latch spent: no further Store round-trips, no dialog re-pop.
        expect(await s.check(rowAlreadyLit: true), UpdateCheckOutcome.none);
        expect(store.checks, 1);
        expect(store.installs, 1);
      },
    );

    test(
      'optional: keeps checking so a mandatory escalation is caught',
      () async {
        final store = _FakeStore(StoreUpdateCheck.optional);
        final s = WindowsStoreStrategy(service: store);

        expect(
          await s.check(rowAlreadyLit: false),
          UpdateCheckOutcome.updateAvailable,
        );
        expect(
          await s.check(rowAlreadyLit: true),
          UpdateCheckOutcome.updateAvailable,
          reason: 'a lit row must not stop optional-tier re-checks',
        );
        expect(store.checks, 2);
        expect(store.installs, 0);
      },
    );
  });

  group('LinuxBrowserStrategy', () {
    test('a lit row skips the network round-trip entirely', () async {
      final releases = _FakeReleases(true);
      final s = LinuxBrowserStrategy(releases: releases);
      expect(await s.check(rowAlreadyLit: true), UpdateCheckOutcome.none);
      expect(releases.calls, 0);
    });

    test('newer release lights the row', () async {
      final s = LinuxBrowserStrategy(releases: _FakeReleases(true));
      expect(
        await s.check(rowAlreadyLit: false),
        UpdateCheckOutcome.updateAvailable,
      );
    });
  });

  group('MacosSparkleStrategy', () {
    test('a lit row skips the appcast fetch entirely', () async {
      final appcast = _FakeAppcast(true);
      final s = MacosSparkleStrategy(appcast: appcast);
      expect(await s.check(rowAlreadyLit: true), UpdateCheckOutcome.none);
      expect(appcast.calls, 0);
    });

    test('a newer appcast build lights the row', () async {
      final s = MacosSparkleStrategy(appcast: _FakeAppcast(true));
      expect(
        await s.check(rowAlreadyLit: false),
        UpdateCheckOutcome.updateAvailable,
      );
    });

    // The regression this strategy's design prevents: detection reads the
    // very document Sparkle installs from, so no appcast (or an unreadable
    // one) leaves the row DARK instead of dead-ending in Sparkle's error
    // dialog on every tap.
    test('an unreadable appcast leaves the row dark', () async {
      final s = MacosSparkleStrategy(appcast: _FakeAppcast(false));
      expect(await s.check(rowAlreadyLit: false), UpdateCheckOutcome.none);
    });
  });

  group('IosAppStoreStrategy', () {
    test('a lit row skips the lookup entirely', () async {
      final service = _FakeAppStore(true);
      final s = IosAppStoreStrategy(service: service);
      expect(await s.check(rowAlreadyLit: true), UpdateCheckOutcome.none);
      expect(service.calls, 0);
    });

    test('newer listing lights the row', () async {
      final s = IosAppStoreStrategy(service: _FakeAppStore(true));
      expect(
        await s.check(rowAlreadyLit: false),
        UpdateCheckOutcome.updateAvailable,
      );
    });
  });

  group('PlayUpdateStrategy', () {
    test('row copy promises the restart its install performs', () {
      final s = PlayUpdateStrategy(
        service: const _FakePlay(UpdateDecision.none),
      );
      // completeFlexibleUpdate restarts the app in place — the generic
      // 'Update available / Update' copy would promise less than the tap does.
      expect(s.rowTitle, 'Update ready');
      expect(s.rowActionLabel, 'Restart');
    });

    test(
      'flexibleReady maps to the restart prompt, everything else to none',
      () async {
        expect(
          await PlayUpdateStrategy(
            service: const _FakePlay(UpdateDecision.flexibleReady),
          ).check(rowAlreadyLit: false),
          UpdateCheckOutcome.restartReady,
        );
        expect(
          await PlayUpdateStrategy(
            service: const _FakePlay(UpdateDecision.none),
          ).check(rowAlreadyLit: false),
          UpdateCheckOutcome.none,
        );
      },
    );
  });
}
