import 'dart:async';

import 'package:antgrid/design/widgets/ab_confirm_dialog.dart';
import 'package:antgrid/launcher/host_controller.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/control_plane.dart'
    show hostControllerProvider;
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

  @override
  Future<void> shutdownOwnedHost() async {
    drains++;
    log.add('drain');
    final hook = _onDrain;
    if (hook != null) await hook();
  }
}

class _Harness {
  _Harness({
    required this.container,
    required this.context,
    required this.log,
    required this.strategy,
    required this.host,
  });

  final ProviderContainer container;
  final BuildContext context;
  final List<String> log;
  final _FakeStrategy strategy;
  final _FakeHost host;

  UpdateInstallState get state =>
      container.read(updateInstallControllerProvider);

  Future<void> start() =>
      container.read(updateInstallControllerProvider.notifier).start(context);
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
  final container = ProviderContainer(
    overrides: [
      updateStrategyProvider.overrideWithValue(strategy),
      hostControllerProvider.overrideWithValue(host),
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
}
