import 'dart:async';

import 'package:antgrid/update/github_release_update_service.dart';
import 'package:antgrid/update/in_app_update_service.dart';
import 'package:antgrid/update/ios_app_store_update_service.dart';
import 'package:antgrid/update/macos_appcast_update_service.dart';
import 'package:antgrid/update/macos_sparkle_update_service.dart';
import 'package:antgrid/update/update_strategy.dart';
import 'package:antgrid/update/update_check_result.dart';
import 'package:in_app_update/in_app_update.dart';
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

  /// Overridden because the real getter has a side effect: it installs a
  /// PROCESS-GLOBAL handler on the live `antgrid/store_update` channel and
  /// latches a static that no suite resets, so one unmocked read leaks into
  /// every test that runs after it.
  @override
  Stream<int> get downloadProgress => _stream;
  final StreamController<int> progress = StreamController<int>.broadcast();
  // Cached: `StreamController.stream` hands back a fresh wrapper per read.
  late final Stream<int> _stream = progress.stream;

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
  Future<UpdateCheckResult> check() async {
    calls++;
    return result
        ? const UpdateCheckResult(UpdateCheckStatus.available, candidateId: '2')
        : UpdateCheckResult.failed;
  }
}

class _FakeAppcast extends MacosAppcastUpdateService {
  _FakeAppcast(this.result);
  final bool result;
  int calls = 0;
  String candidate = '2';

  @override
  Future<UpdateCheckResult> check() async {
    calls++;
    return result
        ? UpdateCheckResult(UpdateCheckStatus.available, candidateId: candidate)
        : UpdateCheckResult.failed;
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
  Future<UpdateCheckResult> check() async {
    calls++;
    return result
        ? const UpdateCheckResult(UpdateCheckStatus.available, candidateId: '2')
        : UpdateCheckResult.failed;
  }
}

AppUpdateInfo playInfo({
  bool available = false,
  InstallStatus status = InstallStatus.unknown,
  int priority = 0,
  bool immediate = true,
  bool flexible = true,
  bool inProgress = false,
}) => AppUpdateInfo(
  updateAvailability: inProgress
      ? UpdateAvailability.developerTriggeredUpdateInProgress
      : available
      ? UpdateAvailability.updateAvailable
      : UpdateAvailability.updateNotAvailable,
  immediateUpdateAllowed: immediate,
  immediateAllowedPreconditions: [],
  flexibleUpdateAllowed: flexible,
  flexibleAllowedPreconditions: [],
  availableVersionCode: 2,
  installStatus: status,
  packageName: 'ai.antgrid.app',
  clientVersionStalenessDays: 0,
  updatePriority: priority,
);

class _FakePlay extends InAppUpdateService {
  _FakePlay(this.info);
  AppUpdateInfo info;
  int completes = 0;
  final starts = <UpdateAction>[];
  Future<AppUpdateResult>? download;
  @override
  Future<AppUpdateInfo> check() async => info;
  @override
  Future<AppUpdateResult> start(UpdateAction action) async {
    starts.add(action);
    return await (download ?? Future.value(AppUpdateResult.success));
  }

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
  // could-not-open toast instead of the path being asserted.
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
        // The strategy REPORTS; the gate installs. Starting the Store here
        // would skip the bridge drain the whole sequence exists to perform.
        expect(store.installs, 0);

        // Latch spent: no further Store round-trips, no dialog re-pop.
        expect(await s.check(rowAlreadyLit: true), UpdateCheckOutcome.none);
        expect(store.checks, 1);
        expect(store.installs, 0);

        // A third check must stay just as quiet — the latch is what stops the
        // system dialog re-popping on every ≥30-min refocus for the whole
        // process lifetime, not only on the check straight after it.
        expect(await s.check(rowAlreadyLit: false), UpdateCheckOutcome.none);
        expect(store.checks, 1);
        expect(store.installs, 0);
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
        expect(store.installs, 0);
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
        WindowsStoreStrategy(
          service: _FakeStore(StoreUpdateCheck.none),
        ).installEndsSession,
        isTrue,
      );
      final store = _FakeStore(StoreUpdateCheck.none);
      addTearDown(store.progress.close);
      // Identity, not isNotNull: the point is that the strategy forwards the
      // SERVICE's stream, which a non-null stream that never emits satisfies
      // just as well.
      expect(
        WindowsStoreStrategy(service: store).installProgress,
        same(store.downloadProgress),
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

      // A later check that finds nothing must forget the name too, or the
      // confirm dialog offers to install a version that is no longer pending.
      final store = _FakeStore(
        StoreUpdateCheck.optional,
        version: '1.20677.173.0',
      );
      final cleared = WindowsStoreStrategy(service: store);
      await cleared.check(rowAlreadyLit: false);
      expect(cleared.pendingVersion, '1.20677.173.0');
      store.reply = StoreUpdateCheck.none;
      expect(await cleared.check(rowAlreadyLit: true), UpdateCheckOutcome.none);
      expect(cleared.pendingVersion, isNull);
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
      final s = PlayUpdateStrategy(service: _FakePlay(playInfo()));
      // completeFlexibleUpdate restarts the app in place — the generic
      // 'Update available / Update' copy would promise less than the tap does.
      expect(s.rowTitle, 'Update available');
      expect(s.rowActionLabel, 'Update');
    });

    test(
      'flexibleReady maps to the restart prompt, everything else to none',
      () async {
        expect(
          await PlayUpdateStrategy(
            service: _FakePlay(playInfo(status: InstallStatus.downloaded)),
          ).check(rowAlreadyLit: false),
          UpdateCheckOutcome.restartReady,
        );
        expect(
          await PlayUpdateStrategy(
            service: _FakePlay(playInfo()),
          ).check(rowAlreadyLit: false),
          UpdateCheckOutcome.none,
        );
      },
    );

    testWidgets('install completes the flexible update and hands off', (
      tester,
    ) async {
      final context = await pumpContext(tester);
      final play = _FakePlay(playInfo(status: InstallStatus.downloaded));
      final s = PlayUpdateStrategy(service: play);
      await s.detect();
      expect(await s.install(context), UpdateInstallResult.handedOff);
      expect(play.completes, 1);
      // Play restarts the app in place with nothing of ours to unwind, so the
      // confirm-and-drain path the Windows tap takes must not reach here.
      expect(s.installEndsSession, isFalse);
      expect(s.installProgress, isNull);
      expect(s.pendingVersion, isNull);
    });
  });
  test(
    'manual Windows mandatory detection never spends the automatic latch or installs',
    () async {
      final store = _FakeStore(StoreUpdateCheck.mandatory, version: '2.0.0.0');
      final strategy = WindowsStoreStrategy(service: store);
      expect((await strategy.detect()).status, UpdateCheckStatus.available);
      expect((await strategy.detect()).version, '2.0.0.0');
      expect(store.installs, 0);
      expect(
        strategy.automaticOutcome(await strategy.detect()),
        UpdateCheckOutcome.updateAvailableQuiet,
      );
    },
  );

  testWidgets(
    'Play detection selects immediate or flexible without starting either',
    (tester) async {
      final context = await pumpContext(tester);
      for (final priority in [1, 5]) {
        final play = _FakePlay(playInfo(available: true, priority: priority));
        final strategy = PlayUpdateStrategy(service: play);
        addTearDown(strategy.dispose);
        final result = await strategy.detect();
        expect(result.status, UpdateCheckStatus.available);
        expect(
          strategy.automaticOutcome(result),
          UpdateCheckOutcome.startDownloadQuiet,
        );
        expect(play.starts, isEmpty);
        await strategy.install(context);
        expect(play.starts, [
          priority == 5 ? UpdateAction.immediate : UpdateAction.flexible,
        ]);
        expect(play.completes, 0);
      }
    },
  );

  testWidgets(
    'Play download must complete before Restart can finish an update',
    (tester) async {
      final context = await pumpContext(tester);
      final completion = Completer<AppUpdateResult>();
      final play = _FakePlay(playInfo(available: true))
        ..download = completion.future;
      final strategy = PlayUpdateStrategy(service: play);
      addTearDown(strategy.dispose);
      final states = <UpdateCheckStatus>[];
      final sub = strategy.statusChanges.listen((r) => states.add(r.status));
      addTearDown(sub.cancel);
      await strategy.detect();
      final install = strategy.install(context);
      expect((await strategy.detect()).status, UpdateCheckStatus.downloading);
      expect(await strategy.install(context), UpdateInstallResult.notInstalled);
      expect(play.starts, [UpdateAction.flexible]);
      expect(play.completes, 0);
      completion.complete(AppUpdateResult.success);
      await install;
      await tester.pump();
      expect(states, [
        UpdateCheckStatus.downloading,
        UpdateCheckStatus.restartReady,
      ]);
      expect(strategy.rowActionLabel, 'Restart');
      await strategy.install(context);
      expect(play.completes, 1);
    },
  );

  test('Play leaves an existing flexible download alone', () async {
    final play = _FakePlay(
      playInfo(
        inProgress: true,
        immediate: false,
        status: InstallStatus.downloading,
      ),
    );
    final strategy = PlayUpdateStrategy(service: play);
    addTearDown(strategy.dispose);
    final result = await strategy.detect();
    expect(result.status, UpdateCheckStatus.downloading);
    expect(strategy.automaticOutcome(result), UpdateCheckOutcome.none);
    expect(play.starts, isEmpty);
    expect(play.completes, 0);
  });

  testWidgets('Sparkle rejection remembers a candidate, allowing a newer one', (
    tester,
  ) async {
    final context = await pumpContext(tester);
    final sparkle = _FakeSparkle();
    final appcast = _FakeAppcast(true);
    final strategy = MacosSparkleStrategy(sparkle: sparkle, appcast: appcast);
    addTearDown(strategy.dispose);
    await strategy.prepare();
    expect((await strategy.detect()).status, UpdateCheckStatus.available);
    await strategy.install(context);
    sparkle.onUpdaterUpdateNotAvailable(null);
    await tester.pump();
    expect((await strategy.detect()).status, UpdateCheckStatus.unsupported);
    appcast.candidate = '3';
    expect((await strategy.detect()).status, UpdateCheckStatus.available);
  });
  testWidgets(
    'manual Play action can use immediate when automatic policy waits for flexible',
    (tester) async {
      final context = await pumpContext(tester);
      final play = _FakePlay(playInfo(available: true, flexible: false));
      final strategy = PlayUpdateStrategy(service: play);
      addTearDown(strategy.dispose);
      final result = await strategy.detect();
      expect(result.status, UpdateCheckStatus.available);
      expect(strategy.automaticOutcome(result), UpdateCheckOutcome.none);
      expect(play.starts, isEmpty);
      await strategy.install(context);
      expect(play.starts, [UpdateAction.immediate]);
    },
  );

  test('manual action labels match each platform handoff', () {
    const available = UpdateCheckResult(UpdateCheckStatus.available);
    const ready = UpdateCheckResult(UpdateCheckStatus.restartReady);
    final strategies = <UpdateStrategy, String>{
      WindowsStoreStrategy(): 'Install & restart',
      MacosSparkleStrategy(): 'Update',
      LinuxBrowserStrategy(): 'Open download page',
      IosAppStoreStrategy(): 'Open App Store',
      PlayUpdateStrategy(): 'Update',
    };
    for (final entry in strategies.entries) {
      addTearDown(entry.key.dispose);
      expect(entry.key.actionLabel(available), entry.value);
      if (entry.key is PlayUpdateStrategy) {
        expect(entry.key.actionLabel(ready), 'Restart');
      }
    }
  });
}
