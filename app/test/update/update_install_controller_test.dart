import 'dart:async';

import 'package:antgrid/config/build_info.dart';
import 'package:antgrid/design/widgets/ab_confirm_dialog.dart';
import 'package:antgrid/launcher/host_controller.dart';
import 'package:antgrid/launcher/host_discovery.dart' show HostFile;
import 'package:antgrid/design/widgets/ab_toast.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/control_plane.dart'
    show hostControllerProvider;
import 'package:antgrid/providers/update_available.dart';
import 'package:antgrid/storage/update_handoff_store.dart';
import 'package:antgrid/update/update_install_controller.dart';
import 'package:antgrid/update/update_strategy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Both fakes append to one shared list, which is the only way to assert the
/// thing the sequence exists for: the host is drained BEFORE the platform is
/// handed the update.
class _FakeStrategy extends UpdateStrategy {
  _FakeStrategy(
    this.log, {
    this.endsSession = true,
    this.result = UpdateInstallResult.handedOff,
    this.throwOnInstall = false,
    this.version,
    this.progress,
  });

  final List<String> log;
  final bool endsSession;
  final UpdateInstallResult result;
  final bool throwOnInstall;
  final String? version;
  final Stream<int>? progress;
  int installs = 0;

  @override
  bool get active => true;

  @override
  bool get installEndsSession => endsSession;

  @override
  Stream<int>? get installProgress => progress;

  @override
  String? get pendingVersion => version;

  @override
  Future<UpdateCheckOutcome> check({required bool rowAlreadyLit}) async =>
      UpdateCheckOutcome.none;

  @override
  Future<UpdateInstallResult> install(BuildContext context) async {
    installs++;
    log.add('install');
    if (throwOnInstall) throw StateError('install blew up');
    return result;
  }
}

class _FakeHost extends HostController {
  _FakeHost(this.log, {Future<void> Function()? onDrain}) : _onDrain = onDrain;

  final List<String> log;
  final Future<void> Function()? _onDrain;
  int drains = 0;
  int rearms = 0;
  int seals = 0;
  int unseals = 0;

  /// Seal/unseal deliberately stay OUT of [log]: the shared list pins the
  /// drain-before-install ordering, and counters keep that assertion readable.
  @override
  void sealSpawns() {
    seals++;
    super.sealSpawns();
  }

  @override
  void unsealSpawns() {
    unseals++;
    super.unsealSpawns();
  }

  @override
  Future<void> shutdownOwnedHost() async {
    drains++;
    log.add('drain');
    final hook = _onDrain;
    if (hook != null) await hook();
  }

  @override
  Future<HostFile> ensureHost() async {
    rearms++;
    log.add('rearm');
    throw StateError('no host in a widget test');
  }
}

class _FakeHandoff implements UpdateHandoffSink {
  final List<String> marked = [];
  int clears = 0;

  @override
  Future<void> markHandoff(String version) async => marked.add(version);

  @override
  Future<void> clear() async => clears++;
}

class _Harness {
  _Harness({
    required this.container,
    required this.context,
    required this.log,
    required this.strategy,
    required this.host,
    required this.handoff,
  });

  final ProviderContainer container;
  final BuildContext context;
  final List<String> log;
  final _FakeStrategy strategy;
  final _FakeHost host;
  final _FakeHandoff handoff;

  UpdateInstallState get state =>
      container.read(updateInstallControllerProvider);

  Future<void> start({bool confirm = true}) => container
      .read(updateInstallControllerProvider.notifier)
      .start(context, confirm: confirm);
}

Future<_Harness> _pump(
  WidgetTester tester, {
  bool endsSession = true,
  UpdateInstallResult result = UpdateInstallResult.handedOff,
  bool throwOnInstall = false,
  String? version,
  Stream<int>? progress,
  Future<void> Function()? onDrain,
}) async {
  final log = <String>[];
  final strategy = _FakeStrategy(
    log,
    endsSession: endsSession,
    result: result,
    throwOnInstall: throwOnInstall,
    version: version,
    progress: progress,
  );
  final host = _FakeHost(log, onDrain: onDrain);
  final handoff = _FakeHandoff();
  final container = ProviderContainer(
    overrides: [
      updateStrategyProvider.overrideWithValue(strategy),
      hostControllerProvider.overrideWithValue(host),
      updateHandoffStoreProvider.overrideWithValue(handoff),
    ],
  );
  addTearDown(container.dispose);

  late BuildContext captured;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              captured = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    ),
  );
  return _Harness(
    container: container,
    context: captured,
    log: log,
    strategy: strategy,
    host: host,
    handoff: handoff,
  );
}

void main() {
  testWidgets('confirms, then drains the host BEFORE handing the update over', (
    tester,
  ) async {
    // The whole point of the sequence: `didRequestAppExit` never fires on
    // Windows, so if the bridge isn't shut down here it is killed by the job
    // object as the Store replaces the package.
    final h = await _pump(tester, version: '1.20677.173.0');
    unawaited(h.start());
    await tester.pumpAndSettle();

    expect(find.text('Install update and restart?'), findsOneWidget);
    expect(h.state, const UpdateInstallConfirming());
    expect(h.log, isEmpty);

    await tester.tap(find.text('Install & restart'));
    await tester.pumpAndSettle();

    expect(h.log, ['drain', 'install']);
    expect(h.state, const UpdateInstallDone());
  });

  testWidgets('declining touches neither the host nor the platform', (
    tester,
  ) async {
    final progress = StreamController<int>.broadcast();
    addTearDown(progress.close);
    final h = await _pump(tester, progress: progress.stream);
    unawaited(h.start());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(h.log, isEmpty);
    expect(h.host.drains, 0);
    expect(h.strategy.installs, 0);
    expect(progress.hasListener, isFalse);
    expect(h.state, const UpdateInstallIdle());
  });

  testWidgets('a not-installed outcome leaves the affordance retryable', (
    tester,
  ) async {
    // The Store collapses a declined consent dialog, a low-battery refusal and
    // a download still in flight into one "not completed" bucket, so this must
    // never lock the user out of trying again.
    final h = await _pump(tester, result: UpdateInstallResult.notInstalled);
    unawaited(h.start());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install & restart'));
    await tester.pumpAndSettle();

    // What `UpdateRow` treats as tappable is idle-or-failed.
    expect(
      h.state,
      const UpdateInstallFailed(UpdateInstallResult.notInstalled),
    );

    unawaited(h.start());
    await tester.pumpAndSettle();
    expect(find.text('Install update and restart?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(h.strategy.installs, 1);

    await tester.pump(const Duration(seconds: 9)); // expire the toast timer
  });

  testWidgets('an unreachable install route surfaces as a failure state', (
    tester,
  ) async {
    final h = await _pump(tester, result: UpdateInstallResult.unavailable);
    unawaited(h.start());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install & restart'));
    await tester.pumpAndSettle();

    expect(h.state, const UpdateInstallFailed(UpdateInstallResult.unavailable));
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('a strategy that throws is reported, not propagated', (
    tester,
  ) async {
    final h = await _pump(tester, throwOnInstall: true);
    unawaited(h.start());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install & restart'));
    await tester.pumpAndSettle();

    expect(h.state, const UpdateInstallFailed(UpdateInstallResult.unavailable));
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('a drain that throws still hands the update over', (
    tester,
  ) async {
    // Best-effort by design: the user has already decided, so a wedged host
    // must not be able to veto the update.
    final h = await _pump(
      tester,
      onDrain: () async {
        throw StateError('wedged host');
      },
    );
    unawaited(h.start());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install & restart'));
    await tester.pumpAndSettle();

    expect(h.log, ['drain', 'install']);
    expect(h.state, const UpdateInstallDone());
  });

  testWidgets('a drain that hangs is timed out and the install proceeds', (
    tester,
  ) async {
    final blocked = Completer<void>();
    final h = await _pump(tester, onDrain: () => blocked.future);
    unawaited(h.start());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install & restart'));
    await tester.pumpAndSettle();

    expect(h.log, ['drain']);
    expect(h.state, const UpdateInstallWorking(0));

    await tester.pump(const Duration(seconds: 9)); // trip the 8s ceiling
    await tester.pump();

    expect(h.log, ['drain', 'install']);
    expect(h.state, const UpdateInstallDone());
  });

  testWidgets('progress ticks drive the state and are dropped on success', (
    tester,
  ) async {
    final progress = StreamController<int>.broadcast();
    addTearDown(progress.close);
    final blocked = Completer<void>();
    final h = await _pump(
      tester,
      progress: progress.stream,
      onDrain: () => blocked.future,
    );
    unawaited(h.start());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install & restart'));
    await tester.pumpAndSettle();

    expect(progress.hasListener, isTrue);
    progress.add(42);
    await tester.pump();
    expect(h.state, const UpdateInstallWorking(42));

    blocked.complete();
    await tester.pumpAndSettle();
    await tester.pump();

    expect(h.state, const UpdateInstallDone());
    expect(progress.hasListener, isFalse);
  });

  testWidgets('the progress subscription is dropped on the failure path too', (
    tester,
  ) async {
    final progress = StreamController<int>.broadcast();
    addTearDown(progress.close);
    final h = await _pump(
      tester,
      result: UpdateInstallResult.notInstalled,
      progress: progress.stream,
    );
    unawaited(h.start());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install & restart'));
    await tester.pumpAndSettle();
    await tester.pump();

    expect(
      h.state,
      const UpdateInstallFailed(UpdateInstallResult.notInstalled),
    );
    expect(progress.hasListener, isFalse);

    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('the confirm body omits the session clause when none are open', (
    tester,
  ) async {
    final h = await _pump(tester, version: '1.20677.173.0');
    unawaited(h.start());
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Version 1.20677.173.0 installs over a closed app'),
      findsOneWidget,
    );
    expect(find.textContaining('will stop'), findsNothing);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('open projects are counted, and an unknown version is nameless', (
    tester,
  ) async {
    final h = await _pump(tester);
    h.container
        .read(projectSessionRegistryProvider.notifier)
        .touch('p1', isLocal: true);
    unawaited(h.start());
    await tester.pumpAndSettle();

    expect(
      find.textContaining('1 open project session will stop.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('This update installs over a closed app'),
      findsOneWidget,
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('a platform whose install ends nothing skips confirm and drain', (
    tester,
  ) async {
    // Linux opens a browser tab: there is nothing of ours to unwind and
    // nothing worth a confirmation click.
    final h = await _pump(tester, endsSession: false);
    await h.start();
    await tester.pump();

    expect(find.byType(AbConfirmDialog), findsNothing);
    expect(h.host.drains, 0);
    expect(h.log, ['install']);
    // Idle, not Done: the user can close the browser tab without downloading,
    // and Done is the one state the row refuses to leave.
    expect(h.state, const UpdateInstallIdle());
  });

  testWidgets('spawning is sealed before the drain, not after', (tester) async {
    // Asserted from INSIDE the drain: sealing afterwards would leave open
    // exactly the window the seal exists to close.
    _FakeHost? host;
    bool? sealedDuringDrain;
    final h = await _pump(
      tester,
      // Runs after `host` is assigned below — the drain is several frames away.
      onDrain: () async => sealedDuringDrain = host!.spawnSealed,
    );
    host = h.host;
    unawaited(h.start());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install & restart'));
    await tester.pumpAndSettle();

    expect(sealedDuringDrain, isTrue);
  });

  testWidgets('a hand-off leaves the seal on, so nothing respawns', (
    tester,
  ) async {
    // The process is dying; anything that spawned here would hand the Store a
    // live PTY tree to force-kill.
    final h = await _pump(tester);
    unawaited(h.start());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install & restart'));
    await tester.pumpAndSettle();

    expect(h.host.seals, 1);
    expect(h.host.unseals, 0);
    expect(h.host.spawnSealed, isTrue);
  });

  testWidgets('an install that did not happen lifts the seal', (tester) async {
    // Otherwise a declined consent dialog leaves the machine unable to start
    // any agent until the app is restarted.
    final h = await _pump(tester, result: UpdateInstallResult.notInstalled);
    unawaited(h.start());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install & restart'));
    await tester.pumpAndSettle();

    expect(h.host.spawnSealed, isFalse);
    expect(h.host.rearms, 1);
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('a platform that ends nothing never seals', (tester) async {
    final h = await _pump(tester, endsSession: false);
    await h.start();
    await tester.pump();

    expect(h.host.seals, 0);
    expect(h.host.spawnSealed, isFalse);
  });

  testWidgets('a hand-off records the build being replaced', (tester) async {
    // `--after-update` alone cannot prove an update happened: Windows relaunches
    // with the same argument after a crash. The recorded version is the proof.
    final h = await _pump(tester);
    unawaited(h.start());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install & restart'));
    await tester.pumpAndSettle();

    expect(h.handoff.marked, [BuildInfo.version]);
    expect(h.handoff.clears, 0);
  });

  testWidgets('an install that did not happen clears the record', (
    tester,
  ) async {
    // Left behind, it would be found by the next crash relaunch and announced
    // as an update the user never got.
    final h = await _pump(tester, result: UpdateInstallResult.notInstalled);
    unawaited(h.start());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install & restart'));
    await tester.pumpAndSettle();

    expect(h.handoff.marked, [BuildInfo.version]);
    expect(h.handoff.clears, 1);
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('a platform that ends nothing records nothing', (tester) async {
    // Nothing replaces the package, so there is no relaunch to announce.
    final h = await _pump(tester, endsSession: false);
    await h.start();
    await tester.pump();

    expect(h.handoff.marked, isEmpty);
    expect(h.handoff.clears, 0);
  });

  testWidgets('a browser hand-off can be repeated', (tester) async {
    final h = await _pump(tester, endsSession: false);
    await h.start();
    await tester.pump();
    await h.start();
    await tester.pump();

    expect(h.strategy.installs, 2);
  });

  testWidgets('a second entry while the confirm is up is dropped', (
    tester,
  ) async {
    final h = await _pump(tester);
    unawaited(h.start());
    await tester.pumpAndSettle();
    unawaited(h.start());
    await tester.pumpAndSettle();

    expect(find.text('Install update and restart?'), findsOneWidget);

    await tester.tap(find.text('Install & restart'));
    await tester.pumpAndSettle();

    expect(h.host.drains, 1);
    expect(h.strategy.installs, 1);
  });

  testWidgets('a platform-initiated install skips the dialog, not the drain', (
    tester,
  ) async {
    final h = await _pump(tester);
    await h.start(confirm: false);
    await tester.pumpAndSettle();

    // The Windows mandatory tier: the user is not being asked, but the bridge
    // is still shut down before the MSIX is replaced over it.
    expect(find.byType(AbConfirmDialog), findsNothing);
    expect(h.log, ['drain', 'install']);
    expect(h.state, const UpdateInstallDone());
  });

  testWidgets(
    'an update that turns out not to be pending stops offering itself',
    (tester) async {
      final h = await _pump(tester, result: UpdateInstallResult.nothingPending);
      h.container.read(updateAvailableProvider.notifier).set(true);

      unawaited(h.start());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Install & restart'));
      await tester.pumpAndSettle();

      // The Store answering "nothing pending" is the only evidence that outranks
      // the check that lit the row; leaving it lit offers an install that can
      // now only ever repeat this toast.
      expect(h.container.read(updateAvailableProvider), isFalse);
      expect(h.state, const UpdateInstallIdle());
      expect(find.text('Already up to date'), findsOneWidget);

      await tester.pump(const Duration(seconds: 9));
    },
  );

  testWidgets('a failed attempt does not leave the row lit-but-unbacked', (
    tester,
  ) async {
    final h = await _pump(tester, result: UpdateInstallResult.unavailable);
    h.container.read(updateAvailableProvider.notifier).set(true);

    unawaited(h.start());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install & restart'));
    await tester.pumpAndSettle();

    // Only the platform's own "nothing pending" un-lights it — a transient
    // failure must not hide an update that is still waiting.
    expect(h.container.read(updateAvailableProvider), isTrue);

    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('a drain that bought nothing is undone again', (tester) async {
    final h = await _pump(tester, result: UpdateInstallResult.notInstalled);

    unawaited(h.start());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install & restart'));
    await tester.pumpAndSettle();

    // shutdownOwnedHost cancels supervised respawn, so without this the user
    // is left on a dead bridge with no banner and nothing to bring it back.
    expect(h.log, ['drain', 'install', 'rearm']);
    expect(
      h.state,
      const UpdateInstallFailed(UpdateInstallResult.notInstalled),
    );
    // The toast has to own up to what the abandoned attempt already cost.
    final toast = tester.widget<AbToast>(find.byType(AbToast));
    expect(toast.title, 'Update not installed');
    expect(toast.description, contains('Project sessions were stopped'));

    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('a real hand-off never re-arms the host', (tester) async {
    final h = await _pump(tester);

    unawaited(h.start());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install & restart'));
    await tester.pumpAndSettle();

    // The process is going away; spawning a bridge into the Store's window is
    // the exact tree the update must not find alive.
    expect(h.host.rearms, 0);
    expect(h.log, ['drain', 'install']);
  });
}
