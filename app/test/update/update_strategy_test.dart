import 'package:antgrid/update/github_release_update_service.dart';
import 'package:antgrid/update/in_app_update_service.dart';
import 'package:antgrid/update/ios_app_store_update_service.dart';
import 'package:antgrid/update/macos_appcast_update_service.dart';
import 'package:antgrid/update/macos_sparkle_update_service.dart';
import 'package:antgrid/update/update_strategy.dart';
import 'package:antgrid/update/windows_store_update_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeStore extends WindowsStoreUpdateService {
  _FakeStore(
    this.reply, {
    this.version,
    this.outcome = StoreInstallOutcome.completed,
  });

  /// Mutable so a suite can let an optional update escalate to mandatory
  /// between two checks — the case the optional tier keeps checking for.
  StoreUpdateCheck reply;
  final String? version;
  final StoreInstallOutcome outcome;
  int checks = 0;
  int installs = 0;

  @override
  Future<StoreUpdateStatus> checkForUpdates() async {
    checks++;
    return reply == StoreUpdateCheck.none
        ? StoreUpdateStatus.none
        : StoreUpdateStatus(check: reply, version: version);
  }

  @override
  Future<StoreInstallOutcome> requestDownloadAndInstall() async {
    installs++;
    return outcome;
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

class _FakeSparkle extends MacosSparkleUpdateService {
  final List<String> calls = [];

  @override
  Future<void> configureFeed() async => calls.add('configureFeed');

  @override
  Future<void> startUpdate() async => calls.add('startUpdate');
}

class _FakeAppStore extends IosAppStoreUpdateService {
  _FakeAppStore(this.result, {this.url});
  final bool result;
  final String? url;
  int calls = 0;

  @override
  String? get listingUrl => url;

  @override
  Future<bool> isUpdateAvailable() async {
    calls++;
    return result;
  }
}

class _FakePlay extends InAppUpdateService {
  _FakePlay(this.decision);
  final UpdateDecision decision;
  int completes = 0;

  @override
  Future<UpdateDecision> checkAndStart() async => decision;

  @override
  Future<void> completeFlexibleUpdate() async {
    completes++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The browser/App Store hand-offs go through url_launcher, whose default
  // platform implementation is the method channel — unregistered under
  // `flutter test`, so without this their install() dead-ends in the
  // could-not-open SnackBar instead of the path being asserted.
  List<String> mockUrlLauncher() {
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final launched = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'launch':
          launched.add((call.arguments as Map)['url'] as String);
          return true;
        case 'canLaunch':
          return true;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    return launched;
  }

  Future<BuildContext> pumpContext(WidgetTester tester) async {
    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            captured = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return captured;
  }

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

        // A third check must stay just as quiet — the latch is what stops the
        // system dialog re-popping on every ≥30-min refocus for the whole
        // process lifetime, not only on the check straight after it.
        expect(await s.check(rowAlreadyLit: false), UpdateCheckOutcome.none);
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

    test(
      'an escalation to mandatory auto-launches on the later check',
      () async {
        final store = _FakeStore(StoreUpdateCheck.optional);
        final s = WindowsStoreStrategy(service: store);

        expect(
          await s.check(rowAlreadyLit: false),
          UpdateCheckOutcome.updateAvailable,
        );
        expect(store.installs, 0);

        store.reply = StoreUpdateCheck.mandatory;
        expect(
          await s.check(rowAlreadyLit: true),
          UpdateCheckOutcome.updateAvailableQuiet,
        );
        expect(store.installs, 1);
      },
    );

    test('row copy names the restart the tap performs', () {
      final s = WindowsStoreStrategy(
        service: _FakeStore(StoreUpdateCheck.none),
      );
      expect(s.rowTitle, 'Update available');
      // The tap CLOSES the app; 'Update' would hide the part of it the user
      // cannot take back.
      expect(s.rowActionLabel, 'Install & restart');
    });

    test('install ends the session and reports download progress', () {
      // Both are Windows-only; every other strategy's own test pins the
      // opposite, which is what keeps the controller from showing a
      // quit-and-drain confirmation on a platform that neither quits nor
      // drains.
      expect(
        WindowsStoreStrategy(service: _FakeStore(StoreUpdateCheck.none))
            .installEndsSession,
        isTrue,
      );
      expect(
        WindowsStoreStrategy(service: _FakeStore(StoreUpdateCheck.none))
            .installProgress,
        isNotNull,
      );
    });

    test('pendingVersion is only what the last check actually saw', () async {
      final withVersion = WindowsStoreStrategy(
        service: _FakeStore(
          StoreUpdateCheck.optional,
          version: '1.20677.173.0',
        ),
      );
      expect(withVersion.pendingVersion, isNull, reason: 'no check yet');
      await withVersion.check(rowAlreadyLit: false);
      expect(withVersion.pendingVersion, '1.20677.173.0');

      // Unknown is common (the Store reports "" for it) and must stay null so
      // copy that names the version falls back rather than naming nothing.
      final nameless = WindowsStoreStrategy(
        service: _FakeStore(StoreUpdateCheck.optional),
      );
      await nameless.check(rowAlreadyLit: false);
      expect(nameless.pendingVersion, isNull);
    });

    testWidgets('every Store outcome maps to its install result', (
      tester,
    ) async {
      final context = await pumpContext(tester);
      const cases = <(StoreInstallOutcome, UpdateInstallResult)>[
        (StoreInstallOutcome.completed, UpdateInstallResult.handedOff),
        (StoreInstallOutcome.cancelled, UpdateInstallResult.notInstalled),
        (StoreInstallOutcome.none, UpdateInstallResult.nothingPending),
        (StoreInstallOutcome.unavailable, UpdateInstallResult.unavailable),
      ];
      for (final (outcome, expected) in cases) {
        final store = _FakeStore(StoreUpdateCheck.optional, outcome: outcome);
        expect(
          await WindowsStoreStrategy(service: store).install(context),
          expected,
          reason: '$outcome',
        );
        expect(store.installs, 1);
      }
    });

    testWidgets('a refused install leaves the row tappable again', (
      tester,
    ) async {
      // 'cancelled' is the Store's whole not-installed bucket (a declined
      // dialog, a Wi-Fi refusal, a download still in flight), so a repeat tap
      // must reach the Store again rather than being latched off.
      final context = await pumpContext(tester);
      final store = _FakeStore(
        StoreUpdateCheck.optional,
        outcome: StoreInstallOutcome.cancelled,
      );
      final s = WindowsStoreStrategy(service: store);
      expect(await s.install(context), UpdateInstallResult.notInstalled);
      expect(await s.install(context), UpdateInstallResult.notInstalled);
      expect(store.installs, 2);
    });
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

    testWidgets('install opens the releases page and hands off', (
      tester,
    ) async {
      final launched = mockUrlLauncher();
      final context = await pumpContext(tester);
      final s = LinuxBrowserStrategy(releases: _FakeReleases(true));
      expect(await s.install(context), UpdateInstallResult.handedOff);
      expect(launched, [GithubReleaseUpdateService.latestDownloadPageUrl]);
      expect(s.installEndsSession, isFalse);
      expect(s.installProgress, isNull);
      expect(s.pendingVersion, isNull);
      expect(s.rowTitle, 'Update available');
      expect(s.rowActionLabel, 'Update');
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

    testWidgets('install re-asserts the feed before opening Sparkle', (
      tester,
    ) async {
      // Order is the point: prepare() is fire-and-forget at startup and
      // swallows failures, and a feed-less Sparkle errors silently on every
      // startUpdate.
      final context = await pumpContext(tester);
      final sparkle = _FakeSparkle();
      final s = MacosSparkleStrategy(
        sparkle: sparkle,
        appcast: _FakeAppcast(true),
      );
      expect(await s.install(context), UpdateInstallResult.handedOff);
      expect(sparkle.calls, ['configureFeed', 'startUpdate']);
      expect(s.installEndsSession, isFalse);
      expect(s.installProgress, isNull);
      expect(s.pendingVersion, isNull);
      expect(s.rowTitle, 'Update available');
      expect(s.rowActionLabel, 'Update');
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

    testWidgets('install opens the cached listing and hands off', (
      tester,
    ) async {
      final launched = mockUrlLauncher();
      final context = await pumpContext(tester);
      final s = IosAppStoreStrategy(
        service: _FakeAppStore(true, url: 'https://apps.apple.com/app/id123'),
      );
      expect(await s.install(context), UpdateInstallResult.handedOff);
      expect(launched, ['https://apps.apple.com/app/id123']);
      expect(s.installEndsSession, isFalse);
      expect(s.installProgress, isNull);
      expect(s.pendingVersion, isNull);
      expect(s.rowTitle, 'Update available');
      expect(s.rowActionLabel, 'Update');
    });
  });

  group('PlayUpdateStrategy', () {
    test('row copy promises the restart its install performs', () {
      final s = PlayUpdateStrategy(service: _FakePlay(UpdateDecision.none));
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
            service: _FakePlay(UpdateDecision.flexibleReady),
          ).check(rowAlreadyLit: false),
          UpdateCheckOutcome.restartReady,
        );
        expect(
          await PlayUpdateStrategy(service: _FakePlay(UpdateDecision.none))
              .check(rowAlreadyLit: false),
          UpdateCheckOutcome.none,
        );
      },
    );

    testWidgets('install completes the flexible update and hands off', (
      tester,
    ) async {
      final context = await pumpContext(tester);
      final play = _FakePlay(UpdateDecision.flexibleReady);
      final s = PlayUpdateStrategy(service: play);
      expect(await s.install(context), UpdateInstallResult.handedOff);
      expect(play.completes, 1);
      // Play restarts the app in place with nothing of ours to unwind, so the
      // confirm-and-drain path the Windows tap takes must not reach here.
      expect(s.installEndsSession, isFalse);
      expect(s.installProgress, isNull);
      expect(s.pendingVersion, isNull);
    });
  });
}
